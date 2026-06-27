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

from orchestrator import Daemon, RunsStore, Worker, validate_worker_completion  # noqa: E402
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
                branch="relay/rr-1",
                attempt=2,
                run_id=17,
            )

            self.assertIn("Read `.orchestrator/RR-1.md`", prompt)
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
        daemon.agent_kind = provider
        daemon.agent_bin = provider
        daemon.runs = RunsStore(root / "runs.db")
        daemon._dispatch_lock = threading.Lock()
        daemon._workers = {}
        daemon._workers_lock = threading.Lock()
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
