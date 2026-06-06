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
    EDGE_CONTAINS,
    EDGE_RELATED_TO,
    NODE_DECISION,
    NODE_IDEA,
    NODE_PROGRAM_EVENT,
    NODE_PROJECT,
    NODE_RISK,
    NODE_RUN,
    NODE_STATUS,
    NODE_TICKET,
    GraphifyCoreStore,
)
from session_capture import capture_session_review  # noqa: E402


class SessionCaptureTests(unittest.TestCase):
    def make_store(self) -> GraphifyCoreStore:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return GraphifyCoreStore(Path(tmp.name) / "graphify.db")

    def test_capture_creates_structured_nodes_and_links_existing_project_ticket_and_run(self):
        store = self.make_store()
        repo = Path(tempfile.mkdtemp()) / "relay-runner"
        self.addCleanup(lambda: _remove_tree(repo.parent))
        repo.mkdir()
        project = store.upsert_node(
            kind=NODE_PROJECT,
            stable_key=f"repo:{repo.resolve()}",
            title="Relay Runner",
            body={"repo_path": str(repo.resolve())},
        )
        ticket = store.upsert_node(
            kind=NODE_TICKET,
            stable_key=f"{project['stable_key']}:RR-43",
            project_id=project["id"],
            title="Native session review capture",
            body={"ticket_id": "RR-43", "state": "in_progress"},
        )
        run = store.upsert_node(
            kind=NODE_RUN,
            stable_key="run:28",
            project_id=project["id"],
            title="RR-43 run 28",
            body={"run_id": 28, "ticket_id": "RR-43", "state": "active"},
        )

        result = capture_session_review(
            store,
            repo_path=repo,
            ticket_id="RR-43",
            run_id=28,
            provider="codex",
            context="User approved native capture after PM-sync replacement discussion.",
            capture_id="cap-rr-43",
            occurred_at=1000.0,
            entries=[
                {"kind": "shipped", "title": "Graph capture shipped"},
                {"kind": "decision", "title": "Use Graphify Core as ledger"},
                {"kind": "blocker", "title": "Transcript export unavailable"},
                {"kind": "idea", "title": "Summarize follow-up tickets"},
                {"kind": "status", "status": "awaiting review"},
            ],
        )

        self.assertEqual(result["counts"][NODE_PROGRAM_EVENT], 1)
        self.assertEqual(result["counts"][NODE_DECISION], 1)
        self.assertEqual(result["counts"][NODE_RISK], 1)
        self.assertEqual(result["counts"][NODE_IDEA], 1)
        self.assertEqual(result["counts"][NODE_STATUS], 1)

        event = store.find_node(kind=NODE_PROGRAM_EVENT, stable_key="capture:cap-rr-43:0")
        risk = store.find_node(kind=NODE_RISK, stable_key="capture:cap-rr-43:2")
        status = store.find_node(kind=NODE_STATUS, stable_key="capture:cap-rr-43:4")
        self.assertEqual(event["body"]["event_type"], "shipped_work")
        self.assertEqual(event["body"]["provider_key"], "codex")
        self.assertEqual(event["body"]["evidence"]["ticket_id"], "RR-43")
        self.assertEqual(event["body"]["evidence"]["run_id"], 28)
        self.assertEqual(risk["body"]["risk_type"], "blocker")
        self.assertEqual(status["body"]["status"], "awaiting review")
        self.assertIsNotNone(store.get_edge(src_id=project["id"], dst_id=event["id"], kind=EDGE_CONTAINS))
        self.assertIsNotNone(store.get_edge(src_id=event["id"], dst_id=ticket["id"], kind=EDGE_RELATED_TO))
        self.assertIsNotNone(store.get_edge(src_id=event["id"], dst_id=run["id"], kind=EDGE_RELATED_TO))
        self.assertIsNotNone(store.get_edge(src_id=risk["id"], dst_id=ticket["id"], kind=EDGE_BLOCKS))

    def test_capture_can_create_project_and_ticket_from_repo_without_pm_project_id(self):
        store = self.make_store()
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        repo = root / "client-dashboard"
        (repo / ".orchestrator").mkdir(parents=True)
        self.assertFalse((repo / ".pm" / "project-id").exists())
        _write_ticket(repo, "CD-7", "Capture wrap-up", "done")

        result = capture_session_review(
            store,
            repo_path=repo,
            ticket_id="CD-7",
            capture_id="cap-no-pm",
            entries=[{"kind": "note", "title": "Reviewed work without PM sync"}],
        )

        project = store.find_node(kind=NODE_PROJECT, stable_key=f"repo:{repo.resolve()}")
        ticket = store.find_node(kind=NODE_TICKET, stable_key=f"{project['stable_key']}:CD-7")
        event = store.find_node(kind=NODE_PROGRAM_EVENT, stable_key="capture:cap-no-pm:0")

        self.assertEqual(result["counts"][NODE_PROGRAM_EVENT], 1)
        self.assertEqual(project["body"]["source"], "session_capture")
        self.assertEqual(ticket["body"]["ticket_id"], "CD-7")
        self.assertIsNotNone(store.get_edge(src_id=event["id"], dst_id=ticket["id"], kind=EDGE_RELATED_TO))

    def test_capture_normalizes_claude_provider_metadata(self):
        store = self.make_store()
        repo = Path(tempfile.mkdtemp()) / "relay-runner"
        self.addCleanup(lambda: _remove_tree(repo.parent))
        repo.mkdir()

        result = capture_session_review(
            store,
            repo_path=repo,
            provider="Claude Code",
            context="Claude parity workspace verification.",
            capture_id="cap-claude-parity",
            occurred_at=1000.0,
            entries=[{"kind": "note", "title": "Claude capture verified"}],
        )

        event = store.find_node(kind=NODE_PROGRAM_EVENT, stable_key="capture:cap-claude-parity:0")
        self.assertEqual(result["provider"], "claude")
        self.assertIn("(claude)", result["message"])
        self.assertEqual(event["body"]["provider_key"], "claude")
        self.assertEqual(event["body"]["context"], "Claude parity workspace verification.")


def _write_ticket(repo: Path, ticket_id: str, title: str, status: str) -> None:
    path = repo / ".orchestrator" / f"{ticket_id}.md"
    path.write_text(
        f"""---
id: {ticket_id}
title: {title}
status: {status}
priority: high
depends_on: []
run_id: null
canceled: false
---

## Description

{title}
"""
    )


def _remove_tree(path: Path) -> None:
    import shutil

    shutil.rmtree(path, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
