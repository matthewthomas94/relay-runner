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

    def test_blocked_work_includes_project_path_ticket_id_and_blocker(self):
        store = self.make_store()
        project = _project(store, "/tmp/relay-runner", "Relay Runner")
        blocker = _ticket(store, project, "RR-1", "Finish dependency", "in_progress")
        blocked = _ticket(store, project, "RR-2", "Ship dependent", "ready")
        store.upsert_edge(src_id=blocker["id"], dst_id=blocked["id"], kind=EDGE_BLOCKS)

        result = build_program_status(store, query="blocked_work", now=2000.0)
        message = result["message"]

        self.assertIn("Blocked work: 1 ticket", message)
        self.assertIn("Relay Runner (/tmp/relay-runner)", message)
        self.assertIn("RR-2", message)
        self.assertIn("blocked by RR-1", message)

    def test_no_projects_has_clear_indexing_message(self):
        store = self.make_store()

        result = build_program_status(store, query="summary")

        self.assertEqual(result["counts"]["projects"], 0)
        self.assertEqual(result["items"], [])
        self.assertIn("No registered projects are indexed in Graphify Core", result["message"])


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
) -> dict:
    return store.upsert_node(
        kind=NODE_TICKET,
        stable_key=f"{project['stable_key']}:{ticket_id}",
        project_id=project["id"],
        title=title,
        body={"ticket_id": ticket_id, "state": state},
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
    run = store.upsert_node(
        kind=NODE_RUN,
        stable_key=f"run:{run_id}",
        project_id=project["id"],
        title=f"{ticket['body']['ticket_id']} run {run_id}",
        body={
            "run_id": run_id,
            "ticket_id": ticket["body"]["ticket_id"],
            "state": state,
            "provider_key": provider,
            "model_alias": model,
            "started_at": float(run_id),
        },
    )
    store.upsert_edge(src_id=run["id"], dst_id=ticket["id"], kind=EDGE_EXECUTES)
    return run


if __name__ == "__main__":
    unittest.main()
