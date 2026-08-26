from __future__ import annotations

import json
import os
import json
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

import orchestrator  # noqa: E402
from orchestrator import (  # noqa: E402
    Daemon,
    MessengerOutcomeStore,
    ReviewWorker,
    RunsStore,
    Worker,
    validate_worker_completion,
    validate_worker_outcome,
)
from relay_authorization import (  # noqa: E402
    allowed_mutations_for_metadata,
    record_command_authorization,
    validate_and_mark_mutation,
)
from tickets import read as read_ticket  # noqa: E402


CODEX_MODEL_LIST_FIXTURE = json.dumps({
    "data": [
        {
            "id": "gpt-5.7-sol",
            "model": "gpt-5.7-sol",
            "hidden": False,
            "defaultReasoningEffort": "low",
            "supportedReasoningEfforts": [
                {"reasoningEffort": "low"},
                {"reasoningEffort": "medium"},
                {"reasoningEffort": "high"},
                {"reasoningEffort": "xhigh"},
            ],
        },
        {
            "id": "gpt-6.0-sol",
            "model": "gpt-6.0-sol",
            "hidden": False,
            "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": [
                {"reasoningEffort": "low"},
                {"reasoningEffort": "medium"},
                {"reasoningEffort": "high"},
                {"reasoningEffort": "xhigh"},
            ],
        },
        {
            "id": "gpt-6.0-terra",
            "model": "gpt-6.0-terra",
            "hidden": False,
            "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": [
                {"reasoningEffort": "low"},
                {"reasoningEffort": "medium"},
                {"reasoningEffort": "high"},
                {"reasoningEffort": "xhigh"},
            ],
        },
    ],
})


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
            self.assertIn("`.orchestrator/attachments/RR-1/`", prompt)
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
        worker.run = {"model_alias": "sol", "worker_effort": "high"}

        with patch.dict(os.environ, {"RELAY_CODEX_MODEL_LIST_JSON": CODEX_MODEL_LIST_FIXTURE}):
            command = Worker._command(worker)

        self.assertIn("--model", command)
        self.assertIn("gpt-6.0-sol", command)
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

    def test_claude_worker_omits_default_model_and_effort_sentinels(self):
        worker = object.__new__(Worker)
        worker.agent_kind = "claude"
        worker.agent_bin = "claude"
        worker.run = {"model_alias": "default", "worker_effort": "default"}

        command = Worker._command(worker)

        self.assertNotIn("--model", command)
        self.assertNotIn("--effort", command)
        self.assertNotIn("model_reasoning_effort=default", command)

    def test_worker_applies_effort_without_default_model_override(self):
        codex = object.__new__(Worker)
        codex.agent_kind = "codex"
        codex.agent_bin = "codex"
        codex.run = {"worker_effort": "high"}

        claude = object.__new__(Worker)
        claude.agent_kind = "claude"
        claude.agent_bin = "claude"
        claude.run = {"worker_effort": "high"}

        codex_command = Worker._command(codex)
        claude_command = Worker._command(claude)

        self.assertNotIn("--model", codex_command)
        self.assertIn("model_reasoning_effort=high", codex_command)
        self.assertNotIn("--model", claude_command)
        self.assertIn("--effort", claude_command)
        self.assertIn("high", claude_command)

    def test_review_worker_uses_same_provider_effort_flags(self):
        codex = object.__new__(ReviewWorker)
        codex.agent_kind = "codex"
        codex.agent_bin = "codex"
        codex.run = {"model_alias": "sol", "worker_effort": "high"}

        claude = object.__new__(ReviewWorker)
        claude.agent_kind = "claude"
        claude.agent_bin = "claude"
        claude.run = {"model_alias": "sonnet", "worker_effort": "xhigh"}

        with patch.dict(os.environ, {"RELAY_CODEX_MODEL_LIST_JSON": CODEX_MODEL_LIST_FIXTURE}):
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
                    "provider": "codex",
                    "model": "sol",
                    "subagent_model": "strong",
                    "subagent_effort": "high",
                    "orchestrator_effort": "high",
                }
            }

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            run = result["run"]
            self.assertEqual(run["model_alias"], "sol")
            self.assertEqual(run["worker_model"], "codex:sol")
            self.assertEqual(run["worker_effort"], "high")
            ticket = read_ticket(repo / ".orchestrator/RR-1.md")
            self.assertEqual(ticket["_raw_fields"]["worker_model"], "codex:sol")
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
                    "provider": "codex",
                    "model": "sol",
                    "subagent_model": "strong",
                    "subagent_effort": "xhigh",
                    "orchestrator_effort": "xhigh",
                }
            }

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            self.assertEqual(result["dispatched"][0]["ticket_id"], "RR-1")
            ticket = read_ticket(repo / ".orchestrator/RR-1.md")
            self.assertEqual(ticket["_raw_fields"]["worker_model"], "codex:sol")
            self.assertEqual(ticket["_raw_fields"]["worker_effort"], "xhigh")
            self.assertIn(
                "Use my defaults preserves explicit stable provider selections",
                ticket["_raw_fields"]["worker_provider_notes"],
            )

    def test_user_default_worker_sizing_overrides_explicit_ticket_sizing(self):
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
                    "provider": "codex",
                    "model": "sol",
                    "subagent_model": "strong",
                    "subagent_effort": "high",
                    "orchestrator_effort": "high",
                }
            }

            with patch("orchestrator.create_worktree"), patch.object(Worker, "start"):
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            self.assertEqual(result["run"]["model_alias"], "sol")
            self.assertEqual(result["run"]["worker_model"], "codex:sol")
            self.assertEqual(result["run"]["worker_effort"], "high")
            ticket = read_ticket(repo / ".orchestrator/RR-1.md")
            self.assertEqual(ticket["_raw_fields"]["worker_model"], "codex:sol")
            self.assertEqual(ticket["_raw_fields"]["worker_effort"], "high")

    def test_user_default_legacy_codex_defaults_migrate_to_sol_xhigh(self):
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
            daemon.cfg = {
                "general": {
                    "subagent_sizing_policy": "user_default",
                    "provider": "codex",
                    "model": "default",
                    "orchestrator_effort": "default",
                }
            }

            with patch("orchestrator.create_worktree"), patch.object(Worker, "start"):
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            self.assertEqual(result["run"]["model_alias"], "sol")
            self.assertEqual(result["run"]["worker_model"], "codex:sol")
            self.assertEqual(result["run"]["worker_effort"], "xhigh")
            with patch.dict(os.environ, {"RELAY_CODEX_MODEL_LIST_JSON": CODEX_MODEL_LIST_FIXTURE}):
                command = Worker(
                    run_id=result["run"]["id"],
                    run=result["run"],
                    prompt="",
                    agent_bin="codex",
                    agent_kind="codex",
                    store=daemon.runs,
                    log_path=Path(tmp) / "run.log",
                )._command()
            self.assertIn("--model", command)
            self.assertIn("gpt-6.0-sol", command)
            self.assertIn("model_reasoning_effort=xhigh", command)

    def test_user_default_inherits_claude_model_and_effort(self):
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
            daemon = self.make_daemon(root, provider="claude")
            daemon.cfg = {
                "general": {
                    "subagent_sizing_policy": "user_default",
                    "provider": "claude",
                    "model": "sonnet",
                    "orchestrator_effort": "high",
                }
            }

            with patch("orchestrator.create_worktree"), patch.object(Worker, "start"):
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            run = result["run"]
            self.assertEqual(run["provider_key"], "claude")
            self.assertEqual(run["model_alias"], "sonnet")
            self.assertEqual(run["worker_model"], "claude:sonnet")
            self.assertEqual(run["worker_effort"], "high")
            command = Worker(
                run_id=run["id"],
                run=run,
                prompt="",
                agent_bin="claude",
                agent_kind="claude",
                store=daemon.runs,
                log_path=Path(tmp) / "run.log",
            )._command()
            self.assertIn("--model", command)
            self.assertIn("sonnet", command)
            self.assertIn("--effort", command)
            self.assertIn("high", command)

    def test_user_default_inherits_codex_model_with_legacy_effort_migration(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="codex")
            daemon.cfg = {
                "general": {
                    "subagent_sizing_policy": "user_default",
                    "provider": "codex",
                    "model": "gpt-5.4-mini",
                    "orchestrator_effort": "default",
                }
            }

            with patch("orchestrator.create_worktree"), patch.object(Worker, "start"):
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            run = result["run"]
            self.assertEqual(run["model_alias"], "sol")
            self.assertEqual(run["worker_effort"], "xhigh")
            with patch.dict(os.environ, {"RELAY_CODEX_MODEL_LIST_JSON": CODEX_MODEL_LIST_FIXTURE}):
                command = Worker(
                    run_id=run["id"],
                    run=run,
                    prompt="",
                    agent_bin="codex",
                    agent_kind="codex",
                    store=daemon.runs,
                    log_path=Path(tmp) / "run.log",
                )._command()
            self.assertIn("--model", command)
            self.assertIn("gpt-6.0-sol", command)
            self.assertIn("model_reasoning_effort=xhigh", command)

    def test_user_default_legacy_claude_defaults_migrate_to_opus_xhigh(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="claude")
            daemon.cfg = {
                "general": {
                    "subagent_sizing_policy": "user_default",
                    "provider": "claude",
                    "model": "default",
                    "orchestrator_effort": "default",
                }
            }

            with patch("orchestrator.create_worktree"), patch.object(Worker, "start"):
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            run = result["run"]
            self.assertEqual(run["model_alias"], "opus")
            self.assertEqual(run["worker_effort"], "xhigh")
            self.assertEqual(run["worker_model"], "claude:opus")
            command = Worker(
                run_id=run["id"],
                run=run,
                prompt="",
                agent_bin="claude",
                agent_kind="claude",
                store=daemon.runs,
                log_path=Path(tmp) / "run.log",
            )._command()
            self.assertIn("--model", command)
            self.assertIn("opus", command)
            self.assertIn("--effort", command)
            self.assertIn("xhigh", command)

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
            self.assertEqual(run["model_alias"], "sol")
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
                body=(
                    "## Description\n\nUntracked dispatch snapshot.\n\n"
                    "## Attachments\n\n"
                    "- ![design.png](attachments/RR-1/design.png)\n"
                ),
            )
            attachment = repo / ".orchestrator/attachments/RR-1/design.png"
            attachment.parent.mkdir(parents=True)
            attachment.write_bytes(b"design-image")
            daemon = self.make_daemon(root, provider="codex")

            with patch.object(Worker, "start") as start_worker:
                result = daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            start_worker.assert_called_once()
            workspace_ticket = Path(result["run"]["workspace_path"]) / ".orchestrator/RR-1.md"
            self.assertTrue(workspace_ticket.is_file())
            self.assertEqual(workspace_ticket.read_text(), (repo / ".orchestrator/RR-1.md").read_text())
            workspace_attachment = (
                Path(result["run"]["workspace_path"])
                / ".orchestrator/attachments/RR-1/design.png"
            )
            self.assertEqual(workspace_attachment.read_bytes(), b"design-image")
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
            self.assertEqual(result["run"]["model_alias"], "sol")

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

    def test_ready_sweeper_holds_after_deterministic_provider_launch_failure(self):
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
                model_alias=None,
                worker_model="codex:default",
                worker_effort="default",
            )
            daemon.runs.update(
                failed,
                ended=True,
                exit_code=1,
                last_error=(
                    "exit=1; tail=Error: HTTP 400 bad request: "
                    "invalid value for model_reasoning_effort=default"
                ),
            )

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            self.assertEqual(result["dispatched"], [])
            self.assertEqual(result["skipped"][0]["reason"], "dispatch_failed")
            self.assertIn("automatic retry circuit open", result["skipped"][0]["error"])
            self.assertIn("model_reasoning_effort=default", result["skipped"][0]["error"])

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
            self.git(repo, "add", ".orchestrator/config.toml")
            self.git(repo, "commit", "-m", "add config")
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
            self.git(repo, "add", ".orchestrator/config.toml")
            self.git(repo, "commit", "-m", "add config")
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

    def test_orchestrator_actions_commit_authored_ticket_and_preserve_unrelated_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            self.git(repo, "add", ".orchestrator/config.toml")
            self.git(repo, "commit", "-m", "add config")
            (repo / "notes.txt").write_text("leave this alone\n")
            daemon = self.make_daemon(root, provider="codex")

            result = daemon.apply_orchestrator_actions(repo_path=str(repo), actions=[{
                "kind": "create_ticket",
                "title": "Commit authored ticket",
                "description": "Keep ticket authorship in git history.",
                "acceptance_criteria": ["The authored ticket is committed before completion."],
                "worker_model": "fast",
                "worker_effort": "low",
                "worker_sizing_rationale": "A focused workflow contract change.",
                "worker_provider_notes": "Codex and Claude share the daemon authoring path.",
            }])

            self.assertEqual(result["tickets_written"], [{"ticket_id": "RR-1", "action": "create_ticket"}])
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-1.md")["status"], "backlog")
            self.assertEqual((repo / ".orchestrator/config.toml").read_text(), 'prefix = "RR"\nnext_id = 2\n')
            self.assertEqual(
                self.git(repo, "show", "--format=", "--name-only", "HEAD").stdout.splitlines(),
                [".orchestrator/RR-1.md", ".orchestrator/config.toml"],
            )
            self.assertEqual(self.git(repo, "status", "--porcelain").stdout, "?? notes.txt\n")

    def test_orchestrator_actions_commit_ticket_edits_from_worktree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "author-ticket"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 2\n')
            self.write_ticket(repo, "RR-1", status="backlog", run_id=None)
            self.git(repo, "add", ".orchestrator/config.toml", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            self.git(repo, "worktree", "add", "-b", "relay/author-ticket", str(workspace), "HEAD")
            (workspace / "notes.txt").write_text("leave this alone\n")
            daemon = self.make_daemon(root, provider="claude")

            result = daemon.apply_orchestrator_actions(repo_path=str(workspace), actions=[{
                "kind": "edit_ticket",
                "ticket_id": "RR-1",
                "description": "Refined in an isolated worktree.",
                "acceptance_criteria": ["The refined ticket is committed from the worktree."],
            }])

            self.assertEqual(result["tickets_written"], [{"ticket_id": "RR-1", "action": "edit_ticket"}])
            self.assertIn("Refined in an isolated worktree.", read_ticket(workspace / ".orchestrator/RR-1.md")["body"])
            self.assertEqual(
                self.git(workspace, "show", "--format=", "--name-only", "HEAD").stdout.splitlines(),
                [".orchestrator/RR-1.md"],
            )
            self.assertEqual(self.git(workspace, "status", "--porcelain").stdout, "?? notes.txt\n")

    def test_orchestrator_actions_block_dirty_ticket_authoring_overlap(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            self.git(repo, "add", ".orchestrator/config.toml")
            self.git(repo, "commit", "-m", "add config")
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 9\n')
            daemon = self.make_daemon(root, provider="claude")

            with self.assertRaisesRegex(ValueError, "existing changes to .orchestrator/config.toml"):
                daemon.apply_orchestrator_actions(repo_path=str(repo), actions=[{
                    "kind": "create_ticket",
                    "title": "Blocked ticket",
                    "description": "This must not overwrite a counter edit.",
                    "acceptance_criteria": ["The dirty counter stays untouched."],
                    "worker_model": "fast",
                    "worker_effort": "low",
                    "worker_sizing_rationale": "A focused workflow contract change.",
                    "worker_provider_notes": "Codex and Claude share the daemon authoring path.",
                }])

            self.assertFalse((repo / ".orchestrator/RR-1.md").exists())
            self.assertEqual((repo / ".orchestrator/config.toml").read_text(), 'prefix = "RR"\nnext_id = 9\n')

    def test_orchestrator_actions_report_and_revert_failed_ticket_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            self.git(repo, "add", ".orchestrator/config.toml")
            self.git(repo, "commit", "-m", "add config")
            daemon = self.make_daemon(root, provider="codex")
            real_git = orchestrator._git

            def reject_commit(repo_path, *args, check=True):
                if args[0] == "commit":
                    return subprocess.CompletedProcess(args, 1, "", "commit hook rejected")
                return real_git(repo_path, *args, check=check)

            with patch("orchestrator._git", side_effect=reject_commit), \
                    self.assertRaisesRegex(ValueError, "ticket authoring commit failed: commit hook rejected"):
                daemon.apply_orchestrator_actions(repo_path=str(repo), actions=[{
                    "kind": "create_ticket",
                    "title": "Rejected ticket",
                    "description": "This must not survive a rejected commit.",
                    "acceptance_criteria": ["The failed authorship stays unreported."],
                    "worker_model": "fast",
                    "worker_effort": "low",
                    "worker_sizing_rationale": "A focused workflow contract change.",
                    "worker_provider_notes": "Codex and Claude share the daemon authoring path.",
                }])

            self.assertFalse((repo / ".orchestrator/RR-1.md").exists())
            self.assertEqual((repo / ".orchestrator/config.toml").read_text(), 'prefix = "RR"\nnext_id = 1\n')
            self.assertEqual(self.git(repo, "status", "--porcelain").stdout, "")

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

    def test_authorized_dispatch_survives_newer_acknowledgement_turn(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            state_path = root / "voice_command_state.json"
            auth_path = root / "voice_command_authorizations.json"
            first = {
                "relay_command_seq": 1,
                "relay_command_id": "dispatch-cmd",
                "action": "dispatch_ticket",
                "ticket_id": "RR-1",
                "source_text": "dispatch RR-1",
            }
            record_command_authorization(
                auth_path,
                first,
                relationship="replacement",
                allowed_mutations=allowed_mutations_for_metadata(first),
                now=1,
            )
            state_path.write_text(json.dumps({
                "relay_command_seq": 2,
                "relay_command_id": "ack-cmd",
                "action": "conversation",
                "authorization_relationship": "conversation",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            original_auth_path = orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE = auth_path
            daemon = self.make_daemon(root, provider="codex")
            try:
                with patch("orchestrator.create_worktree") as create_worktree, \
                        patch.object(Worker, "start") as start_worker:
                    result = daemon.dispatch(
                        ticket_id="RR-1",
                        repo_path=str(repo),
                        relay_command_seq=1,
                        relay_command_id="dispatch-cmd",
                    )
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path
                orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE = original_auth_path

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            self.assertFalse(result["already_active"])
            ledger = json.loads(auth_path.read_text())
            started = ledger["authorizations"][0]["started_mutations"]
            self.assertEqual(started[0]["mutation"]["ticket_id"], "RR-1")

    def test_authorized_dispatch_survives_newer_status_question(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-2", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-2.md")
            self.git(repo, "commit", "-m", "add ticket")
            state_path = root / "voice_command_state.json"
            auth_path = root / "voice_command_authorizations.json"
            first = {
                "relay_command_seq": 3,
                "relay_command_id": "dispatch-cmd",
                "action": "dispatch_ticket",
                "ticket_id": "RR-2",
                "source_text": "dispatch RR-2",
            }
            record_command_authorization(
                auth_path,
                first,
                relationship="replacement",
                allowed_mutations=allowed_mutations_for_metadata(first),
                now=1,
            )
            state_path.write_text(json.dumps({
                "relay_command_seq": 4,
                "relay_command_id": "status-cmd",
                "action": "inspect_ticket",
                "ticket_id": "RR-2",
                "authorization_relationship": "inspection",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            original_auth_path = orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE = auth_path
            daemon = self.make_daemon(root, provider="claude")
            try:
                with patch("orchestrator.create_worktree") as create_worktree, \
                        patch.object(Worker, "start") as start_worker:
                    result = daemon.dispatch(
                        ticket_id="RR-2",
                        repo_path=str(repo),
                        relay_command_seq=3,
                        relay_command_id="dispatch-cmd",
                    )
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path
                orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE = original_auth_path

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            self.assertFalse(result["already_active"])

    def test_multi_ticket_dispatch_authorization_rejects_outside_ticket(self):
        with tempfile.TemporaryDirectory() as tmp:
            auth_path = Path(tmp) / "voice_command_authorizations.json"
            command = {
                "relay_command_seq": 13,
                "relay_command_id": "batch-dispatch",
                "action": "dispatch_ticket",
                "source_text": "dispatch RR-1 and RR-2",
            }
            record_command_authorization(
                auth_path,
                command,
                relationship="replacement",
                allowed_mutations=allowed_mutations_for_metadata(command),
                now=1,
            )

            with self.assertRaisesRegex(ValueError, "not authorized"):
                validate_and_mark_mutation(
                    auth_path,
                    13,
                    "batch-dispatch",
                    {"kind": "dispatch_ticket", "ticket_id": "RR-999"},
                    now=2,
                )

            record = validate_and_mark_mutation(
                auth_path,
                13,
                "batch-dispatch",
                {"kind": "dispatch_ticket", "ticket_id": "RR-2"},
                now=3,
            )
            self.assertEqual(record["started_mutations"][0]["mutation"]["ticket_id"], "RR-2")

    def test_item_scoped_replacement_preserves_unrelated_turn_authorization(self):
        with tempfile.TemporaryDirectory() as tmp:
            auth_path = Path(tmp) / "voice_command_authorizations.json"
            for order, target in ((1, "login"), (2, "search")):
                item = {
                    "relay_command_seq": 1,
                    "relay_command_id": "multi-item",
                    "intent_id": f"multi-item:item:{order}",
                    "within_turn_order": order,
                    "target": target,
                    "action": "create_ticket",
                    "source_text": f"fix {target}",
                }
                record_command_authorization(
                    auth_path,
                    item,
                    relationship="additive",
                    allowed_mutations=allowed_mutations_for_metadata(item),
                    now=float(order),
                )

            record_command_authorization(
                auth_path,
                {
                    "relay_command_seq": 2,
                    "relay_command_id": "cancel-login",
                    "intent_id": "cancel-login:item:1",
                    "cancellation_scope": "item",
                    "target_intent_ids": ["multi-item:item:1"],
                    "authorization_relationship": "redirect",
                },
                relationship="redirect",
                allowed_mutations=[],
                now=3,
            )

            records = {
                item.get("intent_id"): item
                for item in json.loads(auth_path.read_text())["authorizations"]
            }
            self.assertEqual(records["multi-item:item:1"]["status"], "revoked")
            self.assertEqual(records["multi-item:item:2"]["status"], "active")
            with self.assertRaisesRegex(ValueError, "revoked"):
                validate_and_mark_mutation(
                    auth_path,
                    1,
                    "multi-item",
                    {"kind": "orchestrator_command", "request_id": "login"},
                    relay_intent_id="multi-item:item:1",
                    now=4,
                )
            survivor = validate_and_mark_mutation(
                auth_path,
                1,
                "multi-item",
                {"kind": "orchestrator_command", "request_id": "search"},
                relay_intent_id="multi-item:item:2",
                now=5,
            )
            self.assertEqual(survivor["intent_id"], "multi-item:item:2")

    def test_redirect_revokes_authorized_dispatch_before_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-3", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-3.md")
            self.git(repo, "commit", "-m", "add ticket")
            state_path = root / "voice_command_state.json"
            auth_path = root / "voice_command_authorizations.json"
            first = {
                "relay_command_seq": 5,
                "relay_command_id": "dispatch-cmd",
                "action": "dispatch_ticket",
                "ticket_id": "RR-3",
                "source_text": "dispatch RR-3",
            }
            record_command_authorization(
                auth_path,
                first,
                relationship="replacement",
                allowed_mutations=allowed_mutations_for_metadata(first),
                now=1,
            )
            redirect = {
                "relay_command_seq": 6,
                "relay_command_id": "redirect-cmd",
                "action": "create_ticket",
                "source_text": "actually fix something else instead",
            }
            record_command_authorization(
                auth_path,
                redirect,
                relationship="redirect",
                allowed_mutations=[],
                now=2,
            )
            state_path.write_text(json.dumps({
                **redirect,
                "authorization_relationship": "redirect",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            original_auth_path = orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE = auth_path
            daemon = self.make_daemon(root, provider="codex")
            try:
                with patch("orchestrator.create_worktree") as create_worktree, \
                        patch.object(Worker, "start") as start_worker, \
                        self.assertRaisesRegex(ValueError, "revoked"):
                    daemon.dispatch(
                        ticket_id="RR-3",
                        repo_path=str(repo),
                        relay_command_seq=5,
                        relay_command_id="dispatch-cmd",
                    )
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path
                orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE = original_auth_path

            create_worktree.assert_not_called()
            start_worker.assert_not_called()

    def test_redirect_partway_through_multi_action_reports_canceled_remainder(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-4", status="ready", run_id=None, sizing=True)
            self.write_ticket(repo, "RR-5", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-4.md", ".orchestrator/RR-5.md")
            self.git(repo, "commit", "-m", "add tickets")
            state_path = root / "voice_command_state.json"
            auth_path = root / "voice_command_authorizations.json"
            first = {
                "relay_command_seq": 7,
                "relay_command_id": "batch-cmd",
                "action": "create_ticket",
                "source_text": "dispatch RR-4 and RR-5",
            }
            record_command_authorization(
                auth_path,
                first,
                relationship="replacement",
                allowed_mutations=allowed_mutations_for_metadata(first),
                now=1,
            )
            state_path.write_text(json.dumps({
                **first,
                "authorization_relationship": "replacement",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            original_auth_path = orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE = auth_path
            daemon = self.make_daemon(root, provider="codex")
            dispatch_calls: list[str] = []

            def fake_dispatch(**kwargs):
                dispatch_calls.append(kwargs["ticket_id"])
                redirect = {
                    "relay_command_seq": 8,
                    "relay_command_id": "redirect-cmd",
                    "action": "create_ticket",
                    "source_text": "actually do the other thing instead",
                }
                record_command_authorization(
                    auth_path,
                    redirect,
                    relationship="redirect",
                    allowed_mutations=[],
                    now=2,
                )
                state_path.write_text(json.dumps({
                    **redirect,
                    "authorization_relationship": "redirect",
                }))
                return {"already_active": False, "run": {"id": 100 + len(dispatch_calls)}}

            daemon.dispatch = fake_dispatch
            try:
                result = daemon.apply_orchestrator_actions(
                    repo_path=str(repo),
                    actions=[
                        {"kind": "request_worker", "ticket_id": "RR-4"},
                        {"kind": "request_worker", "ticket_id": "RR-5"},
                    ],
                    request_id="batch-1",
                    relay_command_seq=7,
                    relay_command_id="batch-cmd",
                )
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path
                orchestrator.RELAY_COMMAND_AUTHORIZATION_FILE = original_auth_path

            self.assertEqual(dispatch_calls, ["RR-4"])
            self.assertEqual(result["dispatches"], [{
                "ticket_id": "RR-4",
                "run_id": 101,
                "already_active": False,
            }])
            self.assertTrue(result["partial"])
            self.assertTrue(result["superseded"])
            self.assertEqual(result["canceled"], [{
                "action": "request_worker",
                "reason": result["status_message"],
                "ticket_id": "RR-5",
            }])

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

    def test_verification_blocked_ticket_is_a_declared_worker_outcome(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="in_progress", run_id=42)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "claim ticket")
            start_head = self.git(repo, "rev-parse", "HEAD").stdout.strip()

            ticket_path = repo / ".orchestrator/RR-1.md"
            ticket_path.write_text(
                ticket_path.read_text().replace(
                    "status: in_progress\n",
                    "status: verification_blocked\n"
                    "verification_blocker: Physical modifier-only input is unavailable.\n"
                    "verification_resume: Connect physical HID input and rerun the mounted replay smoke.\n",
                ).replace(
                    "## Description\n\nTest ticket.\n",
                    "## Run log\n\n- **Run 42** (attempt 1) - branch `relay/rr-1`\n",
                )
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "docs(RR-1): run 42 log")

            outcome, reason = validate_worker_outcome(
                workspace_path=str(repo),
                ticket_id="RR-1",
                run_id=42,
                start_head=start_head,
            )

            self.assertEqual(outcome, "verification_blocked")
            self.assertIn("Physical modifier-only input is unavailable", reason)
            self.assertIn("Connect physical HID input", reason)

    def test_exit_zero_declared_verification_blocker_is_not_failed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            workspace.mkdir()
            agent = root / "agent.sh"
            agent.write_text("#!/bin/sh\nexit 0\n")
            os.chmod(agent, 0o755)
            store = RunsStore(root / "runs.db")
            run_id = store.insert(
                ticket_id="RR-1",
                repo_path=str(workspace),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="Claimed",
            )
            run = store.get(run_id) or {}
            worker = Worker(
                run_id=run_id,
                run=run,
                prompt="prompt",
                agent_bin=str(agent),
                agent_kind="codex",
                store=store,
                log_path=root / "run.log",
            )

            with patch.object(worker, "_command", return_value=[str(agent)]), \
                    patch(
                        "orchestrator.validate_worker_outcome",
                        return_value=(
                            "verification_blocked",
                            "verification blocked: physical input unavailable; resume: connect HID",
                        ),
                    ):
                worker._run()

            updated = store.get(run_id) or {}
            self.assertEqual(updated["state"], "AwaitingReview")
            self.assertEqual(updated["exit_code"], 0)
            self.assertIn("physical input unavailable", updated["last_error"])

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
                model_alias="sol",
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
            )

            with patch.dict(os.environ, {"RELAY_CODEX_MODEL_LIST_JSON": CODEX_MODEL_LIST_FIXTURE}):
                review._run()

            updated = daemon.runs.get(run_id)
            self.assertEqual(updated["state"], "AwaitingReview")
            self.assertIn("review worker failed: exit=7", updated["last_error"])
            self.assertEqual(updated["activity"], "Reviewing worker branch")
            self.assertIsNotNone(updated["activity_at"])

    def test_review_worker_does_not_overwrite_accepted_verification_blocker(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            workspace.mkdir(parents=True)
            agent = root / "fake-agent.sh"
            agent.write_text("#!/bin/sh\nsleep 0.2\nexit 0\n")
            os.chmod(agent, 0o755)
            store = RunsStore(root / "runs.db")
            run_id = store.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="AwaitingReview",
                log_path=str(workspace / ".relay" / "run.log"),
                provider_key="codex",
                model_alias="sol",
                worker_effort="high",
            )
            review = ReviewWorker(
                run_id=run_id,
                run=store.get(run_id) or {},
                prompt="review prompt",
                agent_bin=str(agent),
                agent_kind="codex",
                store=store,
                log_path=workspace / ".relay" / "run.log",
            )

            with patch.dict(os.environ, {"RELAY_CODEX_MODEL_LIST_JSON": CODEX_MODEL_LIST_FIXTURE}):
                review.start()
                for _ in range(100):
                    if (store.get(run_id) or {}).get("state") == "Reviewing":
                        break
                    threading.Event().wait(0.01)
                self.assertEqual((store.get(run_id) or {}).get("state"), "Reviewing")
                store.update(run_id, state="VerificationBlocked")
                review.thread.join(timeout=2)

            self.assertFalse(review.thread.is_alive())
            self.assertEqual((store.get(run_id) or {}).get("state"), "VerificationBlocked")

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

    def test_accept_verification_blocked_run_merges_without_closing_or_progressing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.write_ticket(
                repo,
                "RR-2",
                status="backlog",
                run_id=None,
                depends_on=["RR-1"],
                sizing=True,
            )
            self.git(repo, "add", ".orchestrator/RR-1.md", ".orchestrator/RR-2.md")
            self.git(repo, "commit", "-m", "add tickets")
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
            ticket_path = workspace / ".orchestrator/RR-1.md"
            ticket_path.write_text(
                ticket_path.read_text().replace(
                    "status: ready\n",
                    "status: verification_blocked\n"
                    "verification_blocker: Screen Recording and physical Option input are unavailable.\n"
                    "verification_resume: Grant Screen Recording and provide foreground/background physical Option input.\n",
                ).replace("run_id: null", f"run_id: {run_id}").replace(
                    "## Description\n\nTest ticket.\n",
                    f"## Run log\n\n- **Run {run_id}** (attempt 1) - branch `relay/rr-1`\n",
                )
            )
            (workspace / "code.txt").write_text("reviewed partial implementation\n")
            self.git(workspace, "add", ".orchestrator/RR-1.md", "code.txt")
            self.git(workspace, "commit", "-m", "feat: implement RR-1 pending physical verification")
            dispatches: list[dict] = []
            daemon.dispatch = lambda **kwargs: dispatches.append(kwargs)

            result = daemon.accept_worker_run(run_id)

            self.assertTrue(result["accepted"])
            self.assertEqual(result["run"]["state"], "VerificationBlocked")
            self.assertFalse(workspace.exists())
            blocked = read_ticket(repo / ".orchestrator/RR-1.md")
            self.assertEqual(blocked["status"], "verification_blocked")
            self.assertIn("Screen Recording", blocked["verification_blocker"])
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-2.md")["status"], "backlog")
            self.assertEqual(dispatches, [])

    def test_explicit_resume_commits_ticket_transition_before_requeue(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            daemon = self.make_daemon(root, provider="codex")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(root / "old-workspace"),
                branch="relay/rr-1",
                state="VerificationBlocked",
                provider_key="codex",
                model_alias="gpt-5.5",
            )
            ticket = repo / ".orchestrator/RR-1.md"
            ticket.write_text(
                f"""---
id: RR-1
title: RR-1
status: verification_blocked
priority: medium
depends_on: []
run_id: {run_id}
canceled: false
verification_blocker: Physical input unavailable.
verification_resume: Connect physical input and resume.
---

## Run log

- **Run {run_id}** reviewed and blocked.
"""
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "record verification blocker")

            result = daemon.resume_verification_blocked(
                run_id,
                reason="A physical HID route is now connected.",
                redispatch=False,
            )

            resumed = read_ticket(ticket)
            self.assertTrue(result["resumed"])
            self.assertEqual(resumed["status"], "ready")
            self.assertIsNone(resumed["run_id"])
            self.assertIsNone(resumed["verification_blocker"])
            self.assertIsNone(resumed["verification_resume"])
            self.assertIn(
                "Verification resumed after run 1** — A physical HID route is now connected.",
                resumed["body"],
            )
            self.assertEqual(self.git(repo, "status", "--porcelain").stdout.strip(), "")
            self.assertEqual(daemon.runs.get(run_id)["state"], "VerificationBlocked")

    def test_reconcile_missing_verification_blocked_run_restores_resume_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            daemon = self.make_daemon(root, provider="codex")
            ticket = repo / ".orchestrator/RR-1.md"
            ticket.write_text(
                """---
id: RR-1
title: RR-1
status: verification_blocked
priority: medium
depends_on: []
run_id: 7
canceled: false
verification_blocker: Physical input unavailable.
verification_resume: Connect physical input and resume.
---

## Run log

- **Run 7** (attempt 2) reviewed and blocked.
"""
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "record preserved verification blocker")

            reconciled = daemon.reconcile_preserved_run(
                repo_path=str(repo),
                ticket_id="RR-1",
            )

            self.assertTrue(reconciled["reconciled"])
            self.assertEqual(reconciled["run"]["id"], 7)
            self.assertEqual(reconciled["run"]["state"], "VerificationBlocked")
            self.assertEqual(reconciled["run"]["attempt"], 2)
            self.assertEqual(daemon.runs.next_attempt("RR-1", str(repo.resolve())), 3)
            self.assertEqual(reconciled["run"]["exit_code"], 0)
            self.assertEqual(reconciled["run"]["workspace_path"], "")
            self.assertIn("Physical input unavailable", reconciled["run"]["last_error"])
            self.assertFalse(
                daemon.reconcile_preserved_run(
                    repo_path=str(repo),
                    ticket_id="RR-1",
                )["reconciled"]
            )

            resumed = daemon.resume_verification_blocked(
                7,
                reason="A physical HID route is now connected.",
                redispatch=False,
            )

            self.assertTrue(resumed["resumed"])
            self.assertEqual(read_ticket(ticket)["status"], "ready")

    def test_reconcile_missing_done_run_does_not_progress_dependencies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(
                repo,
                "RR-1",
                status="done",
                run_id=9,
                sizing=True,
                body="## Run log\n\n- **Run 9** (attempt 2) reviewed and merged.\n",
            )
            self.write_ticket(
                repo,
                "RR-2",
                status="backlog",
                run_id=None,
                depends_on=["RR-1"],
                sizing=True,
            )
            self.git(repo, "add", ".orchestrator/RR-1.md", ".orchestrator/RR-2.md")
            self.git(repo, "commit", "-m", "record preserved completed run")
            daemon = self.make_daemon(root, provider="codex")
            dispatches: list[dict] = []
            daemon.dispatch = lambda **kwargs: dispatches.append(kwargs)

            result = daemon.reconcile_preserved_run(
                repo_path=str(repo),
                ticket_id="RR-1",
            )

            self.assertTrue(result["reconciled"])
            self.assertEqual(result["run"]["id"], 9)
            self.assertEqual(result["run"]["state"], "Merged")
            self.assertEqual(result["run"]["attempt"], 2)
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-2.md")["status"], "backlog")
            self.assertEqual(dispatches, [])

    def test_recover_preserved_run_collision_relinks_idempotently_then_resumes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            ticket = repo / ".orchestrator/RR-1.md"
            ticket.write_text(
                """---
id: RR-1
title: RR-1
status: verification_blocked
priority: medium
depends_on: []
run_id: 7
canceled: false
verification_blocker: Physical input unavailable.
verification_resume: Connect physical input and resume.
---

## Run log

### Run 7 (attempt 2) — branch `relay/rr-1`

- Reviewed and blocked.
"""
            )
            self.write_ticket(
                repo,
                "RR-2",
                status="done",
                run_id=7,
                sizing=True,
                body="## Run log\n\n- **Run 7** (attempt 1) reviewed and merged.\n",
            )
            self.write_ticket(
                repo,
                "RR-3",
                status="backlog",
                run_id=None,
                depends_on=["RR-1"],
                sizing=True,
            )
            self.git(
                repo,
                "add",
                ".orchestrator/RR-1.md",
                ".orchestrator/RR-2.md",
                ".orchestrator/RR-3.md",
            )
            self.git(repo, "commit", "-m", "record colliding preserved run")
            daemon = self.make_daemon(root, provider="codex")
            daemon.runs.insert_reconciled(
                run_id=7,
                ticket_id="RR-2",
                repo_path=str(repo.resolve()),
                state="Merged",
                attempt=1,
            )
            occupied_before = daemon.runs.get(7)
            dispatches: list[dict] = []
            daemon.dispatch = lambda **kwargs: dispatches.append(kwargs)

            result = daemon.recover_preserved_run_collision(
                repo_path=str(repo),
                ticket_id="RR-1",
            )

            replacement_id = result["replacement_run_id"]
            recovered = read_ticket(ticket)
            self.assertTrue(result["recovered"])
            self.assertNotEqual(replacement_id, 7)
            self.assertEqual(recovered["status"], "verification_blocked")
            self.assertEqual(recovered["run_id"], replacement_id)
            self.assertIn(
                f"historical run 7 (attempt 2); replacement run {replacement_id}; "
                "occupied row retained for RR-2",
                recovered["body"],
            )
            self.assertEqual(daemon.runs.get(7), occupied_before)
            self.assertEqual(result["run"]["ticket_id"], "RR-1")
            self.assertEqual(result["run"]["state"], "VerificationBlocked")
            self.assertEqual(result["run"]["attempt"], 2)
            self.assertEqual(read_ticket(repo / ".orchestrator/RR-3.md")["status"], "backlog")
            self.assertEqual(dispatches, [])
            self.assertEqual(self.git(repo, "status", "--porcelain").stdout.strip(), "")

            repeated = daemon.recover_preserved_run_collision(
                repo_path=str(repo),
                ticket_id="RR-1",
            )

            self.assertFalse(repeated["recovered"])
            self.assertEqual(repeated["replacement_run_id"], replacement_id)
            self.assertEqual(daemon.runs.get(7), occupied_before)
            self.assertEqual(
                len(daemon.runs.reconciled_replacements(
                    historical_run_id=7,
                    ticket_id="RR-1",
                    repo_path=str(repo),
                )),
                1,
            )

            resumed = daemon.resume_verification_blocked(
                replacement_id,
                reason="A physical HID route is now connected.",
                redispatch=False,
            )

            self.assertTrue(resumed["resumed"])
            self.assertEqual(resumed["previous_run"]["ticket_id"], "RR-1")
            self.assertEqual(read_ticket(ticket)["status"], "ready")
            self.assertEqual(daemon.runs.get(7), occupied_before)

    def test_recover_preserved_run_collision_rejects_unsafe_evidence(self):
        def fixture(
            root: Path,
            *,
            status: str = "verification_blocked",
            body: str = "## Run log\n\n- **Run 7** (attempt 2) reviewed and blocked.\n",
            occupied_repo: Path | None = None,
        ) -> tuple[Path, Daemon]:
            repo = root / "repo"
            self.make_git_repo(repo)
            blocker_fields = ""
            if status == "verification_blocked":
                blocker_fields = (
                    "verification_blocker: Physical input unavailable.\n"
                    "verification_resume: Connect physical input and resume.\n"
                )
            (repo / ".orchestrator/RR-1.md").write_text(
                f"""---
id: RR-1
title: RR-1
status: {status}
priority: medium
depends_on: []
run_id: 7
canceled: false
{blocker_fields}---

{body}
"""
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "record collision evidence")
            daemon = self.make_daemon(root, provider="codex")
            daemon.runs.insert_reconciled(
                run_id=7,
                ticket_id="RR-2",
                repo_path=str((occupied_repo or repo).resolve()),
                state="Merged",
            )
            return repo, daemon

        cases = (
            ("nonterminal", {"status": "ready"}, "only committed done or verification_blocked"),
            (
                "missing-attempt",
                {"body": "## Run log\n\n- **Run 7** reviewed and blocked.\n"},
                "attempt evidence",
            ),
            (
                "repository-mismatch",
                {"occupied_repo_name": "other-repo"},
                "different repository",
            ),
        )
        for name, options, error in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                occupied_repo_name = options.pop("occupied_repo_name", None)
                occupied_repo = root / occupied_repo_name if occupied_repo_name else None
                repo, daemon = fixture(root, occupied_repo=occupied_repo, **options)

                with self.assertRaisesRegex(ValueError, error):
                    daemon.recover_preserved_run_collision(
                        repo_path=str(repo),
                        ticket_id="RR-1",
                    )

                self.assertEqual(len(daemon.runs.list()), 1)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo, daemon = fixture(root)
            ticket = repo / ".orchestrator/RR-1.md"
            ticket.write_text(ticket.read_text() + "\nUncommitted claim.\n")

            with self.assertRaisesRegex(ValueError, "existing changes"):
                daemon.recover_preserved_run_collision(
                    repo_path=str(repo),
                    ticket_id="RR-1",
                )

            self.assertEqual(len(daemon.runs.list()), 1)

    def test_recover_preserved_run_collision_rejects_ambiguous_repeat(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            ticket = repo / ".orchestrator/RR-1.md"
            ticket.write_text(
                """---
id: RR-1
title: RR-1
status: verification_blocked
priority: medium
depends_on: []
run_id: 7
canceled: false
verification_blocker: Physical input unavailable.
verification_resume: Connect physical input and resume.
---

## Run log

- **Run 7** (attempt 2) reviewed and blocked.
"""
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "record collision evidence")
            daemon = self.make_daemon(root, provider="codex")
            daemon.runs.insert_reconciled(
                run_id=7,
                ticket_id="RR-2",
                repo_path=str(repo.resolve()),
                state="Merged",
            )
            result = daemon.recover_preserved_run_collision(
                repo_path=str(repo),
                ticket_id="RR-1",
            )
            entry = (
                "- **Preserved run collision recovery** — historical run 7 "
                f"(attempt 2); replacement run {result['replacement_run_id']}; "
                "occupied row retained for RR-2.\n"
            )
            ticket.write_text(ticket.read_text() + "\n" + entry)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ambiguous recovery evidence")

            with self.assertRaisesRegex(ValueError, "ambiguous"):
                daemon.recover_preserved_run_collision(
                    repo_path=str(repo),
                    ticket_id="RR-1",
                )

    def test_reconcile_preserved_run_rejects_dirty_ticket_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(
                repo,
                "RR-1",
                status="done",
                run_id=9,
                sizing=True,
                body="## Run log\n\n- **Run 9** reviewed and merged.\n",
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "record completed run")
            ticket = repo / ".orchestrator/RR-1.md"
            ticket.write_text(ticket.read_text() + "\nUncommitted claim.\n")
            daemon = self.make_daemon(root, provider="codex")

            with self.assertRaisesRegex(ValueError, "existing changes"):
                daemon.reconcile_preserved_run(
                    repo_path=str(repo),
                    ticket_id="RR-1",
                )

            self.assertIsNone(daemon.runs.get(9))

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
        daemon.worker_health_check_seconds = 600
        daemon._run_health = {}
        daemon._run_health_lock = threading.Lock()
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
