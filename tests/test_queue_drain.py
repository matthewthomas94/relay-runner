from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from orchestrator import (  # noqa: E402
    MAX_AUTO_DISPATCH_ATTEMPTS,
    Daemon,
    MessengerOutcomeStore,
    QueueDrainStore,
    ReviewWorker,
    RunsStore,
    Worker,
)


class QueueDrainTests(unittest.TestCase):
    def test_verification_blocked_run_remains_in_board_index_after_retention_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            index_path = root / "runs-index.json"
            store = RunsStore(root / "runs.db", index_path=index_path)
            with patch("orchestrator.time.time", return_value=1000.0):
                run_id = store.insert(
                    ticket_id="RR-1",
                    repo_path=str(root / "repo"),
                    workspace_path=str(root / "workspace"),
                    branch="relay/rr-1",
                    state="Running",
                )
                store.update(run_id, state="VerificationBlocked", ended=True)

            with patch("orchestrator.time.time", return_value=2000.0):
                store.write_index()

            runs = json.loads(index_path.read_text())["runs"]
            self.assertEqual([(run["run_id"], run["state"]) for run in runs], [
                (run_id, "VerificationBlocked"),
            ])

    def test_verification_blocked_ticket_is_durable_and_never_redispatched(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            daemon = self.make_daemon(root, provider="codex")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(root / "reviewed-workspace"),
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
priority: high
depends_on: []
run_id: {run_id}
canceled: false
verification_blocker: Screen Recording and modifier-only physical input are unavailable.
verification_resume: Grant Screen Recording and connect physical Option input, then explicitly resume.
worker_model: strong
worker_effort: high
worker_sizing_rationale: Verification-blocked lifecycle needs daemon coverage.
worker_provider_notes: Codex and Claude share the same lifecycle.
---

## Run log

- **Run {run_id}** reviewed and verification blocked.
"""
            )
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "record blocked ticket")

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                first = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")
                second = daemon.reconcile_queue_drain(repo_path=str(repo), trigger="test-again")
                with self.assertRaisesRegex(ValueError, "explicit resume action"):
                    daemon.dispatch(ticket_id="RR-1", repo_path=str(repo))

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            self.assertEqual(len(daemon.runs.list()), 1)
            self.assertEqual(first["drain"]["state"], "blocked")
            self.assertEqual(second["drain"]["state"], "blocked")
            item = second["drain"]["items"][0]
            self.assertEqual(item["state"], "blocked")
            self.assertEqual(item["blocker_owner"], "external_verification")
            self.assertIn("modifier-only physical input", item["reason"])
            self.assertIn("explicitly resume", item["blocker_next_step"])

    def test_ready_tickets_create_and_join_one_active_drain(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add first ticket")
            daemon = self.make_daemon(root, provider="codex")

            with patch("orchestrator.create_worktree"), patch.object(Worker, "start"):
                first = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            drain = first["drain"]
            self.assertIsNotNone(drain)
            self.assertEqual(drain["state"], "active")
            self.assertEqual(drain["provider_key"], "codex")
            self.assertEqual(drain["provider_goal_mode"], "codex-goal-lifecycle")
            self.assertEqual(drain["observed_ticket_ids"], ["RR-1"])
            self.assertEqual(drain["items"][0]["state"], "active")

            self.write_ticket(repo, "RR-2", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-2.md")
            self.git(repo, "commit", "-m", "add second ticket")

            with patch("orchestrator.create_worktree"), patch.object(Worker, "start"):
                second = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            self.assertEqual(second["drain"]["id"], drain["id"])
            self.assertEqual(second["drain"]["observed_ticket_ids"], ["RR-1", "RR-2"])
            self.assertEqual(
                sorted(item["ticket_id"] for item in second["drain"]["items"]),
                ["RR-1", "RR-2"],
            )

    def test_capacity_wait_is_visible_scheduled_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-0", status="ready", run_id=None, sizing=True)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-0.md", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add tickets")
            daemon = self.make_daemon(root, provider="codex")
            daemon.max_concurrent_workers = 1
            active_run_id = daemon.runs.insert(
                ticket_id="RR-0",
                repo_path=str(repo.resolve()),
                workspace_path=str(root / "workspaces" / "rr-0"),
                branch="relay/rr-0",
                state="Running",
                provider_key="codex",
                model_alias="gpt-5.5",
            )
            daemon.runs.update(active_run_id, pid=os.getpid())

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            reasons = {item["ticket_id"]: item for item in result["skipped"]}
            self.assertEqual(reasons["RR-1"]["reason"], "capacity_wait")
            items = {item["ticket_id"]: item for item in result["drain"]["items"]}
            self.assertEqual(items["RR-0"]["state"], "active")
            self.assertEqual(items["RR-1"]["state"], "scheduled")
            self.assertIn("capacity wait", items["RR-1"]["reason"])
            self.assertIsNotNone(items["RR-1"]["next_action_at"])

    def test_old_live_active_run_remains_active(self):
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
                state="Running",
                provider_key="codex",
                model_alias="gpt-5.5",
            )
            stale_at = time.time() - 24 * 60 * 60
            daemon.runs.update(run_id, pid=os.getpid())
            with daemon.runs._conn() as conn:
                conn.execute(
                    "UPDATE runs SET activity_at = ?, started_at = ? WHERE id = ?",
                    (stale_at, stale_at, run_id),
                )

            with patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            active = daemon.runs.get(run_id)
            self.assertEqual(active["state"], "Running")
            self.assertIsNone(active["last_error"])
            item = result["drain"]["items"][0]
            self.assertEqual(item["state"], "active")

            daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")
            self.assertEqual(len(daemon.runs.list()), 1)

    def test_dead_active_run_is_recovered_once_and_scheduled(self):
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
                state="Running",
                provider_key="codex",
                model_alias="gpt-5.5",
            )
            daemon.runs.update(run_id, pid=999_999)

            with patch("orchestrator._process_is_alive", return_value=False), \
                    patch("orchestrator.create_worktree") as create_worktree, \
                    patch.object(Worker, "start") as start_worker:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            create_worktree.assert_not_called()
            start_worker.assert_not_called()
            recovered = daemon.runs.get(run_id)
            self.assertEqual(recovered["state"], "Stalled")
            self.assertIn("process is no longer running", recovered["last_error"])
            item = result["drain"]["items"][0]
            self.assertEqual(item["state"], "scheduled")
            self.assertIn("backoff active", item["reason"])

            daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")
            self.assertEqual(len(daemon.runs.list()), 1)

    def test_awaiting_review_run_gets_review_worker_from_drain(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            workspace.mkdir(parents=True)
            daemon = self.make_daemon(root, provider="claude")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="AwaitingReview",
                provider_key="claude",
                model_alias="sonnet",
                worker_effort="high",
            )
            daemon.runs.update(run_id, ended=True, exit_code=0)

            with patch.object(ReviewWorker, "start") as start_review:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            start_review.assert_called_once()
            self.assertIn(run_id, daemon._review_workers)
            item = result["drain"]["items"][0]
            self.assertEqual(item["state"], "reviewing")
            self.assertEqual(item["run_id"], run_id)

    def test_old_live_review_owner_is_not_recovered(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            workspace.mkdir(parents=True)
            daemon = self.make_daemon(root, provider="claude")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="Reviewing",
                provider_key="claude",
                model_alias="sonnet",
                worker_effort="high",
            )
            daemon.runs.update(run_id, pid=os.getpid())
            stale_at = time.time() - 24 * 60 * 60
            with daemon.runs._conn() as conn:
                conn.execute(
                    "UPDATE runs SET activity_at = ?, started_at = ? WHERE id = ?",
                    (stale_at, stale_at, run_id),
                )

            with patch.object(ReviewWorker, "start") as start_review:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            start_review.assert_not_called()
            active = daemon.runs.get(run_id)
            self.assertEqual(active["state"], "Reviewing")
            self.assertIsNone(active["last_error"])
            item = result["drain"]["items"][0]
            self.assertEqual(item["state"], "reviewing")
            self.assertEqual(item["run_id"], run_id)

    def test_dead_review_owner_is_recovered_and_replaced(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            workspace = root / "workspaces" / "rr-1"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            workspace.mkdir(parents=True)
            daemon = self.make_daemon(root, provider="claude")
            run_id = daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(workspace),
                branch="relay/rr-1",
                state="Reviewing",
                provider_key="claude",
                model_alias="sonnet",
                worker_effort="high",
            )
            daemon.runs.update(run_id, pid=999_999)

            with patch("orchestrator._process_is_alive", return_value=False), \
                    patch.object(ReviewWorker, "start") as start_review:
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            start_review.assert_called_once()
            recovered = daemon.runs.get(run_id)
            self.assertEqual(recovered["state"], "AwaitingReview")
            self.assertIn("process is no longer running", recovered["last_error"])
            item = result["drain"]["items"][0]
            self.assertEqual(item["state"], "reviewing")
            self.assertEqual(item["run_id"], run_id)

    def test_retry_exhaustion_becomes_drain_blocker(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="claude")
            for attempt in range(1, MAX_AUTO_DISPATCH_ATTEMPTS + 1):
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
            item = result["drain"]["items"][0]
            self.assertEqual(result["drain"]["state"], "blocked")
            self.assertEqual(item["state"], "blocked")
            self.assertEqual(item["blocker_owner"], "human")
            self.assertIn("automatic retry exhausted", item["reason"])
            self.assertIn("explicitly redispatch", item["blocker_next_step"])

    def test_quiescence_completes_and_next_ticket_starts_new_drain(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="done", run_id=7, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add done ticket")
            daemon = self.make_daemon(root, provider="codex")
            daemon.queue_drain_quiescence_seconds = 0
            daemon.runs.insert(
                ticket_id="RR-1",
                repo_path=str(repo.resolve()),
                workspace_path=str(root / "workspaces" / "rr-1"),
                branch="relay/rr-1",
                state="Merged",
                provider_key="codex",
                model_alias="gpt-5.5",
            )
            drain, _ = daemon.queue_drains.ensure_active(
                repo_path=str(repo),
                target_branch="main",
                provider_key="codex",
                observed_ticket_ids=["RR-1"],
            )

            first = daemon.reconcile_queue_drain(repo_path=str(repo), trigger="test")
            self.assertEqual(first["drain"]["state"], "waiting")
            second = daemon.reconcile_queue_drain(repo_path=str(repo), trigger="test")
            self.assertEqual(second["drain"]["id"], drain["id"])
            self.assertEqual(second["drain"]["state"], "completed")
            self.assertEqual(second["drain"]["provider_goal_state"], "completed")

            self.write_ticket(repo, "RR-2", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-2.md")
            self.git(repo, "commit", "-m", "add next ticket")

            with patch("orchestrator.create_worktree"), patch.object(Worker, "start"):
                next_result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            self.assertNotEqual(next_result["drain"]["id"], drain["id"])
            self.assertEqual(next_result["drain"]["observed_ticket_ids"], ["RR-2"])
            all_drains = daemon.list_queue_drains(
                repo_path=str(repo),
                include_terminal=True,
            )
            self.assertEqual(len(all_drains), 2)

    def test_claude_drain_uses_relay_durable_goal_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", run_id=None, sizing=True)
            self.git(repo, "add", ".orchestrator/RR-1.md")
            self.git(repo, "commit", "-m", "add ticket")
            daemon = self.make_daemon(root, provider="claude")

            with patch("orchestrator.create_worktree"), patch.object(Worker, "start"):
                result = daemon.sweep_ready_tickets(repo_path=str(repo), trigger="test")

            self.assertEqual(result["drain"]["provider_key"], "claude")
            self.assertEqual(result["drain"]["provider_goal_mode"], "relay-runner-durable-goal")
            self.assertEqual(result["drain"]["provider_goal_state"], "active")

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
        daemon.max_concurrent_workers = 0
        daemon.runs = RunsStore(root / "runs.db")
        daemon.queue_drains = QueueDrainStore(root / "queue_drains.db")
        daemon.messenger_outcomes = MessengerOutcomeStore(root / "messenger_outcomes.db")
        daemon.program_registry_path = root / "registry.json"
        daemon._dispatch_lock = threading.Lock()
        daemon._ticket_authoring_lock = threading.Lock()
        daemon._orchestrator_action_request_ids = set()
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
worker_sizing_rationale: "Drain invariant touches provider-neutral queue orchestration."
worker_provider_notes: "Codex uses model_reasoning_effort; Claude uses --effort. Queue drain semantics are provider-neutral."
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
