from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))

import orchestrator  # noqa: E402
from orchestrator import (  # noqa: E402
    Daemon,
    MessengerOutcomeStore,
    RunsStore,
    Worker,
    create_spike_workspace,
    extract_spike_result,
    remove_spike_workspace,
    validate_spike_result,
)
from tickets import read as read_ticket  # noqa: E402


class SpikeExecutionTests(unittest.TestCase):
    def test_research_dispatch_requires_explicit_mode_without_changing_legacy_defaults(self):
        with self.assertRaisesRegex(ValueError, "execution mode must be explicit"):
            orchestrator.validate_research_dispatch(
                {"title": "Spike: investigate voices"}, "---\ntitle: Spike: investigate voices\n---\n"
            )
        for mode in ("spike", "implementation"):
            orchestrator.validate_research_dispatch(
                {"title": "Spike: investigate voices"}, f"---\nexecution_mode: {mode}\n---\n"
            )
        orchestrator.validate_research_dispatch({"title": "Fix a bug"}, "---\ntitle: Fix a bug\n---\n")

    def test_unresolved_required_inputs_block_dispatch_but_uncertainties_do_not(self):
        for mode in ("spike", "implementation"):
            contents = f"---\nexecution_mode: {mode}\n---\n"
            ticket = {"title": "Spike: investigate voices", "body": "## Required inputs\n- [ ] Consented reference\n\n## Acceptance criteria\n- [ ] Report findings\n"}
            with self.assertRaisesRegex(ValueError, "Required inputs"):
                orchestrator.validate_research_dispatch(ticket, contents)
            ticket["body"] = ticket["body"].replace("[ ] Consented", "[x] Consented")
            orchestrator.validate_research_dispatch(ticket, contents)

    def test_legacy_ticket_defaults_to_implementation_and_spike_round_trips(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.write_ticket(repo, "RR-1", mode=None)
            self.write_ticket(repo, "RR-2", mode="spike")

            self.assertEqual(read_ticket(repo / ".orchestrator/RR-1.md")["execution_mode"], "implementation")
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-2.md")["execution_mode"], "spike")

    def test_foreground_action_can_author_refined_spike_directly(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / ".orchestrator").mkdir()
            (repo / ".orchestrator/config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            daemon = object.__new__(Daemon)

            ticket_id = daemon._create_orchestrator_ticket(repo, {
                "title": "Investigate parser boundaries",
                "priority": "high",
                "execution_mode": "spike",
                "description": "Determine the canonical parsing boundary without changing code.",
                "acceptance_criteria": ["Cite repository evidence."],
                "depends_on": [],
                "worker_model": "strong",
                "worker_effort": "high",
                "worker_sizing_rationale": "Cross-module research requires careful evidence review.",
                "worker_provider_notes": "Codex and Claude use equivalent branchless read-only contracts.",
            })

            ticket = read_ticket(repo / ".orchestrator" / f"{ticket_id}.md")
            self.assertEqual(ticket["execution_mode"], "spike")
            self.assertEqual(ticket["status"], "backlog")
            self.assertNotIn("raw transcript", ticket["body"].lower())

    def test_provider_commands_enforce_equivalent_read_only_spike_contract(self):
        git_environment = {
            "PATH": "/direct git/bin:/usr/bin:/bin",
            "RELAY_SPIKE_GIT": "/direct git/bin/git",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_NO_LAZY_FETCH": "1",
        }
        codex = orchestrator._agent_command(
            agent_kind="codex",
            agent_bin="codex",
            run={"execution_mode": "spike", "result_schema_path": "/tmp/schema.json",
                 "spike_git_environment": git_environment},
        )
        claude = orchestrator._agent_command(
            agent_kind="claude",
            agent_bin="claude",
            run={"execution_mode": "spike"},
        )

        self.assertIn("read-only", codex)
        self.assertLess(codex.index("--search"), codex.index("exec"))
        self.assertIn("--ignore-user-config", codex)
        self.assertIn("--output-schema", codex)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", codex)
        self.assertIn('approval_policy="never"', codex)
        self.assertIn("allow_login_shell=false", codex)
        self.assertIn("features.shell_snapshot=false", codex)
        self.assertIn("shell_environment_policy.experimental_use_profile=false", codex)
        for key, value in git_environment.items():
            self.assertIn(f"shell_environment_policy.set.{key}={json.dumps(value)}", codex)
        with self.assertRaisesRegex(RuntimeError, "verified read-only Git environment"):
            orchestrator._agent_command(
                agent_kind="codex", agent_bin="codex",
                run={"execution_mode": "spike", "result_schema_path": "/tmp/schema.json"},
            )
        self.assertIn("Read,Glob,Grep,WebSearch,WebFetch", claude)
        self.assertIn("--safe-mode", claude)
        self.assertIn("--strict-mcp-config", claude)
        self.assertEqual(claude[claude.index("--mcp-config") + 1], '{"mcpServers":{}}')
        self.assertNotIn("--dangerously-skip-permissions", claude)
        self.assertNotIn("Bash", ",".join(claude))

        prompt = Daemon._build_spike_prompt(
            ticket={"id": "RR-1", "title": "Research", "body": "Evidence only."},
            repo_path="/repo",
            workspace_path="/snapshot",
            attempt=1,
            run_id=7,
        )
        self.assertIn("designated terminal structured result", prompt)
        self.assertIn("daemon validates it and is the sole process allowed", prompt)
        self.assertIn("may not draft or accept canonical tickets", prompt)
        self.assertIn('"$RELAY_SPIKE_GIT" rev-parse HEAD', prompt)
        self.assertIn("native public web-search tool", prompt)
        self.assertIn("curl -q", prompt)
        self.assertIn("full pinned commit revision", prompt)
        self.assertIn("research_access.status", prompt)
        self.assertIn("login=false", prompt)
        self.assertIn("do not start a login shell", prompt)
        claude_prompt = Daemon._build_spike_prompt(
            ticket={"id": "RR-1", "title": "Research", "body": "Evidence only."},
            repo_path="/repo", workspace_path="/snapshot", attempt=1, run_id=7,
            agent_kind="claude",
        )
        self.assertIn("Read, Glob, Grep, WebSearch, and WebFetch", claude_prompt)
        self.assertIn("HTTPS commit/raw-file URLs", claude_prompt)
        self.assertNotIn("RELAY_SPIKE_GIT", claude_prompt)

    def test_implementation_and_review_commands_keep_default_research_tools(self):
        codex = orchestrator._agent_command(
            agent_kind="codex", agent_bin="codex", run={"execution_mode": "implementation"}
        )
        claude = orchestrator._agent_command(
            agent_kind="claude", agent_bin="claude", run={"execution_mode": "implementation"}
        )

        self.assertLess(codex.index("--search"), codex.index("exec"))
        self.assertIn("--dangerously-bypass-approvals-and-sandbox", codex)
        self.assertNotIn("--tools", claude)
        self.assertIn("--dangerously-skip-permissions", claude)

    def test_spike_workspace_is_detached_branchless_read_only_and_removable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "spike"
            self.make_repo(repo)
            (repo / "source.txt").write_text("evidence\n")
            self.git(repo, "add", "source.txt")
            self.git(repo, "commit", "-m", "source")
            self.git(repo, "branch", "-M", "main")
            before = self.git(repo, "branch", "--format=%(refname:short)").stdout.splitlines()

            create_spike_workspace(
                repo_path=str(repo), workspace_path=workspace, base_branch="main"
            )

            self.assertNotEqual(
                self.git(workspace, "symbolic-ref", "-q", "HEAD", check=False).returncode,
                0,
            )
            self.assertEqual(
                self.git(repo, "branch", "--format=%(refname:short)").stdout.splitlines(),
                before,
            )
            self.assertEqual(self.git(workspace, "remote").stdout.strip(), "")
            self.assertEqual((workspace / "source.txt").stat().st_mode & 0o222, 0)

            removed, error = remove_spike_workspace(workspace)
            self.assertTrue(removed)
            self.assertIsNone(error)

    def test_dispatch_and_completion_create_no_worker_branch_or_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_repo(repo)
            self.write_ticket(repo, "RR-1", mode="spike")
            self.write_ticket(repo, "RR-2", mode="implementation", depends_on=["RR-1"], status="backlog")
            self.git(repo, "add", ".orchestrator/RR-1.md", ".orchestrator/RR-2.md")
            self.git(repo, "commit", "-m", "tickets")
            self.git(repo, "branch", "-M", "main")
            daemon = self.make_daemon(root)

            with patch.object(Worker, "start") as start, \
                    patch.object(daemon, "dispatch_review_worker") as review:
                dispatched = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))
                run = dispatched["run"]
                worker = daemon._workers[run["id"]]
                worker.spike_result = self.result()
                daemon.runs.update(run["id"], state="SpikeResultReady", ended=True, exit_code=0)
                daemon._on_worker_complete(run["id"])

            start.assert_called_once()
            review.assert_not_called()
            completed = daemon.runs.get(run["id"]) or {}
            self.assertEqual(completed["state"], "SpikeCompleted")
            self.assertEqual(completed["branch"], "")
            self.assertEqual(completed["execution_mode"], "spike")
            self.assertFalse(Path(completed["workspace_path"]).exists())
            self.assertNotIn("relay/rr-1", self.git(repo, "branch", "--format=%(refname:short)").stdout)
            ticket = read_ticket(repo / ".orchestrator/RR-1.md")
            self.assertEqual(ticket["status"], "done")
            self.assertEqual(ticket["run_id"], run["id"])
            self.assertIn("## Spike report", ticket["body"])
            self.assertIn("**Conclusions**", ticket["body"])
            self.assertNotIn("chain-of-thought", ticket["body"])
            self.assertEqual(
                self.git(repo, "show", "-s", "--format=%s", "HEAD").stdout.strip(),
                f"docs(RR-1): record spike run {run['id']}",
            )

            daemon._promote_unblocked_dependents(repo_path=str(repo))
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-2.md")["status"], "backlog")

    def test_incomplete_spike_returns_to_backlog_with_exact_retry_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_repo(repo)
            self.write_ticket(repo, "RR-1", mode="spike")
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "ticket")
            self.git(repo, "branch", "-M", "main")
            daemon = self.make_daemon(root)

            with patch.object(Worker, "start"):
                run = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))["run"]
            daemon.runs.update(
                run["id"], state="Failed", last_error="provider returned no valid structured spike result", ended=True
            )
            daemon._on_worker_complete(run["id"])

            ticket = read_ticket(repo / ".orchestrator/RR-1.md")
            self.assertEqual(ticket["status"], "backlog")
            self.assertIsNone(ticket["run_id"])
            self.assertIn("provider returned no valid structured spike result", ticket["body"])
            self.assertFalse(Path(run["workspace_path"]).exists())

            with patch.object(Worker, "start"):
                retried = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))["run"]
            self.assertEqual(retried["attempt"], 2)
            daemon._workers.pop(retried["id"])
            canceled = daemon.cancel_run(retried["id"])

            self.assertTrue(canceled["canceled"])
            self.assertFalse(Path(retried["workspace_path"]).exists())
            ticket = read_ticket(repo / ".orchestrator/RR-1.md")
            self.assertEqual(ticket["status"], "backlog")
            self.assertIsNone(ticket["run_id"])
            self.assertIn("Canceled by user", ticket["body"])

    def test_structured_results_are_sanitized_and_mutation_attempts_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "run.log"
            payload = self.result()
            log.write_text(json.dumps({
                "type": "item.completed",
                "item": {"type": "agent_message", "text": json.dumps(payload)},
            }) + "\n")
            self.assertEqual(extract_spike_result(log)["conclusions"], payload["conclusions"])

        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "run.log"
            valid = self.result()
            oversized = self.result()
            oversized["recommended_next_steps"] = [f"step {index}" for index in range(13)]
            log.write_text("\n".join([
                json.dumps({
                    "type": "item.completed",
                    "item": {"type": "agent_message", "text": json.dumps(valid)},
                }),
                json.dumps({
                    "type": "item.completed",
                    "item": {"type": "agent_message", "text": json.dumps(oversized)},
                }),
            ]) + "\n")
            with self.assertRaisesRegex(ValueError, "recommended_next_steps exceeds 12 items"):
                extract_spike_result(log)

        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "run.log"
            log.write_text("\n".join([
                json.dumps({"structured_output": self.result()}),
                json.dumps({
                    "type": "item.completed",
                    "item": {"type": "agent_message", "text": "not-json"},
                }),
            ]) + "\n")
            with self.assertRaisesRegex(ValueError, "terminal structured spike result is not valid JSON"):
                extract_spike_result(log)

        payload = self.result()
        payload["mutation_attempts"] = ["touch source.txt was blocked"]
        with self.assertRaisesRegex(ValueError, "blocked mutation"):
            validate_spike_result(payload)

        with tempfile.TemporaryDirectory() as tmp:
            store = RunsStore(Path(tmp) / "runs.db")
            run_id = store.insert(
                ticket_id="RR-1",
                repo_path="/repo",
                workspace_path="/snapshot",
                branch="",
                execution_mode="spike",
                state="Running",
            )
            worker = Worker(
                run_id=run_id,
                run=store.get(run_id) or {},
                prompt="",
                agent_bin="codex",
                agent_kind="codex",
                store=store,
                log_path=Path(tmp) / "run.log",
            )
            worker._handle_event(json.dumps({
                "type": "item.started",
                "item": {"id": "1", "type": "command_execution", "command": "touch source.txt"},
            }), 0)
            self.assertEqual(worker._spike_violation, "spike attempted a mutating command")

            worker = Worker(
                run_id=run_id,
                run=store.get(run_id) or {},
                prompt="",
                agent_bin="claude",
                agent_kind="claude",
                store=store,
                log_path=Path(tmp) / "run.log",
            )
            worker._handle_event(json.dumps({
                "type": "assistant",
                "message": {"content": [
                    {"type": "tool_use", "id": "web", "name": "WebFetch", "input": {}},
                ]},
            }), 0)
            self.assertIsNone(worker._spike_violation)
            worker._handle_event(json.dumps({
                "type": "assistant",
                "message": {"content": [
                    {"type": "tool_use", "id": "write", "name": "Write", "input": {}},
                ]},
            }), 0)
            self.assertEqual(worker._spike_violation, "spike attempted disallowed tool Write")

    def test_spike_null_output_does_not_mask_real_mutations(self):
        cases = {
            '/bin/zsh -lc "ls -l /usr/bin/git 2>/dev/null; xcode-select -p 2>/dev/null || true"': False,
            '/bin/zsh -lc "git show HEAD:README.md >/dev/null && echo tracked-at-head"': False,
            'grep pattern source.py 2>/dev/null | head -20': False,
            'git show HEAD:README.md >> /dev/null': False,
            'git show HEAD:README.md > result.txt': True,
            'git show HEAD:README.md > /dev/null.log': True,
            'git show HEAD:README.md > /dev/null/file': True,
            'git show HEAD:README.md >/dev/null; touch result.txt': True,
            'git show HEAD:README.md >/dev/null > result.txt': True,
            'curl -q https://example.com': False,
            'curl --disable --head https://example.com': False,
            '/usr/bin/curl -q -fsSL --max-time 10 https://example.com': False,
            '/bin/zsh -lc "curl -q --request HEAD https://example.com"': False,
            'grep curl services/orchestrator.py': False,
            '/bin/zsh -lc "grep curl services/orchestrator.py"': False,
            'curl https://example.com': True,
            'curl --silent -q https://example.com': True,
            'CURL_HOME=/tmp curl -q https://example.com': True,
            'env curl -q https://example.com': True,
            'command curl -q https://example.com': True,
            'curl -q https://example.com https://example.org': True,
            'git show HEAD:README.md >/dev/null; curl -q https://example.com': True,
            'curl -X POST https://example.com': True,
            'curl -XPOST https://example.com': True,
            'curl --request=PUT https://example.com': True,
            'curl --data name=value https://example.com': True,
            'curl -q -dsecret https://example.com': True,
            'curl -q -Ffile=@source.txt https://example.com': True,
            'curl -q -Tsource.txt https://example.com': True,
            'curl -q --json {"name":"value"} https://example.com': True,
            'wget --post-data=name=value https://example.com': True,
            'wget --method PATCH https://example.com': True,
            'git show HEAD:README.md >/dev/null; git commit -am change': True,
        }
        with tempfile.TemporaryDirectory() as tmp:
            store = RunsStore(Path(tmp) / 'runs.db')
            run_id = store.insert(ticket_id='RR-1', repo_path='/repo',
                                  workspace_path='/snapshot', branch='',
                                  execution_mode='spike', state='Running')
            for command, rejected in cases.items():
                with self.subTest(command=command):
                    worker = Worker(run_id=run_id, run=store.get(run_id), prompt='',
                                    agent_bin='codex', agent_kind='codex', store=store,
                                    log_path=Path(tmp) / 'run.log')
                    worker._handle_event(json.dumps({
                        'type': 'item.started',
                        'item': {'id': '1', 'type': 'command_execution', 'command': command},
                    }), 0)
                    self.assertEqual(bool(worker._spike_violation), rejected)

    def test_spike_denied_unknown_write_is_not_mistaken_for_research_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = RunsStore(Path(tmp) / "runs.db")
            run_id = store.insert(
                ticket_id="RR-1", repo_path="/repo", workspace_path="/snapshot",
                branch="", execution_mode="spike", state="Running",
            )

            read_worker = Worker(
                run_id=run_id, run=store.get(run_id) or {}, prompt="",
                agent_bin="codex", agent_kind="codex", store=store,
                log_path=Path(tmp) / "read.log",
            )
            read_worker._handle_event(json.dumps({
                "type": "item.started",
                "item": {
                    "id": "read", "type": "command_execution",
                    "command": "curl -q https://example.com/public-source",
                },
            }), 0)
            read_worker._handle_event(json.dumps({
                "type": "item.completed",
                "item": {
                    "id": "read", "type": "command_execution", "exit_code": 7,
                    "aggregated_output": "curl: operation not permitted",
                },
            }), 0)
            self.assertIsNone(read_worker._spike_violation)
            self.assertIn("read-only public research", read_worker._research_access_error)

            write_worker = Worker(
                run_id=run_id, run=store.get(run_id) or {}, prompt="",
                agent_bin="codex", agent_kind="codex", store=store,
                log_path=Path(tmp) / "write.log",
            )
            write_worker._handle_event(json.dumps({
                "type": "item.started",
                "item": {
                    "id": "write", "type": "command_execution",
                    "command": "python3 -c \"open('source.txt', 'w').write('changed')\"",
                },
            }), 0)
            write_worker._handle_event(json.dumps({
                "type": "item.completed",
                "item": {
                    "id": "write", "type": "command_execution", "exit_code": 1,
                    "aggregated_output": "Permission denied: 'source.txt'",
                },
            }), 0)
            self.assertEqual(
                write_worker._spike_violation,
                "spike command was blocked by mutation isolation",
            )

    def test_spike_provider_access_failure_is_public_and_actionable(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = RunsStore(Path(tmp) / "runs.db")
            run_id = store.insert(
                ticket_id="RR-1", repo_path=tmp, workspace_path=tmp,
                branch="", execution_mode="spike", state="Running",
            )
            worker = Worker(
                run_id=run_id,
                run=store.get(run_id) or {},
                prompt="",
                agent_bin="claude",
                agent_kind="claude",
                store=store,
                log_path=Path(tmp) / "run.log",
            )
            event = json.dumps({
                "type": "system",
                "subtype": "api_retry",
                "error_status": 401,
                "error": "authentication_failed",
            })
            command = [sys.executable, "-c", f"import sys; print({event!r}); sys.exit(1)"]
            with patch.object(worker, "_command", return_value=command):
                worker._run()

            self.assertEqual(
                store.get(run_id)["last_error"],
                "spike research access unavailable: provider authentication failed (HTTP 401); "
                "re-authenticate the provider and retry",
            )

    def test_schema_and_validator_share_structured_result_limits(self):
        schema = orchestrator.SPIKE_RESULT_SCHEMA["properties"]
        for field in ("conclusions", "evidence", "uncertainties", "recommended_next_steps"):
            self.assertEqual(schema[field]["maxItems"], 12)
        self.assertEqual(schema["conclusions"]["items"]["maxLength"], 600)
        self.assertEqual(schema["evidence"]["items"]["properties"]["source"]["maxLength"], 300)
        oversized = self.result()
        oversized["conclusions"] = ["x" * 601]
        with self.assertRaisesRegex(ValueError, "conclusions exceeds 600 characters"):
            validate_spike_result(oversized)

        external = self.result()
        external["research_access"] = {
            "status": "succeeded",
            "detail": "Public evidence was retrieved.",
        }
        with self.assertRaisesRegex(ValueError, "requires URL evidence"):
            validate_spike_result(external)

        failed = self.result()
        failed["research_access"] = {
            "status": "failed",
            "detail": "WebSearch was unavailable.",
        }
        failed["uncertainties"] = []
        with self.assertRaisesRegex(ValueError, "recorded as an uncertainty"):
            validate_spike_result(failed)

        legacy = self.result()
        del legacy["research_access"]
        self.assertEqual(
            validate_spike_result(legacy)["research_access"]["status"],
            "not_used",
        )

    def test_spike_report_persistence_blocks_dirty_ticket_overlap(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_repo(repo)
            self.write_ticket(repo, "RR-1", mode="spike", status="in_progress")
            ticket_path = repo / ".orchestrator/RR-1.md"
            ticket_path.write_text(ticket_path.read_text().replace("run_id: null", "run_id: 1"))
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "claim spike")
            ticket_path.write_text(ticket_path.read_text() + "\nUncommitted PM note.\n")
            daemon = self.make_daemon(root)

            with self.assertRaisesRegex(ValueError, "ticket authoring blocked by existing changes"):
                daemon._spike_ticket_update(
                    {
                        "id": 1,
                        "ticket_id": "RR-1",
                        "repo_path": str(repo),
                        "attempt": 1,
                        "provider_key": "codex",
                    },
                    result=self.result(),
                )

            self.assertIn("Uncommitted PM note.", ticket_path.read_text())
            self.assertEqual(self.git(repo, "show", "-s", "--format=%s", "HEAD").stdout.strip(), "claim spike")

    def test_version_four_run_ledger_migrates_without_losing_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "runs.db"
            with sqlite3.connect(db) as conn:
                conn.executescript(RunsStore.SCHEMA.replace(
                    "        execution_mode TEXT NOT NULL DEFAULT 'implementation',\n", ""
                ))
                conn.execute("PRAGMA user_version = 4")
                conn.execute(
                    "INSERT INTO runs(ticket_id, repo_path, workspace_path, branch, state, started_at) "
                    "VALUES ('RR-1', '/repo', '/workspace', 'relay/rr-1', 'Merged', 1)"
                )

            store = RunsStore(db)
            rows = store.list()
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["execution_mode"], "implementation")

    def test_restart_recovery_stops_and_cleans_branchless_spike(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "spike-1"
            self.make_repo(repo)
            self.write_ticket(repo, "RR-1", mode="spike", status="in_progress")
            ticket_path = repo / ".orchestrator/RR-1.md"
            raw = ticket_path.read_text().replace("run_id: null", "run_id: 1")
            ticket_path.write_text(raw)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "claim spike")
            workspace.mkdir(parents=True)
            (workspace / "snapshot.txt").write_text("evidence")
            daemon = self.make_daemon(root)
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo),
                workspace_path=str(workspace),
                branch="",
                execution_mode="spike",
                state="SpikeResultReady",
            )
            self.assertEqual(run_id, 1)

            self.assertEqual(daemon.runs.reconcile_on_startup(), 1)
            self.assertEqual(daemon.runs.get(run_id)["state"], "Stalled")
            daemon._recover_stalled_spikes()

            ticket = read_ticket(ticket_path)
            self.assertEqual(ticket["status"], "backlog")
            self.assertIsNone(ticket["run_id"])
            self.assertFalse(workspace.exists())

    def test_restart_recovery_commits_terminal_report_before_marking_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "spike-1"
            log_path = root / "run.log"
            self.make_repo(repo)
            self.write_ticket(repo, "RR-1", mode="spike", status="in_progress")
            ticket_path = repo / ".orchestrator/RR-1.md"
            ticket_path.write_text(ticket_path.read_text().replace("run_id: null", "run_id: 1"))
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "claim spike")
            workspace.mkdir(parents=True)
            log_path.write_text(json.dumps({
                "type": "item.completed",
                "item": {"type": "agent_message", "text": json.dumps(self.result())},
            }) + "\n")
            daemon = self.make_daemon(root)
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo),
                workspace_path=str(workspace),
                branch="",
                execution_mode="spike",
                state="SpikeResultReady",
                log_path=str(log_path),
            )
            self.assertEqual(run_id, 1)

            self.assertEqual(daemon.runs.reconcile_on_startup(), 1)
            daemon._recover_stalled_spikes()

            ticket = read_ticket(ticket_path)
            self.assertEqual(ticket["status"], "done")
            self.assertIn("**Recovery:** Restored from the terminal structured result", ticket["body"])
            self.assertEqual(daemon.runs.get(run_id)["state"], "SpikeCompleted")
            self.assertEqual(
                self.git(repo, "show", "-s", "--format=%s", "HEAD").stdout.strip(),
                "docs(RR-1): record spike run 1",
            )
            self.assertFalse(workspace.exists())

    @staticmethod
    def result() -> dict:
        return {
            "conclusions": ["The parser has one canonical entry point."],
            "evidence": [{"source": "services/tickets.py:79", "finding": "parse validates frontmatter."}],
            "uncertainties": ["Mounted UI behavior was not observed."],
            "recommended_next_steps": ["Create a separately reviewed implementation ticket."],
            "mutation_attempts": [],
            "research_access": {
                "status": "not_used",
                "detail": "The spike used only immutable local evidence.",
            },
        }

    def make_repo(self, repo: Path) -> None:
        (repo / ".orchestrator").mkdir(parents=True)
        self.git(repo, "init")
        self.git(repo, "config", "user.email", "relay@example.test")
        self.git(repo, "config", "user.name", "Relay Test")
        (repo / "README.md").write_text("repo\n")
        self.git(repo, "add", "README.md")
        self.git(repo, "commit", "-m", "initial")

    def make_daemon(self, root: Path) -> Daemon:
        daemon = object.__new__(Daemon)
        daemon.cfg = {}
        daemon.workspace_root = root / "workspaces"
        daemon.branch_prefix = "relay/"
        daemon.workflow_path = ROOT / "services" / "orchestrator_workflow.md"
        daemon.worker_health_check_seconds = 600
        daemon._run_health = {}
        daemon._run_health_lock = threading.Lock()
        daemon.port = 7634
        daemon.agent_kind = "codex"
        daemon.agent_bin = "codex"
        daemon.runs = RunsStore(root / "runs.db")
        daemon.messenger_outcomes = MessengerOutcomeStore(root / "messenger_outcomes.db")
        daemon._dispatch_lock = threading.Lock()
        daemon._ticket_authoring_lock = threading.Lock()
        daemon._workers = {}
        daemon._workers_lock = threading.Lock()
        daemon._review_workers = {}
        daemon._review_workers_lock = threading.Lock()
        return daemon

    def write_ticket(
        self,
        repo: Path,
        ticket_id: str,
        *,
        mode: str | None,
        status: str = "ready",
        depends_on: list[str] | None = None,
    ) -> None:
        mode_line = f"execution_mode: {mode}\n" if mode else ""
        deps = ", ".join(depends_on or [])
        (repo / ".orchestrator").mkdir(parents=True, exist_ok=True)
        (repo / ".orchestrator" / f"{ticket_id}.md").write_text(
            f"""---
id: {ticket_id}
title: Research parser behavior
status: {status}
priority: medium
{mode_line}depends_on: [{deps}]
run_id: null
canceled: false
worker_model: strong
worker_effort: high
worker_sizing_rationale: Cross-module lifecycle work.
worker_provider_notes: Codex and Claude enforce equivalent read-only spike behavior.
---

## Description

Determine how ticket parsing is structured.

## Acceptance criteria

- [ ] Cite local repository evidence.
"""
        )

    @staticmethod
    def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            capture_output=True,
            text=True,
            check=check,
        )


if __name__ == "__main__":
    unittest.main()
