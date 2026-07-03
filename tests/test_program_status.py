from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from graphify_core import (  # noqa: E402
    EDGE_BLOCKS,
    EDGE_EXECUTES,
    NODE_PROJECT,
    NODE_RUN,
    NODE_TICKET,
    GraphifyCoreStore,
)
from program_status import build_program_status  # noqa: E402


class ProgramStatusTests(unittest.TestCase):
    def make_store(self) -> GraphifyCoreStore:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return GraphifyCoreStore(Path(tmp.name) / "graphify.db")

    def test_active_work_includes_project_ticket_and_provider_labels(self):
        store = self.make_store()
        project = _project(
            store,
            "/tmp/client-dashboard",
            "Client Dashboard",
            providers={"codex": {}, "claude": {}},
        )
        codex_ticket = _ticket(store, project, "CD-1", "Prepare data", "in_progress")
        claude_ticket = _ticket(store, project, "CD-2", "Render dashboard", "in_progress")
        _run(store, project, codex_ticket, 101, "active", "codex", model="gpt-5")
        _run(store, project, claude_ticket, 102, "active", "claude", model="sonnet")

        result = build_program_status(store, query="active_work", now=2000.0)
        message = result["message"]

        self.assertIn("Active work: 2 runs", message)
        self.assertIn("Client Dashboard (/tmp/client-dashboard)", message)
        self.assertIn("CD-1", message)
        self.assertIn("Codex/gpt-5", message)
        self.assertIn("CD-2", message)
        self.assertIn("Claude/sonnet", message)

        claude = build_program_status(store, query="active_work", provider="claude", now=2000.0)
        self.assertEqual(len(claude["items"]), 1)
        self.assertIn("Claude/sonnet", claude["message"])
        self.assertNotIn("Codex/gpt-5", claude["message"])

    def test_blocked_work_includes_project_path_ticket_id_and_waiting_dependency(self):
        store = self.make_store()
        project = _project(store, "/tmp/relay-runner", "Relay Runner")
        blocker = _ticket(store, project, "RR-1", "Finish dependency", "in_progress")
        _ticket(store, project, "RR-2", "Ship dependent", "ready", depends_on=["RR-1"])

        result = build_program_status(store, query="blocked_work", now=2000.0)
        message = result["message"]

        self.assertIn("Blocked work: 1 ticket", message)
        self.assertIn("Relay Runner (/tmp/relay-runner)", message)
        self.assertIn("RR-2", message)
        self.assertIn("waiting on RR-1", message)

    def test_queued_work_includes_dependency_waiting_and_excludes_awaiting_merge_tickets(self):
        store = self.make_store()
        project = _project(store, "/tmp/relay-runner", "Relay Runner")
        ready = _ticket(store, project, "RR-1", "Ready to dispatch", "ready")
        blocker = _ticket(store, project, "RR-2", "Finish dependency", "in_progress")
        blocked = _ticket(store, project, "RR-3", "Blocked ready ticket", "ready", depends_on=["RR-2"])
        awaiting = _ticket(store, project, "RR-4", "Awaiting review", "ready")
        _run(store, project, awaiting, 102, "awaiting_merge", "claude", model="sonnet")
        store.upsert_edge(src_id=blocker["id"], dst_id=blocked["id"], kind=EDGE_BLOCKS)

        result = build_program_status(store, query="ready_work", now=2000.0)

        self.assertEqual([item["ticket_id"] for item in result["items"]], ["RR-1", "RR-3"])
        self.assertEqual(result["items"][1]["blocked_by"], ["RR-2"])
        self.assertIn("Queued work: 2 tickets", result["message"])
        self.assertIn("RR-1", result["message"])
        self.assertIn("RR-3", result["message"])
        self.assertIn("waiting on RR-2", result["message"])
        self.assertNotIn("RR-4", result["message"])

    def test_ready_work_surfaces_missing_worker_sizing_metadata(self):
        store = self.make_store()
        project = _project(store, "/tmp/relay-runner", "Relay Runner")
        _ticket(store, project, "RR-1", "Ready without sizing", "ready")

        result = build_program_status(store, query="ready_work", now=2000.0)

        self.assertEqual(result["items"][0]["ticket_id"], "RR-1")
        self.assertIn("Missing worker sizing metadata", result["items"][0]["last_error"])
        self.assertIn("worker_model", result["message"])

    def test_discovery_work_includes_backlog_and_ready_without_active_or_blocked_items(self):
        store = self.make_store()
        project = _project(store, "/tmp/relay-runner", "Relay Runner")
        backlog = _ticket(store, project, "RR-1", "Shape program lane", "backlog")
        ready = _ticket(store, project, "RR-2", "Ready but not active", "ready")
        active = _ticket(store, project, "RR-3", "Running now", "ready")
        blocker = _ticket(store, project, "RR-4", "Blocking work", "in_progress")
        blocked = _ticket(store, project, "RR-5", "Blocked discovery", "backlog")
        done = _ticket(store, project, "RR-6", "Already done", "done")
        _run(store, project, active, 101, "active", "codex", model="gpt-5")
        store.upsert_edge(src_id=blocker["id"], dst_id=blocked["id"], kind=EDGE_BLOCKS)

        result = build_program_status(store, query="discovery_work", now=2000.0)

        self.assertEqual([item["ticket_id"] for item in result["items"]], ["RR-1", "RR-2"])
        self.assertIn("Discovery: 2 tickets", result["message"])
        self.assertNotIn("RR-3", result["message"])
        self.assertNotIn("RR-5", result["message"])
        self.assertNotIn("RR-6", result["message"])

    def test_done_work_includes_done_tickets(self):
        store = self.make_store()
        project = _project(store, "/tmp/relay-runner", "Relay Runner")
        _ticket(store, project, "RR-1", "Finished work", "done")
        _ticket(store, project, "RR-2", "Open work", "ready")

        result = build_program_status(store, query="done_work", now=2000.0)

        self.assertEqual([item["ticket_id"] for item in result["items"]], ["RR-1"])
        self.assertIn("Done work: 1 ticket", result["message"])
        self.assertNotIn("RR-2", result["message"])

    def test_board_lane_queries_mirror_project_board_run_placement(self):
        store = self.make_store()
        project = _project(
            store,
            "/tmp/relay-runner",
            "Relay Runner",
            providers={"codex": {}, "claude": {}},
        )
        _ticket(store, project, "RR-1", "Backlog work", "backlog")
        _ticket(store, project, "RR-2", "Queued work", "ready", priority="high", depends_on=["RR-1"])
        active = _ticket(store, project, "RR-3", "Running work", "ready")
        awaiting = _ticket(store, project, "RR-4", "Awaiting merge", "ready")
        _ticket(store, project, "RR-5", "Manual progress", "in_progress")
        _ticket(store, project, "RR-6", "Finished work", "done")
        _run(store, project, active, 101, "active", "codex", model="gpt-5")
        _run(store, project, awaiting, 102, "succeeded", "claude", model="sonnet")

        backlog = build_program_status(store, query="backlog_lane", now=2000.0)
        ready = build_program_status(store, query="ready_lane", now=2000.0)
        in_progress = build_program_status(store, query="in_progress_lane", now=2000.0)
        done = build_program_status(store, query="done_lane", now=2000.0)

        self.assertEqual([item["ticket_id"] for item in backlog["items"]], ["RR-1"])
        self.assertEqual([item["ticket_id"] for item in ready["items"]], ["RR-2"])
        self.assertEqual([item["ticket_id"] for item in in_progress["items"]], ["RR-3", "RR-5"])
        self.assertEqual([item["ticket_id"] for item in done["items"]], ["RR-4", "RR-6"])
        self.assertEqual(ready["items"][0]["priority"], "high")
        self.assertEqual(ready["items"][0]["depends_on"], ["RR-1"])
        self.assertEqual(ready["items"][0]["blocked_by"], ["RR-1"])
        self.assertIn("Queued: 1 ticket", ready["message"])
        self.assertEqual(done["items"][0]["run_state"], "awaiting_merge")
        self.assertEqual(done["items"][0]["provider"], "Claude/sonnet")

    def test_manual_backlog_dispatch_awaiting_review_appears_done_and_review_pending(self):
        store = self.make_store()
        project = _project(store, "/tmp/relay-runner", "Relay Runner")
        awaiting = _ticket(store, project, "RR-7", "Manual backlog dispatch", "backlog")
        _run(store, project, awaiting, 107, "awaiting_review", "codex", model="gpt-5")

        backlog = build_program_status(store, query="backlog_lane", now=2000.0)
        done = build_program_status(store, query="done_lane", now=2000.0)
        awaiting_merge = build_program_status(store, query="awaiting_merge", now=2000.0)

        self.assertEqual(backlog["items"], [])
        self.assertEqual([item["ticket_id"] for item in done["items"]], ["RR-7"])
        self.assertEqual(done["items"][0]["run_state"], "awaiting_review")
        self.assertEqual(awaiting_merge["items"][0]["status"], "awaiting review")
        self.assertIn("RR-7 - Manual backlog dispatch (awaiting review", awaiting_merge["message"])

    def test_done_tickets_with_stale_active_runs_stay_out_of_active_lanes(self):
        store = self.make_store()
        project = _project(
            store,
            "/tmp/relay-runner",
            "Relay Runner",
            providers={"codex": {}, "claude": {}},
        )
        codex_done = _ticket(store, project, "RR-67", "Codex completed work", "done")
        claude_done = _ticket(store, project, "RR-94", "Claude completed work", "done")
        _run(store, project, codex_done, 167, "active", "codex", model="gpt-5")
        _run(store, project, claude_done, 203, "active", "claude", model="sonnet")

        active = build_program_status(store, query="active_work", limit=0, now=2000.0)
        in_progress = build_program_status(store, query="in_progress_lane", limit=0, now=2000.0)
        done = build_program_status(store, query="done_lane", limit=0, now=2000.0)
        summary = build_program_status(store, query="summary", limit=0, now=2000.0)

        self.assertEqual(active["items"], [])
        self.assertEqual(in_progress["items"], [])
        self.assertEqual([item["ticket_id"] for item in done["items"]], ["RR-67", "RR-94"])
        self.assertEqual(summary["items"][0]["active_runs"], 0)
        self.assertEqual(summary["items"][0]["in_progress_tickets"], 0)
        self.assertEqual(summary["items"][0]["done_tickets"], 2)

    def test_zero_limit_returns_all_board_lane_items_across_projects(self):
        store = self.make_store()
        client = _project(store, "/tmp/client-dashboard", "Client Dashboard")
        tools = _project(store, "/tmp/tools", "Tools")
        for index in range(1, 18):
            _ticket(store, client, f"CD-{index}", "Client backlog", "backlog")
        for index in range(1, 10):
            _ticket(store, tools, f"TL-{index}", "Tools backlog", "backlog")

        result = build_program_status(store, query="backlog_lane", limit=0, now=2000.0)

        self.assertEqual(result["counts"], {"projects": 2, "items": 26})
        self.assertEqual(len(result["items"]), 26)
        self.assertEqual(
            {item["project"]["path"] for item in result["items"]},
            {"/tmp/client-dashboard", "/tmp/tools"},
        )

    def test_no_projects_has_clear_indexing_message(self):
        store = self.make_store()

        result = build_program_status(store, query="summary")

        self.assertEqual(result["counts"]["projects"], 0)
        self.assertEqual(result["items"], [])
        self.assertIn("No registered projects are indexed in Graphify Core", result["message"])

    def test_summary_includes_project_board_overview_counts(self):
        store = self.make_store()
        project = _project(store, "/tmp/relay-runner", "Relay Runner")
        _ticket(store, project, "RR-1", "Backlog work", "backlog")
        _ticket(store, project, "RR-2", "Queued work", "ready")
        active = _ticket(store, project, "RR-3", "Running work", "ready")
        awaiting = _ticket(store, project, "RR-4", "Awaiting merge", "ready")
        _ticket(store, project, "RR-5", "Finished work", "done")
        _run(store, project, active, 101, "active", "codex", model="gpt-5")
        _run(store, project, awaiting, 102, "awaiting_merge", "codex", model="gpt-5")

        result = build_program_status(store, query="summary", now=2000.0)
        item = result["items"][0]

        self.assertEqual(item["backlog_tickets"], 1)
        self.assertEqual(item["ready_tickets"], 1)
        self.assertEqual(item["in_progress_tickets"], 1)
        self.assertEqual(item["done_tickets"], 2)
        self.assertEqual(item["awaiting_merge"], 1)

    def test_awaiting_merge_query_distinguishes_review_and_conflict_states(self):
        store = self.make_store()
        project = _project(store, "/tmp/relay-runner", "Relay Runner")
        review = _ticket(store, project, "RR-1", "Needs review", "ready")
        conflict = _ticket(store, project, "RR-2", "Needs conflict resolution", "ready")
        _run(store, project, review, 101, "awaiting_review", "codex", model="gpt-5")
        _run(store, project, conflict, 102, "merge_conflict", "claude", model="sonnet")

        result = build_program_status(store, query="awaiting_merge", now=2000.0)

        statuses = {item["ticket_id"]: item["status"] for item in result["items"]}
        self.assertEqual(statuses["RR-1"], "awaiting review")
        self.assertEqual(statuses["RR-2"], "merge conflict")
        self.assertIn("RR-1 - Needs review (awaiting review", result["message"])
        self.assertIn("RR-2 - Needs conflict resolution (merge conflict", result["message"])


def _project(
    store: GraphifyCoreStore,
    repo_path: str,
    title: str,
    *,
    providers: dict | None = None,
) -> dict:
    return store.upsert_node(
        kind=NODE_PROJECT,
        stable_key=f"repo:{repo_path}",
        title=title,
        body={
            "repo_path": repo_path,
            "root_path": repo_path,
            "providers": providers or {},
        },
    )


def _ticket(
    store: GraphifyCoreStore,
    project: dict,
    ticket_id: str,
    title: str,
    state: str,
    *,
    priority: str = "medium",
    depends_on: list[str] | None = None,
) -> dict:
    return store.upsert_node(
        kind=NODE_TICKET,
        stable_key=f"{project['stable_key']}:{ticket_id}",
        project_id=project["id"],
        title=title,
        body={
            "ticket_id": ticket_id,
            "state": state,
            "priority": priority,
            "depends_on": depends_on or [],
        },
    )


def _run(
    store: GraphifyCoreStore,
    project: dict,
    ticket: dict,
    run_id: int,
    state: str,
    provider: str,
    *,
    model: str,
) -> dict:
    program_state = state
    if state in {"succeeded", "success", "done"} and ticket["body"].get("state") != "done":
        program_state = "awaiting_merge"
    run = store.upsert_node(
        kind=NODE_RUN,
        stable_key=f"run:{run_id}",
        project_id=project["id"],
        title=f"{ticket['body']['ticket_id']} run {run_id}",
        body={
            "run_id": run_id,
            "ticket_id": ticket["body"]["ticket_id"],
            "state": state,
            "program_state": program_state,
            "provider_key": provider,
            "model_alias": model,
            "branch": f"relay/{ticket['body']['ticket_id'].lower()}",
            "started_at": float(run_id),
        },
    )
    store.upsert_edge(src_id=run["id"], dst_id=ticket["id"], kind=EDGE_EXECUTES)
    return run


if __name__ == "__main__":
    unittest.main()
