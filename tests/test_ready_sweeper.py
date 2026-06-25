from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
import json
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

import orchestrator  # noqa: E402
from orchestrator import Daemon, Handler  # noqa: E402


class FakeRuns:
    def __init__(self, active: dict[str | tuple[str, str], dict] | None = None):
        self.active = active or {}

    def find_active(self, ticket_id: str, repo_path: str | None = None) -> dict | None:
        if repo_path is not None:
            active = self.active.get((ticket_id, str(Path(repo_path).resolve())))
            if active:
                return active
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

    def test_direct_runs_route_forwards_relay_command_metadata_when_present(self):
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
            "source": "voice",
            "relay_command_seq": 2,
            "relay_command_id": "second",
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
            "source": "voice",
            "relay_command_seq": 2,
            "relay_command_id": "second",
        }])

    def test_stale_relay_dispatch_is_rejected_before_claim(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_path = Path(tmp) / "voice_command_state.json"
            state_path.write_text(json.dumps({
                "relay_command_seq": 2,
                "relay_command_id": "second",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            daemon = object.__new__(Daemon)
            try:
                with self.assertRaisesRegex(ValueError, "stale Relay command"):
                    Daemon.dispatch(
                        daemon,
                        ticket_id="RR-1",
                        repo_path="/repo",
                        relay_command_seq=1,
                        relay_command_id="first",
                    )
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path

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

    def test_sweeper_skips_board_created_draft_ticket(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            self.make_repo(repo)
            self.write_ticket(repo, "RR-1", status="ready", draft=True)

            daemon = object.__new__(Daemon)
            daemon.runs = FakeRuns()
            calls: list[dict] = []
            daemon.dispatch = lambda **kwargs: calls.append(kwargs)

            result = Daemon.sweep_ready_tickets(daemon, repo_path=str(repo), trigger="test")

            self.assertEqual(calls, [])
            self.assertEqual(result["dispatched"], [])
            self.assertEqual(result["skipped"], [{"ticket_id": "RR-1", "reason": "draft"}])

    def test_dependency_progression_dispatches_already_queued_dependent(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            self.make_repo(repo)
            self.write_ticket(repo, "RR-1", status="done")
            self.write_ticket(repo, "RR-2", status="ready", depends_on=["RR-1"])

            daemon = object.__new__(Daemon)
            calls: list[dict] = []
            daemon.dispatch = lambda **kwargs: calls.append(kwargs) or {
                "already_active": False,
                "run": {"id": 42},
            }

            Daemon._progress_dependents(
                daemon,
                repo_path=str(repo),
                finished_ticket_id="RR-1",
            )

            self.assertEqual(calls, [{
                "ticket_id": "RR-2",
                "repo_path": str(repo),
                "source": "dependency-progression",
            }])

    def test_dependency_progression_does_not_promote_when_finished_ticket_is_not_done(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            self.make_repo(repo)
            self.write_ticket(repo, "RR-1", status="backlog")
            self.write_ticket(repo, "RR-2", status="backlog", depends_on=["RR-1"])

            daemon = object.__new__(Daemon)
            calls: list[dict] = []
            daemon.dispatch = lambda **kwargs: calls.append(kwargs)

            Daemon._progress_dependents(
                daemon,
                repo_path=str(repo),
                finished_ticket_id="RR-1",
            )

            self.assertEqual(calls, [])
            self.assertIn("status: backlog", (repo / ".orchestrator" / "RR-2.md").read_text())

    def test_ready_sweep_promotes_merged_done_dependency_then_dispatches(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            self.make_repo(repo)
            self.write_ticket(repo, "RR-1", status="done")
            self.write_ticket(repo, "RR-2", status="backlog", depends_on=["RR-1"])

            daemon = object.__new__(Daemon)
            daemon.runs = FakeRuns()
            calls: list[dict] = []
            daemon.dispatch = lambda **kwargs: calls.append(kwargs) or {
                "already_active": False,
                "run": {"id": 42},
            }

            result = Daemon.sweep_ready_tickets(daemon, repo_path=str(repo), trigger="test")

            self.assertEqual(result["promoted"], ["RR-2"])
            self.assertEqual(result["dispatched"], [{"ticket_id": "RR-2", "run_id": 42}])
            self.assertIn("status: ready", (repo / ".orchestrator" / "RR-2.md").read_text())
            self.assertEqual(calls, [{
                "ticket_id": "RR-2",
                "repo_path": str(repo.resolve()),
                "source": "ready-sweeper",
            }])

    def test_program_sweeper_dispatches_registered_projects_without_parent_board(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo_a = root / "repo-a"
            repo_b = root / "repo-b"
            self.make_repo(repo_a)
            self.make_repo(repo_b)
            self.write_ticket(repo_a, "RR-1", status="ready")
            self.write_ticket(repo_b, "RR-1", status="ready")

            registry = root / "projects.json"
            registry.write_text(json.dumps({
                "activeWorkspaceRootID": str(root.resolve()),
                "workspaceRoots": [{"id": str(root.resolve()), "rootPath": str(root.resolve())}],
                "projects": [
                    {"id": str(repo_a.resolve()), "repoPath": str(repo_a.resolve())},
                    {"id": str(repo_b.resolve()), "repoPath": str(repo_b.resolve())},
                ],
            }))

            daemon = object.__new__(Daemon)
            daemon.program_registry_path = registry
            daemon.runs = FakeRuns()
            calls: list[dict] = []

            def fake_dispatch(**kwargs):
                calls.append(kwargs)
                return {"already_active": False, "run": {"id": len(calls)}}

            daemon.dispatch = fake_dispatch

            result = Daemon.sweep_program_ready_tickets(
                daemon,
                trigger="program-board-refresh",
            )

            self.assertFalse((root / ".orchestrator").exists())
            self.assertEqual(
                calls,
                [
                    {"ticket_id": "RR-1", "repo_path": str(repo_a.resolve()), "source": "ready-sweeper"},
                    {"ticket_id": "RR-1", "repo_path": str(repo_b.resolve()), "source": "ready-sweeper"},
                ],
            )
            self.assertEqual(
                result["dispatched"],
                [
                    {"repo_path": str(repo_a.resolve()), "ticket_id": "RR-1", "run_id": 1},
                    {"repo_path": str(repo_b.resolve()), "ticket_id": "RR-1", "run_id": 2},
                ],
            )

    def test_repo_scoped_active_run_does_not_block_same_ticket_id_in_another_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo_a = root / "repo-a"
            repo_b = root / "repo-b"
            self.make_repo(repo_a)
            self.make_repo(repo_b)
            self.write_ticket(repo_a, "RR-1", status="ready")
            self.write_ticket(repo_b, "RR-1", status="ready")

            daemon = object.__new__(Daemon)
            daemon.runs = FakeRuns(active={
                ("RR-1", str(repo_a.resolve())): {"id": 99},
            })
            calls: list[dict] = []
            daemon.dispatch = lambda **kwargs: calls.append(kwargs) or {
                "already_active": False,
                "run": {"id": 42},
            }

            first = Daemon.sweep_ready_tickets(daemon, repo_path=str(repo_a), trigger="test")
            second = Daemon.sweep_ready_tickets(daemon, repo_path=str(repo_b), trigger="test")

            self.assertEqual(first["dispatched"], [])
            self.assertEqual(first["skipped"][0]["reason"], "already_active")
            self.assertEqual(second["dispatched"], [{"ticket_id": "RR-1", "run_id": 42}])
            self.assertEqual(calls, [{
                "ticket_id": "RR-1",
                "repo_path": str(repo_b.resolve()),
                "source": "ready-sweeper",
            }])

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
        draft: bool = False,
    ) -> None:
        deps = ", ".join(depends_on or [])
        run_value = "null" if run_id is None else str(run_id)
        draft_line = "draft: true\n" if draft else ""
        (repo / ".orchestrator" / f"{ticket_id}.md").write_text(
            f"""---
id: {ticket_id}
title: {ticket_id}
status: {status}
priority: medium
depends_on: [{deps}]
run_id: {run_value}
canceled: {str(canceled).lower()}
{draft_line}---

## Description

Test ticket.
"""
        )


if __name__ == "__main__":
    unittest.main()
