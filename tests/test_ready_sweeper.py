from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

import orchestrator  # noqa: E402
from orchestrator import Daemon, Handler  # noqa: E402


class FakeRuns:
    def __init__(self, active: dict[str, dict] | None = None):
        self.active = active or {}

    def find_active(self, ticket_id: str) -> dict | None:
        return self.active.get(ticket_id)


class ReadySweeperTests(unittest.TestCase):
    def test_direct_runs_route_still_dispatches_ready_transition(self):
        calls: list[dict] = []

        class FakeDaemon:
            def dispatch(self, **kwargs):
                calls.append(kwargs)
                return {"already_active": False, "run": {"id": 12}}

        handler = object.__new__(Handler)
        handler.daemon = FakeDaemon()
        original_read_body = orchestrator._read_body
        orchestrator._read_body = lambda _: {
            "ticket_id": "RR-1",
            "repo_path": "/repo",
            "source": "board-drop",
        }
        try:
            status, payload = Handler._route(handler, "POST", "/v1/runs")
        finally:
            orchestrator._read_body = original_read_body

        self.assertEqual(status, 202)
        self.assertEqual(payload["run"]["id"], 12)
        self.assertEqual(calls, [{
            "ticket_id": "RR-1",
            "repo_path": "/repo",
            "context": None,
            "source": "board-drop",
        }])

    def test_sweeper_dispatches_stale_ready_ticket(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            self.make_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready")

            daemon = object.__new__(Daemon)
            daemon.runs = FakeRuns()
            calls: list[dict] = []

            def fake_dispatch(**kwargs):
                calls.append(kwargs)
                return {"already_active": False, "run": {"id": 42}}

            daemon.dispatch = fake_dispatch

            result = Daemon.sweep_ready_tickets(daemon, repo_path=str(repo), trigger="test")

            self.assertEqual(result["dispatched"], [{"ticket_id": "RR-1", "run_id": 42}])
            self.assertEqual(calls, [{
                "ticket_id": "RR-1",
                "repo_path": str(repo.resolve()),
                "source": "ready-sweeper",
            }])

    def test_sweeper_skips_active_and_ineligible_tickets(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            self.make_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready")
            self.write_ticket(repo, "RR-2", status="in_progress")
            self.write_ticket(repo, "RR-3", status="done")
            self.write_ticket(repo, "RR-4", status="ready", canceled=True)
            self.write_ticket(repo, "RR-5", status="ready", depends_on=["RR-missing"])
            self.write_ticket(repo, "RR-6", status="ready", run_id=123)

            daemon = object.__new__(Daemon)
            daemon.runs = FakeRuns(active={"RR-1": {"id": 99}})
            calls: list[dict] = []
            daemon.dispatch = lambda **kwargs: calls.append(kwargs)

            result = Daemon.sweep_ready_tickets(daemon, repo_path=str(repo), trigger="test")

            self.assertEqual(calls, [])
            self.assertEqual(result["dispatched"], [])
            reasons = {item["ticket_id"]: item["reason"] for item in result["skipped"]}
            self.assertEqual(reasons["RR-1"], "already_active")
            self.assertEqual(reasons["RR-2"], "status:in_progress")
            self.assertEqual(reasons["RR-3"], "status:done")
            self.assertEqual(reasons["RR-4"], "canceled")
            self.assertEqual(reasons["RR-5"], "dependencies_not_done")
            self.assertEqual(reasons["RR-6"], "run_id_present")

    def make_repo(self, repo: Path) -> None:
        (repo / ".git").mkdir(parents=True)
        (repo / ".orchestrator").mkdir()

    def write_ticket(
        self,
        repo: Path,
        ticket_id: str,
        *,
        status: str,
        canceled: bool = False,
        depends_on: list[str] | None = None,
        run_id: int | None = None,
    ) -> None:
        deps = ", ".join(depends_on or [])
        run_value = "null" if run_id is None else str(run_id)
        (repo / ".orchestrator" / f"{ticket_id}.md").write_text(
            f"""---
id: {ticket_id}
title: {ticket_id}
status: {status}
priority: medium
depends_on: [{deps}]
run_id: {run_value}
canceled: {str(canceled).lower()}
---

## Description

Test ticket.
"""
        )


if __name__ == "__main__":
    unittest.main()
