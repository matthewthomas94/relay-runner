from __future__ import annotations

import os
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from orchestrator import Daemon, ReviewWorker, RunsStore, Worker  # noqa: E402


class OrchestratorSupervisionTests(unittest.TestCase):
    def test_implementation_workers_are_not_terminated_at_health_check_intervals(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                agent = self.make_slow_failing_agent(root)
                store = RunsStore(root / "runs.db")
                run_id = store.insert(
                    ticket_id="RR-1",
                    repo_path=str(root),
                    workspace_path=str(root),
                    branch="relay/rr-1",
                    state="Claimed",
                    provider_key=provider,
                )
                worker = Worker(
                    run_id=run_id,
                    run=store.get(run_id) or {},
                    prompt="test prompt",
                    agent_bin=str(agent),
                    agent_kind=provider,
                    store=store,
                    log_path=root / "run.log",
                )

                started = time.monotonic()
                worker._run()

                updated = store.get(run_id) or {}
                self.assertGreaterEqual(time.monotonic() - started, 0.15)
                self.assertEqual(updated["state"], "Failed")
                self.assertIn("exit=7", updated["last_error"])
                self.assertNotIn("Timed out", updated["last_error"])

    def test_review_workers_are_not_terminated_at_health_check_intervals(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            agent = self.make_slow_failing_agent(root)
            store = RunsStore(root / "runs.db")
            run_id = store.insert(
                ticket_id="RR-1",
                repo_path=str(root),
                workspace_path=str(root),
                branch="relay/rr-1",
                state="AwaitingReview",
                provider_key="codex",
            )
            worker = ReviewWorker(
                run_id=run_id,
                run=store.get(run_id) or {},
                prompt="test prompt",
                agent_bin=str(agent),
                agent_kind="codex",
                store=store,
                log_path=root / "run.log",
            )

            started = time.monotonic()
            worker._run()

            updated = store.get(run_id) or {}
            self.assertGreaterEqual(time.monotonic() - started, 0.15)
            self.assertEqual(updated["state"], "AwaitingReview")
            self.assertIn("exit=7", updated["last_error"])
            self.assertNotIn("timed out", updated["last_error"].lower())

    def test_health_checks_warn_without_stopping_a_live_run(self):
        daemon = object.__new__(Daemon)
        daemon.worker_health_check_seconds = 600
        daemon._run_health = {}
        daemon._run_health_lock = threading.Lock()
        daemon._emit_lifecycle = Mock()
        run = {
            "id": 12,
            "ticket_id": "RR-9",
            "state": "Running",
            "pid": os.getpid(),
            "repo_path": "/tmp/repo",
            "provider_key": "codex",
        }

        with patch.object(daemon, "_run_progress_signature", return_value=("same",)):
            self.assertIsNone(daemon._observe_run_health(run, now=100.0))
            warning = daemon._observe_run_health(run, now=700.0)

        self.assertIn("no observable progress", warning)
        daemon._emit_lifecycle.assert_called_once_with(
            "run-health-warning",
            ticket_id="RR-9",
            run_id=12,
            source="orchestrator",
            message="RR-9 run 12 is alive but has no observable progress in the last 10 minutes",
            repo_path="/tmp/repo",
            provider_key="codex",
        )

    def test_health_checks_report_progress_without_warning(self):
        daemon = object.__new__(Daemon)
        daemon.worker_health_check_seconds = 600
        daemon._run_health = {}
        daemon._run_health_lock = threading.Lock()
        daemon._emit_lifecycle = Mock()
        run = {
            "id": 12,
            "ticket_id": "RR-9",
            "state": "Running",
            "pid": os.getpid(),
            "repo_path": "/tmp/repo",
            "provider_key": "claude",
        }

        with patch.object(
            daemon,
            "_run_progress_signature",
            side_effect=[("before",), ("after",)],
        ):
            daemon._observe_run_health(run, now=100.0)
            warning = daemon._observe_run_health(run, now=700.0)

        self.assertIsNone(warning)
        daemon._emit_lifecycle.assert_called_once_with(
            "run-health-check",
            ticket_id="RR-9",
            run_id=12,
            source="orchestrator",
            message="RR-9 run 12 is alive and made observable progress in the last 10 minutes",
            repo_path="/tmp/repo",
            provider_key="claude",
            queue_messenger=False,
        )

    def test_daemon_restart_preserves_a_live_worker(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = RunsStore(Path(tmp) / "runs.db")
            run_id = store.insert(
                ticket_id="RR-1",
                repo_path=tmp,
                workspace_path=tmp,
                branch="relay/rr-1",
                state="Running",
            )
            store.update(run_id, pid=os.getpid())

            reconciled = store.reconcile_on_startup()

            self.assertEqual(reconciled, 0)
            self.assertEqual((store.get(run_id) or {})["state"], "Running")

    def test_daemon_restart_recovers_a_dead_worker(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = RunsStore(Path(tmp) / "runs.db")
            run_id = store.insert(
                ticket_id="RR-1",
                repo_path=tmp,
                workspace_path=tmp,
                branch="relay/rr-1",
                state="Running",
            )
            store.update(run_id, pid=999_999)

            with patch("orchestrator._process_is_alive", return_value=False):
                reconciled = store.reconcile_on_startup()

            updated = store.get(run_id) or {}
            self.assertEqual(reconciled, 1)
            self.assertEqual(updated["state"], "Stalled")
            self.assertIn("process was no longer running", updated["last_error"])

    @staticmethod
    def make_slow_failing_agent(root: Path) -> Path:
        agent = root / "fake-agent.sh"
        agent.write_text("#!/bin/sh\nsleep 0.2\necho finished naturally\nexit 7\n")
        agent.chmod(agent.stat().st_mode | stat.S_IXUSR)
        return agent
