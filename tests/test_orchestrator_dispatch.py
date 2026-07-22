from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from orchestrator import Daemon, MessengerOutcomeStore, ReviewWorker, RunsStore, Worker, validate_worker_completion  # noqa: E402
from tickets import read as read_ticket  # noqa: E402


class OrchestratorDispatchTests(unittest.TestCase):
    def test_root_workflow_file_does_not_override_ticket_worker_prompt(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            (repo / ".orchestrator").mkdir(parents=True)
            (repo / "WORKFLOW.md").write_text("# Mentistic Workflow\n\nUse stale production loop guidance.\n")

            daemon = object.__new__(Daemon)
            daemon.workflow_path = Path(ROOT) / "services" / "orchestrator_workflow.md"

            prompt = Daemon._build_prompt(
                daemon,
                ticket_id="RR-1",
                repo_path=str(repo),
                workspace_path=str(repo.parent / "workspaces" / "rr-1"),
                branch="relay/rr-1",
                attempt=2,
                run_id=17,
            )

            self.assertIn("Read `.orchestrator/RR-1.md`", prompt)
            self.assertIn(f"- Source repo path: `{repo}`", prompt)
            self.assertIn(f"- Assigned worktree cwd: `{repo.parent / 'workspaces' / 'rr-1'}`", prompt)
            self.assertIn("git branch --show-current` prints exactly `relay/rr-1`", prompt)
            self.assertIn("- Run ID: 17", prompt)
            self.assertNotIn("Mentistic Workflow", prompt)
            self.assertEqual(
                Daemon._resolve_workflow_for_repo(daemon, str(repo)),
                daemon.workflow_path,
            )

    def test_orchestrator_workflow_override_must_be_ticket_template(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            orch = repo / ".orchestrator"
            orch.mkdir(parents=True)
            override = orch / "WORKFLOW.md"
            override.write_text("# Project notes\n\nNo ticket variables here.\n")

            daemon = object.__new__(Daemon)
            daemon.workflow_path = Path(ROOT) / "services" / "orchestrator_workflow.md"

            with self.assertRaisesRegex(RuntimeError, "not an orchestrator ticket workflow"):
                Daemon._build_prompt(
                    daemon,
                    ticket_id="RR-1",
                    repo_path=str(repo),
                    workspace_path=str(repo.parent / "workspaces" / "rr-1"),
                    branch="relay/rr-1",
                    attempt=1,
                    run_id=9,
                )

    def test_codex_worker_runs_ephemeral_session(self):
        worker = object.__new__(Worker)
        worker.agent_kind = "codex"
        worker.agent_bin = "codex"
        worker.run = {}

        self.assertIn("--ephemeral", Worker._command(worker))

    def test_codex_worker_applies_model_and_reasoning_effort(self):
        worker = object.__new__(Worker)
        worker.agent_kind = "codex"
        worker.agent_bin = "codex"
        worker.run = {"model_alias": "gpt-5.5", "worker_effort": "high"}

        command = Worker._command(worker)

        self.assertIn("--model", command)
        self.assertIn("gpt-5.5", command)
        self.assertIn("--config", command)
        self.assertIn("model_reasoning_effort=high", command)
        self.assertNotIn("--effort", command)

    def test_claude_worker_applies_model_and_effort(self):
        worker = object.__new__(Worker)
        worker.agent_kind = "claude"
        worker.agent_bin = "claude"
        worker.run = {"model_alias": "sonnet", "worker_effort": "xhigh"}

        command = Worker._command(worker)

        self.assertIn("--model", command)
        self.assertIn("sonnet", command)
        self.assertIn("--effort", command)
        self.assertIn("xhigh", command)
        self.assertNotIn("model_reasoning_effort=xhigh", command)

    def test_review_worker_uses_same_provider_effort_flags(self):
        codex = object.__new__(ReviewWorker)
        codex.agent_kind = "codex"
        codex.agent_bin = "codex"
        codex.run = {"model_alias": "gpt-5.5", "worker_effort": "high"}

        claude = object.__new__(ReviewWorker)
        claude.agent_kind = "claude"
        claude.agent_bin = "claude"
        claude.run = {"model_alias": "sonnet", "worker_effort": "xhigh"}

        self.assertIn("model_reasoning_effort=high", ReviewWorker._command(codex))
        self.assertIn("--effort", ReviewWorker._command(claude))
        self.assertIn("xhigh", ReviewWorker._command(claude))

    def test_dispatch_refuses_ready_ticket_missing_worker_sizing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=False)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker, \
                    self.assertRaisesRegex(ValueError, "missing worker sizing metadata"):
                daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            runs = daemon.runs.list()
            self.assertEqual(len(runs), 1)
            self.assertEqual(runs[0]["state"], "Failed")
            self.assertEqual(runs[0]["provider_key"], "codex")
            self.assertIn("worker_model", runs[0]["last_error"])

    def test_ready_sweeper_refuses_missing_worker_sizing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=False)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            self.assertEqual(result["dispatched"], [])
            self.assertEqual(result["skipped"][0]["ticket_id"], "RR-1")
            self.assertEqual(result["skipped"][0]["reason"], "dispatch_failed")
            self.assertIn("missing worker sizing metadata", result["skipped"][0]["error"])

    def test_dispatch_applies_user_default_worker_sizing_to_ready_ticket(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=False)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")
            daemon.cfg = {
                "general": {
                    "subagent_sizing_policy": "user_default",
                    "model": "gpt-5.6-sol",
                    "subagent_model": "strong",
                    "subagent_effort": "high",
                }
            }

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            run = result["run"]
            self.assertEqual(run["model_alias"], "gpt-5.6-sol")
            self.assertEqual(run["worker_model"], "strong")
            self.assertEqual(run["worker_effort"], "high")
            ticket = read_ticket(repo / ".orchestrator/RR-1.md")
            self.assertEqual(ticket["_raw_fields"]["worker_model"], "strong")
            self.assertEqual(ticket["_raw_fields"]["worker_effort"], "high")

    def test_ready_sweeper_applies_user_default_worker_sizing_to_ready_ticket(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=False)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")
            daemon.cfg = {
                "general": {
                    "subagent_sizing_policy": "user_default",
                    "model": "gpt-5.5",
                    "subagent_model": "strong",
                    "subagent_effort": "xhigh",
                }
            }

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            self.assertEqual(result["dispatched"][0]["ticket_id"], "RR-1")
            ticket = read_ticket(repo / ".orchestrator/RR-1.md")
            self.assertEqual(ticket["_raw_fields"]["worker_model"], "strong")
            self.assertEqual(ticket["_raw_fields"]["worker_effort"], "xhigh")
            self.assertIn(
                "Codex uses model_reasoning_effort and Claude uses --effort",
                ticket["_raw_fields"]["worker_provider_notes"],
            )

    def test_user_default_worker_sizing_preserves_explicit_ticket_sizing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(
                repo,
                "RR-1",
                status="ready",
                run_id=None,
                sizing=True,
                worker_model="fast",
                worker_effort="low",
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")
            daemon.cfg = {
                "general": {
                    "subagent_sizing_policy": "user_default",
                    "model": "gpt-5.6-sol",
                    "subagent_model": "strong",
                    "subagent_effort": "high",
                }
            }

            with patch("orchestrator.create_worktree"), patch.object(Worker, "start"):
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            self.assertEqual(result["run"]["model_alias"], "gpt-5.4-mini")
            self.assertEqual(result["run"]["worker_model"], "fast")
            self.assertEqual(result["run"]["worker_effort"], "low")
            ticket = read_ticket(repo / ".orchestrator/RR-1.md")
            self.assertEqual(ticket["_raw_fields"]["worker_model"], "fast")
            self.assertEqual(ticket["_raw_fields"]["worker_effort"], "low")

    def test_dispatch_records_valid_codex_sizing_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(
                repo,
                "RR-1",
                status="ready",
                run_id=None,
                sizing=True,
                worker_model="strong",
                worker_effort="high",
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            run = result["run"]
            self.assertEqual(run["state"], "Claimed")
            self.assertEqual(run["provider_key"], "codex")
            self.assertEqual(run["model_alias"], "gpt-5.5")
            self.assertEqual(run["worker_model"], "strong")
            self.assertEqual(run["worker_effort"], "high")
            self.assertIn("Cross-provider", run["worker_sizing_rationale"])

    def test_dispatch_records_valid_claude_sizing_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(
                repo,
                "RR-1",
                status="ready",
                run_id=None,
                sizing=True,
                worker_model="balanced",
                worker_effort="xhigh",
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="claude")

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            run = result["run"]
            self.assertEqual(run["provider_key"], "claude")
            self.assertEqual(run["model_alias"], "sonnet")
            self.assertEqual(run["worker_effort"], "xhigh")

    def test_dispatch_materializes_untracked_ticket_snapshot_before_worker_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / "code.txt").write_text("base\n")
            self.git(repo, "add", "code.txt")
            self.git(repo, "commit", "-m", "base")
            self.git(repo, "branch", "-M", "main")
            self.write_ticket(
                repo,
                "RR-1",
                status="ready",
                run_id=None,
                sizing=True,
                body="## Description\n\nUntracked dispatch snapshot.\n",
            )
            daemon = self.make_daemon(root, provider="codex")

            with patch.object(Worker, "start") as start_worker:
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            start_worker.assert_called_once()
            workspace_ticket = Path(result["run"]["workspace_path"]) / ".orchestrator/RR-1.md"
            self.assertTrue(workspace_ticket.is_file())
            self.assertEqual(workspace_ticket.read_text(), (repo / ".orchestrator/RR-1.md").read_text())
            self.assertFalse((Path(result["run"]["workspace_path"]) / ".orchestrator/config.toml").exists())

    def test_dispatch_materializes_uncommitted_ticket_edits(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(
                repo,
                "RR-1",
                status="ready",
                run_id=None,
                sizing=True,
                body="## Description\n\nCommitted prose.\n",
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            self.git(repo, "branch", "-M", "main")
            self.write_ticket(
                repo,
                "RR-1",
                status="ready",
                run_id=None,
                sizing=True,
                body="## Description\n\nEdited dispatch snapshot.\n",
            )
            daemon = self.make_daemon(root, provider="codex")

            with patch.object(Worker, "start"):
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            workspace_ticket = Path(result["run"]["workspace_path"]) / ".orchestrator/RR-1.md"
            self.assertIn("Edited dispatch snapshot.", workspace_ticket.read_text())
            self.assertNotIn("Committed prose.", workspace_ticket.read_text())

    def test_dispatch_does_not_start_worker_when_ticket_snapshot_materialization_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch("orchestrator._materialize_ticket_snapshot", side_effect=RuntimeError("ticket snapshot materialization failed")), \
                    patch.object(Worker, "start") as start_worker, \
                    self.assertRaisesRegex(RuntimeError, "ticket snapshot materialization failed"):
                daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            create_worktree.assert_called_once()
            start_worker.assert_not_called()
            runs = daemon.runs.list()
            self.assertEqual(runs[0]["state"], "Failed")
            self.assertIn("ticket snapshot materialization failed", runs[0]["last_error"])

    def test_dispatch_uses_current_general_provider_after_daemon_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")
            daemon.cfg = {"general": {"provider": "codex"}}
            daemon.config_loader = lambda: {"general": {"provider": "claude"}}

            with patch("orchestrator._find_agent_bin", return_value="claude") as find_agent, \
                    patch("orchestrator.create_worktree"), \
                    patch.object(Worker, "start"):
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            find_agent.assert_called_once_with("claude")
            run = result["run"]
            self.assertEqual(run["provider_key"], "claude")
            self.assertEqual(run["model_alias"], "opus")
            self.assertEqual(daemon._workers[run["id"]].agent_kind, "claude")

    def test_explicit_orchestrator_agent_override_beats_general_provider_reload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")
            daemon.cfg = {
                "general": {"provider": "claude"},
                "orchestrator": {"agent": "codex"},
            }
            daemon.config_loader = lambda: {"general": {"provider": "claude"}}

            with patch("orchestrator.create_worktree"), patch.object(Worker, "start"):
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            self.assertEqual(result["run"]["provider_key"], "codex")
            self.assertEqual(result["run"]["model_alias"], "gpt-5.5")

    def test_ready_sweeper_holds_after_deterministic_failed_attempt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")
            failed = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(root / "workspaces" / "rr-1"),
                branch="relay/rr-1",
                state="Failed",
                attempt=1,
                provider_key="codex",
                model_alias="gpt-5.5",
            )
            daemon.runs.update(
                failed,
                ended=True,
                exit_code=1,
                last_error="worker exited 0 but did not complete ticket: ticket status is 'ready'",
            )

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            self.assertEqual(result["dispatched"], [])
            self.assertEqual(result["skipped"][0]["reason"], "dispatch_failed")
            self.assertIn("automatic retry circuit open", result["skipped"][0]["error"])
            self.assertEqual(len(daemon.runs.list()), 1)

    def test_ready_sweeper_backs_off_after_recent_transient_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")
            failed = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(root / "workspaces" / "rr-1"),
                branch="relay/rr-1",
                state="Failed",
                attempt=1,
                provider_key="codex",
                model_alias="gpt-5.5",
            )
            daemon.runs.update(failed, ended=True, exit_code=1, last_error="transient provider failure")

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            self.assertIn("automatic retry backoff active after attempt 1", result["skipped"][0]["error"])
            self.assertEqual(len(daemon.runs.list()), 1)

    def test_ready_sweeper_caps_automatic_retry_attempts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="claude")
            for attempt in range(1, 6):
                run_id = daemon.runs.insert(
                    ticket_id="RR-1",
                    repo_path=str(repo.resolve()),
                    workspace_path=str(root / "workspaces" / f"rr-1-{attempt}"),
                    branch="relay/rr-1",
                    state="Failed",
                    attempt=attempt,
                    provider_key="claude",
                    model_alias="sonnet",
                )
                daemon.runs.update(run_id, ended=True, exit_code=1, last_error=f"transient failure {attempt}")

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            self.assertIn("automatic retry exhausted after 5 attempts", result["skipped"][0]["error"])
            self.assertEqual(len(daemon.runs.list()), 5)

    def test_dispatch_skips_succeeded_run_awaiting_merge(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(root / "workspaces" / "rr-1"),
                branch="relay/rr-1",
                state="Succeeded",
                provider_key="claude",
                model_alias="sonnet",
            )
            daemon.runs.update(run_id, ended=True, exit_code=0)

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            self.assertTrue(result["already_active"])
            self.assertTrue(result["awaiting_merge"])
            self.assertEqual(result["run"]["id"], run_id)
            self.assertIn("awaiting merge", result["reason"])
            self.assertIn("explicitly reset", result["reason"])
            self.assertEqual(len(daemon.runs.list()), 1)

    def test_dispatch_allows_retry_after_failed_or_canceled_runs(self):
        for state in ("Failed", "Canceled"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                repo = root / "repo"
                self.make_git_repo(repo)
                self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
                self.git(repo, "add", ".orchestrator/RR-1.md")
                self.git(repo, "commit", "-m", "add ticket")
                daemon = self.make_daemon(root, provider="codex")
                run_id = daemon.runs.insert(
                    ticket_id="RR-1",
                    repo_path=str(repo.resolve()),
                    workspace_path=str(root / "workspaces" / "rr-1"),
                    branch="relay/rr-1",
                    state=state,
                    provider_key="codex",
                    model_alias="gpt-5.5",
                )
                daemon.runs.update(run_id, ended=True, exit_code=1)

                with patch("orchestrator.create_worktree") as create_worktree, \
                        patch.object(Worker, "start") as start_worker:
                    result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

                create_worktree.assert_called_once()
                start_worker.assert_called_once()
                self.assertFalse(result["already_active"])
                self.assertEqual(result["run"]["state"], "Claimed")

    def test_dependency_progression_holds_dependent_missing_worker_sizing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="done", run_id=7, sizing=True)
            self.write_ticket(
                repo,
                "RR-2",
                status="backlog",
                run_id=None,
                depends_on=["RR-1"],
                sizing=False,
            )
            self.git(repo, "add", ".orchestrator/RR-1.md", ".orchestrator/RR-2.md")
            self.git(repo, "commit", "-m", "add tickets")
            daemon = self.make_daemon(root, provider="codex")

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                daemon._progress_dependents(repo_path=str(repo), finished_ticket_id="RR-1")

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            dependent = read_ticket(repo / ".orchestrator/RR-2.md")
            self.assertEqual(dependent["status"], "ready")
            runs = daemon.runs.list()
            self.assertEqual(runs[0]["state"], "Failed")
            self.assertIn("missing worker sizing metadata", runs[0]["last_error"])

    def test_orchestrator_actions_create_ticket_bump_config_and_dispatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            self.git(repo, "add", ".orchestrator/config.toml")
            self.git(repo, "commit", "-m", "add config")
            daemon = self.make_daemon(root, provider="codex")
            actions = [
                {
                    "kind": "create_ticket",
                    "title": "Implement refined login retry fix",
                    "description": "Add bounded retry handling for login failures.",
                    "acceptance_criteria": [
                        "Login retries stop after the configured limit.",
                        "The existing login tests cover the retry failure path.",
                    ],
                    "priority": "high",
                    "worker_model": "strong",
                    "worker_effort": "high",
                    "worker_sizing_rationale": "Touches auth flow and test coverage.",
                    "worker_provider_notes": "Codex uses model_reasoning_effort; Claude uses --effort.",
                },
                {
                    "kind": "request_worker",
                    "ticket_id": "RR-1",
                    "dependency_assumptions": [],
                    "worker_model": "strong",
                    "worker_effort": "high",
                    "dispatcher_context": "Use only the refined ticket content.",
                },
            ]

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.apply_orchestrator_actions(
                    repo_path=str(repo),
                    actions=actions,
                    request_id="req-1",
                )

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            self.assertEqual((repo / ".orchestrator" / "config.toml").read_text(), 'prefix = "RR"\nnext_id = 2\n')
            ticket = read_ticket(repo / ".orchestrator/RR-1.md")
            self.assertEqual(ticket["status"], "ready")
            self.assertEqual(ticket["_raw_fields"]["worker_model"], "strong")
            self.assertEqual(ticket["_raw_fields"]["worker_effort"], "high")
            self.assertIn("Add bounded retry handling", ticket["body"])
            self.assertNotIn("dispatch the refined plan", ticket["body"])
            self.assertEqual(result["dispatch_requests"][0]["worker_model"], "strong")
            self.assertEqual(result["dispatches"][0]["ticket_id"], "RR-1")
            self.assertEqual(result["dispatches"][0]["already_active"], False)
            self.assertEqual(result["skipped"], [])
            self.assertEqual(daemon.runs.list()[0]["worker_effort"], "high")

    def test_orchestrator_actions_explicit_ticket_id_advances_config_counter(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            daemon = self.make_daemon(root, provider="codex")

            daemon.apply_orchestrator_actions(repo_path=str(repo), actions=[{
                "kind": "create_ticket",
                "ticket_id": "RR-4",
                "title": "Explicit ticket",
                "description": "Create a specific ticket id.",
                "acceptance_criteria": ["The counter advances past the explicit id."],
                "worker_model": "fast",
                "worker_effort": "low",
                "worker_sizing_rationale": "Small explicit ticket.",
                "worker_provider_notes": "Codex uses model_reasoning_effort; Claude uses --effort.",
            }])

            self.assertTrue((repo / ".orchestrator/RR-4.md").exists())
            self.assertEqual((repo / ".orchestrator/config.toml").read_text(), 'prefix = "RR"\nnext_id = 5\n')

    def test_orchestrator_actions_multi_ticket_fanout_respects_dependencies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 3\n')
            self.git(repo, "add", ".orchestrator/config.toml")
            self.git(repo, "commit", "-m", "add config")
            daemon = self.make_daemon(root, provider="claude")
            base_action = {
                "priority": "high",
                "worker_model": "balanced",
                "worker_effort": "xhigh",
                "worker_sizing_rationale": "Provider-neutral fanout with explicit sizing.",
                "worker_provider_notes": "Codex uses model_reasoning_effort; Claude uses --effort.",
            }
            actions = [
                {
                    **base_action,
                    "kind": "create_ticket",
                    "ticket_id": "RR-1",
                    "title": "Prepare protocol",
                    "description": "Add the protocol foundation.",
                    "acceptance_criteria": ["Protocol tests pass."],
                },
                {
                    **base_action,
                    "kind": "create_ticket",
                    "ticket_id": "RR-2",
                    "title": "Use protocol",
                    "description": "Use the protocol after RR-1 lands.",
                    "acceptance_criteria": ["Dependent tests pass."],
                    "depends_on": ["RR-1"],
                },
                {
                    "kind": "request_worker",
                    "ticket_id": "RR-1",
                    "dependency_assumptions": [],
                    "worker_model": "balanced",
                    "worker_effort": "xhigh",
                },
                {
                    "kind": "request_worker",
                    "ticket_id": "RR-2",
                    "dependency_assumptions": ["RR-1"],
                    "worker_model": "balanced",
                    "worker_effort": "xhigh",
                },
            ]

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.apply_orchestrator_actions(
                    repo_path=str(repo),
                    actions=actions,
                )

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            self.assertEqual(result["dispatches"][0]["ticket_id"], "RR-1")
            self.assertEqual(result["skipped"], [{"ticket_id": "RR-2", "reason": "dependencies_not_done"}])
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-1.md")["status"], "ready")
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-2.md")["status"], "ready")
            self.assertEqual(daemon.runs.list()[0]["provider_key"], "claude")
            self.assertEqual(daemon.runs.list()[0]["worker_effort"], "xhigh")

    def test_orchestrator_actions_reject_duplicate_request_id_without_rewriting(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            daemon = self.make_daemon(root, provider="codex")
            actions = [{
                "kind": "create_ticket",
                "title": "One refined ticket",
                "description": "Structured description.",
                "acceptance_criteria": ["The ticket is written once."],
                "worker_model": "fast",
                "worker_effort": "low",
                "worker_sizing_rationale": "Small ticket.",
                "worker_provider_notes": "Codex uses model_reasoning_effort; Claude uses --effort.",
            }]

            daemon.apply_orchestrator_actions(repo_path=str(repo), actions=actions, request_id="dup-1")

            with self.assertRaisesRegex(ValueError, "duplicate orchestrator action request"):
                daemon.apply_orchestrator_actions(repo_path=str(repo), actions=actions, request_id="dup-1")

            self.assertTrue((repo / ".orchestrator/RR-1.md").exists())
            self.assertFalse((repo / ".orchestrator/RR-2.md").exists())

    def test_orchestrator_actions_reject_stale_relay_command_before_ticket_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            daemon = self.make_daemon(root, provider="codex")
            actions = [{
                "kind": "create_ticket",
                "title": "Stale ticket",
                "description": "This must not be written.",
                "acceptance_criteria": ["No ticket file is created."],
                "worker_model": "fast",
                "worker_effort": "low",
                "worker_sizing_rationale": "Small ticket.",
                "worker_provider_notes": "Codex uses model_reasoning_effort; Claude uses --effort.",
            }]

            with self.assertRaisesRegex(ValueError, "stale Relay command"):
                daemon.apply_orchestrator_actions(
                    repo_path=str(repo),
                    actions=actions,
                    relay_command_seq=1,
                    relay_command_id="old",
                )

            self.assertFalse((repo / ".orchestrator/RR-1.md").exists())
            self.assertEqual((repo / ".orchestrator/config.toml").read_text(), 'prefix = "RR"\nnext_id = 1\n')

    def test_exit_zero_noop_is_not_successful_ticket_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            start_head = self.git(repo, "rev-parse", "HEAD").stdout.strip()

            ok, reason = validate_worker_completion(
                workspace_path=str(repo),
                ticket_id="RR-1",
                run_id=42,
                start_head=start_head,
            )

            self.assertFalse(ok)
            self.assertIn("worker made no new commit", reason)
            self.assertIn("ticket status is 'ready'", reason)

    def test_done_ticket_with_run_log_and_new_commit_is_successful_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="in_progress", run_id=42)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "claim ticket")
            start_head = self.git(repo, "rev-parse", "HEAD").stdout.strip()

            self.write_ticket(
                repo,
                "RR-1",
                status="done",
                run_id=42,
                body="## Run log\n\n- **Run 42** (attempt 1) - branch `relay/rr-1`\n",
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "docs(RR-1): run 42 log")

            ok, reason = validate_worker_completion(
                workspace_path=str(repo),
                ticket_id="RR-1",
                run_id=42,
                start_head=start_head,
            )

            self.assertTrue(ok, reason)

    def test_done_ticket_left_uncommitted_is_not_successful_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="in_progress", run_id=42)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "claim ticket")
            start_head = self.git(repo, "rev-parse", "HEAD").stdout.strip()

            (repo / "code.txt").write_text("changed\n")
            self.git(repo, "add", "code.txt")
            self.git(repo, "commit", "-m", "feat: change code")
            self.write_ticket(
                repo,
                "RR-1",
                status="done",
                run_id=42,
                body="## Run log\n\n- **Run 42** (attempt 1) - branch `relay/rr-1`\n",
            )

            ok, reason = validate_worker_completion(
                workspace_path=str(repo),
                ticket_id="RR-1",
                run_id=42,
                start_head=start_head,
            )

            self.assertFalse(ok)
            self.assertIn("ticket completion is not committed", reason)

    def test_inspect_run_for_review_returns_branch_logs_and_diff_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            self.git(repo, "worktree", "add", "-b", "relay/rr-1", str(workspace), "HEAD")
            daemon = self.make_daemon(root, provider="codex")
            log_path = workspace / ".relay" / "run.log"
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="AwaitingReview",
                log_path=str(log_path),
                provider_key="codex",
                model_alias="gpt-5.5",
            )
            log_path.parent.mkdir()
            log_path.write_text("[orchestrator] worker completion validation passed\npytest ok\n")
            self.write_ticket(
                workspace,
                "RR-1",
                status="done",
                run_id=run_id,
                body=f"## Run log\n\n- **Run {run_id}** (attempt 1) - branch `relay/rr-1`\n",
            )
            (workspace / "code.txt").write_text("worker change\n")
            self.git(workspace, "add", ".orchestrator/RR-1.md", "code.txt")
            self.git(workspace, "commit", "-m", "feat: finish RR-1")

            result = daemon.inspect_run_for_review(run_id)

            self.assertTrue(result["review_needed"])
            self.assertEqual(result["ticket_status"], "done")
            self.assertIn("pytest ok", result["log_tail"])
            self.assertIn(f"Run {run_id}", result["ticket_run_log"])
            self.assertIn("feat: finish RR-1", result["branch_commits"])
            self.assertIn("code.txt", result["branch_diff_name_status"])
            self.assertEqual(result["verification_evidence"], "worker completion validation passed")

    def test_worker_completion_dispatches_review_worker(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            self.git(repo, "worktree", "add", "-b", "relay/rr-1", str(workspace), "HEAD")

            daemon = self.make_daemon(root, provider="codex")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="AwaitingReview",
                provider_key="codex",
                model_alias="gpt-5.5",
                worker_model="strong",
                worker_effort="high",
            )

            with patch.object(daemon, "dispatch_review_worker") as dispatch_review_worker:
                daemon._on_worker_complete(run_id)

            dispatch_review_worker.assert_called_once_with(run_id, source="worker-completion")

    def test_worker_completion_does_not_progress_dependents_before_review_merge(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.write_ticket(repo, "RR-2", status="backlog", run_id=None, depends_on=["RR-1"], sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md", ".orchestrator/RR-2.md")
            self.git(repo, "commit", "-m", "add tickets")
            daemon = self.make_daemon(root, provider="codex")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(root / "workspaces" / "rr-1"),
                branch="relay/rr-1",
                state="AwaitingReview",
                provider_key="codex",
                model_alias="gpt-5.5",
                worker_model="strong",
                worker_effort="high",
            )
            dispatches: list[dict] = []
            daemon.dispatch = lambda **kwargs: dispatches.append(kwargs)

            with patch.object(daemon, "dispatch_review_worker") as dispatch_review_worker:
                daemon._on_worker_complete(run_id)

            dispatch_review_worker.assert_called_once_with(run_id, source="worker-completion")
            self.assertEqual(dispatches, [])
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-2.md")["status"], "backlog")

    def test_dispatch_review_worker_carries_branch_context_and_marks_reviewing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            self.git(repo, "worktree", "add", "-b", "relay/rr-1", str(workspace), "HEAD")
            daemon = self.make_daemon(root, provider="claude")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="AwaitingReview",
                log_path=str(workspace / ".relay" / "run.log"),
                provider_key="codex",
                model_alias="gpt-5.5",
                worker_model="strong",
                worker_effort="high",
                worker_provider_notes="Codex uses model_reasoning_effort; Claude uses --effort.",
            )
            self.write_ticket(
                workspace,
                "RR-1",
                status="done",
                run_id=run_id,
                body=f"## Run log\n\n- **Run {run_id}** (attempt 1) - branch `relay/rr-1`\n",
            )
            (workspace / "code.txt").write_text("worker change\n")
            self.git(workspace, "add", ".orchestrator/RR-1.md", "code.txt")
            self.git(workspace, "commit", "-m", "feat: finish RR-1")

            with patch.object(ReviewWorker, "start") as start_worker:
                result = daemon.dispatch_review_worker(
                    run_id,
                    source="test",
                    context="Run the focused Python tests.",
                )

            start_worker.assert_called_once()
            self.assertTrue(result["review_dispatched"])
            self.assertIn(run_id, daemon._review_workers)
            review_worker = daemon._review_workers[run_id]
            self.assertEqual(review_worker.agent_kind, "claude")
            self.assertIn(f"Review implementation worker run {run_id}", review_worker.prompt)
            self.assertIn("Implementation worker branch: `relay/rr-1`", review_worker.prompt)
            self.assertIn(f"/v1/runs/{run_id}/review/decision", review_worker.prompt)
            self.assertIn("Run the focused Python tests.", review_worker.prompt)

    def test_dispatch_review_worker_uses_current_general_provider(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            self.git(repo, "worktree", "add", "-b", "relay/rr-1", str(workspace), "HEAD")
            daemon = self.make_daemon(root, provider="codex")
            daemon.cfg = {"general": {"provider": "codex"}}
            daemon.config_loader = lambda: {"general": {"provider": "claude"}}
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="AwaitingReview",
                log_path=str(workspace / ".relay" / "run.log"),
                provider_key="codex",
                model_alias="gpt-5.5",
                worker_model="strong",
                worker_effort="high",
            )
            self.write_ticket(
                workspace,
                "RR-1",
                status="done",
                run_id=run_id,
                body=f"## Run log\n\n- **Run {run_id}** (attempt 1) - branch `relay/rr-1`\n",
            )
            (workspace / "code.txt").write_text("worker change\n")
            self.git(workspace, "add", ".orchestrator/RR-1.md", "code.txt")
            self.git(workspace, "commit", "-m", "feat: finish RR-1")

            with patch("orchestrator._find_agent_bin", return_value="claude") as find_agent, \
                    patch.object(ReviewWorker, "start"):
                result = daemon.dispatch_review_worker(run_id, source="test")

            find_agent.assert_called_once_with("claude")
            self.assertTrue(result["review_dispatched"])
            review_worker = daemon._review_workers[run_id]
            self.assertEqual(review_worker.agent_kind, "claude")
            self.assertIn("Review provider: `claude`", review_worker.prompt)

    def test_review_worker_failure_returns_run_to_awaiting_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            workspace.mkdir(parents=True)
            agent = root / "fake-agent.sh"
            agent.write_text("#!/bin/sh\necho review failed\nexit 7\n")
            os.chmod(agent, 0o755)
            daemon = self.make_daemon(root, provider="codex")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="Reviewing",
                log_path=str(workspace / ".relay" / "run.log"),
                provider_key="codex",
                model_alias="gpt-5.5",
                worker_effort="high",
            )
            run = daemon.runs.get(run_id)
            review = ReviewWorker(
                run_id=run_id,
                run=run,
                prompt="review prompt",
                agent_bin=str(agent),
                agent_kind="codex",
                store=daemon.runs,
                log_path=workspace / ".relay" / "run.log",
                timeout_seconds=30,
            )

            review._run()

            updated = daemon.runs.get(run_id)
            self.assertEqual(updated["state"], "AwaitingReview")
            self.assertIn("review worker failed: exit=7", updated["last_error"])

    def test_accept_worker_run_merges_prunes_and_progresses_dependents(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.write_ticket(repo, "RR-2", status="backlog", run_id=None, depends_on=["RR-1"], sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md", ".orchestrator/RR-2.md")
            self.git(repo, "commit", "-m", "add tickets")
            self.git(repo, "worktree", "add", "-b", "relay/rr-1", str(workspace), "HEAD")
            daemon = self.make_daemon(root, provider="claude")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="AwaitingReview",
                provider_key="claude",
                model_alias="sonnet",
            )
            self.write_ticket(
                workspace,
                "RR-1",
                status="done",
                run_id=run_id,
                body=f"## Run log\n\n- **Run {run_id}** (attempt 1) - branch `relay/rr-1`\n",
            )
            (workspace / "code.txt").write_text("worker change\n")
            self.git(workspace, "add", ".orchestrator/RR-1.md", "code.txt")
            self.git(workspace, "commit", "-m", "feat: finish RR-1")
            dispatches: list[dict] = []
            daemon.dispatch = lambda **kwargs: dispatches.append(kwargs) or {
                "already_active": False,
                "run": {"id": 99},
            }

            result = daemon.accept_worker_run(run_id)

            self.assertTrue(result["accepted"])
            self.assertEqual(result["run"]["state"], "Merged")
            self.assertFalse(workspace.exists())
            self.assertEqual(self.git(repo, "branch", "--list", "relay/rr-1").stdout.strip(), "")
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-1.md")["status"], "done")
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-2.md")["status"], "ready")
            self.assertEqual(dispatches, [{
                "ticket_id": "RR-2",
                "repo_path": str(repo.resolve()),
                "source": "dependency-progression",
            }])

    def test_accept_worker_run_records_merge_conflict_without_publishing_done(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            (repo / "code.txt").write_text("base\n")
            self.git(repo, "add", ".orchestrator/RR-1.md", "code.txt")
            self.git(repo, "commit", "-m", "add ticket")
            self.git(repo, "worktree", "add", "-b", "relay/rr-1", str(workspace), "HEAD")
            daemon = self.make_daemon(root, provider="codex")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="AwaitingReview",
                provider_key="codex",
                model_alias="gpt-5.5",
            )
            self.write_ticket(
                workspace,
                "RR-1",
                status="done",
                run_id=run_id,
                body=f"## Run log\n\n- **Run {run_id}** (attempt 1) - branch `relay/rr-1`\n",
            )
            (workspace / "code.txt").write_text("worker\n")
            self.git(workspace, "add", ".orchestrator/RR-1.md", "code.txt")
            self.git(workspace, "commit", "-m", "feat: finish RR-1")
            (repo / "code.txt").write_text("source\n")
            self.git(repo, "add", "code.txt")
            self.git(repo, "commit", "-m", "feat: source change")

            result = daemon.accept_worker_run(run_id)

            self.assertFalse(result["accepted"])
            self.assertEqual(result["run"]["state"], "MergeConflict")
            self.assertTrue(workspace.exists())
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-1.md")["status"], "ready")
            self.assertEqual(self.git(repo, "status", "--porcelain").stdout.strip(), "")
            pending = daemon.pending_messenger_outcomes(repo_path=str(repo), provider="claude")
            self.assertEqual(len(pending), 1)
            self.assertEqual(pending[0]["message"], f"RR-1 run {run_id} merge needs attention")

    def test_review_retry_prunes_rejected_branch_and_dispatches_fresh_attempt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            self.git(repo, "worktree", "add", "-b", "relay/rr-1", str(workspace), "HEAD")
            daemon = self.make_daemon(root, provider="codex")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="AwaitingReview",
                provider_key="codex",
                model_alias="gpt-5.5",
            )
            (workspace / "code.txt").write_text("needs retry\n")
            self.git(workspace, "add", "code.txt")
            self.git(workspace, "commit", "-m", "feat: incomplete work")

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.request_worker_retry(
                    run_id,
                    reason="missing verification evidence",
                    redispatch=True,
                )

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            self.assertFalse(workspace.exists())
            self.assertEqual(self.git(repo, "branch", "--list", "relay/rr-1").stdout.strip(), "")
            self.assertEqual(result["run"]["state"], "Failed")
            self.assertIn("missing verification evidence", result["run"]["last_error"])
            self.assertEqual(result["redispatched"]["run"]["state"], "Claimed")
            self.assertEqual(result["redispatched"]["run"]["attempt"], 2)

    def make_git_repo(self, repo: Path) -> None:
        (repo / ".orchestrator").mkdir(parents=True)
        self.git(repo, "init")
        self.git(repo, "config", "user.email", "relay@example.test")
        self.git(repo, "config", "user.name", "Relay Test")

    def make_daemon(self, root: Path, *, provider: str) -> Daemon:
        daemon = object.__new__(Daemon)
        daemon.cfg = {}
        daemon.workspace_root = root / "workspaces"
        daemon.branch_prefix = "relay/"
        daemon.workflow_path = Path(ROOT) / "services" / "orchestrator_workflow.md"
        daemon.worker_timeout = 30
        daemon.port = 7634
        daemon.agent_kind = provider
        daemon.agent_bin = provider
        daemon.runs = RunsStore(root / "runs.db")
        daemon.messenger_outcomes = MessengerOutcomeStore(root / "messenger_outcomes.db")
        daemon._dispatch_lock = threading.Lock()
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
        status: str,
        run_id: int | None,
        depends_on: list[str] | None = None,
        sizing: bool = False,
        worker_model: str = "strong",
        worker_effort: str = "high",
        body: str = "## Description\n\nTest ticket.\n",
    ) -> None:
        run_value = "null" if run_id is None else str(run_id)
        deps = "[" + ", ".join(depends_on or []) + "]"
        sizing_block = ""
        if sizing:
            sizing_block = f"""worker_model: {worker_model}
worker_effort: {worker_effort}
worker_sizing_rationale: "Cross-provider dispatch enforcement touches daemon launch and status surfaces."
worker_provider_notes: "Codex uses model_reasoning_effort; Claude uses --effort. No provider-specific limitation."
"""
        (repo / ".orchestrator" / f"{ticket_id}.md").write_text(
            f"""---
id: {ticket_id}
title: {ticket_id}
status: {status}
priority: medium
depends_on: {deps}
run_id: {run_value}
canceled: false
{sizing_block}---

{body}
"""
        )

    def git(self, repo: Path, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            capture_output=True,
            text=True,
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
