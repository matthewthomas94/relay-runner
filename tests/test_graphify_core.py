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
    CORE_EDGE_KINDS,
    CORE_NODE_KINDS,
    EDGE_AWAITS_MERGE,
    EDGE_BELONGS_TO,
    EDGE_BLOCKS,
    EDGE_CONTAINS,
    EDGE_EXECUTES,
    EDGE_USES_PROVIDER,
    NODE_AGENT_PROVIDER,
    NODE_PROJECT,
    NODE_RUN,
    NODE_TICKET,
    GraphifyCoreStore,
)


class GraphifyCoreStoreTests(unittest.TestCase):
    def make_store(self) -> GraphifyCoreStore:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return GraphifyCoreStore(Path(tmp.name) / "graphify.db")

    def test_core_node_and_edge_kinds_can_be_stored(self):
        store = self.make_store()
        nodes = [
            store.upsert_node(
                kind=kind,
                stable_key=f"fixture:{kind}",
                title=kind,
                body={"kind": kind},
            )
            for kind in sorted(CORE_NODE_KINDS)
        ]

        src = nodes[0]
        dst = nodes[1]
        for edge_kind in sorted(CORE_EDGE_KINDS):
            store.upsert_edge(
                src_id=src["id"],
                dst_id=dst["id"],
                kind=edge_kind,
                body={"source": "unit-test"},
            )

        self.assertEqual(
            {node["kind"] for node in store.nodes()},
            set(CORE_NODE_KINDS),
        )
        self.assertEqual(
            {edge["kind"] for edge in store.edges()},
            set(CORE_EDGE_KINDS),
        )

    def test_node_upsert_is_idempotent(self):
        store = self.make_store()

        first = store.upsert_node(
            kind=NODE_PROJECT,
            stable_key="repo:/tmp/example",
            title="Example",
            body={"root_path": "/tmp/example", "active": False},
        )
        second = store.upsert_node(
            kind=NODE_PROJECT,
            stable_key="repo:/tmp/example",
            title="Example renamed",
            body={"root_path": "/tmp/example", "active": True},
        )

        self.assertEqual(first["id"], second["id"])
        self.assertEqual(len(store.nodes(kind=NODE_PROJECT)), 1)
        self.assertEqual(second["title"], "Example renamed")
        self.assertEqual(second["body"]["active"], True)

    def test_edge_upsert_and_neighbor_query_are_idempotent(self):
        store = self.make_store()
        project = store.upsert_node(
            kind=NODE_PROJECT,
            stable_key="repo:/tmp/example",
            title="Example",
            body={"root_path": "/tmp/example"},
        )
        ticket = store.upsert_node(
            kind=NODE_TICKET,
            stable_key="repo:/tmp/example:RR-1",
            project_id=project["id"],
            title="Build thing",
            body={"ticket_id": "RR-1", "state": "ready"},
        )

        store.upsert_edge(
            src_id=ticket["id"],
            dst_id=project["id"],
            kind=EDGE_BELONGS_TO,
            body={"source": "first-pass"},
        )
        edge = store.upsert_edge(
            src_id=ticket["id"],
            dst_id=project["id"],
            kind=EDGE_BELONGS_TO,
            body={"source": "second-pass"},
        )
        store.upsert_edge(
            src_id=project["id"],
            dst_id=ticket["id"],
            kind=EDGE_CONTAINS,
            body={},
        )

        self.assertEqual(len(store.edges(kind=EDGE_BELONGS_TO)), 1)
        self.assertEqual(edge["body"]["source"], "second-pass")
        outward = store.neighbors(ticket["id"], edge_kind=EDGE_BELONGS_TO, direction="out")
        inward = store.neighbors(project["id"], edge_kind=EDGE_BELONGS_TO, direction="in")
        self.assertEqual(outward[0]["node"]["id"], project["id"])
        self.assertEqual(inward[0]["node"]["id"], ticket["id"])

    def test_provider_neutral_run_representation(self):
        store = self.make_store()
        project = store.upsert_node(
            kind=NODE_PROJECT,
            stable_key="repo:/tmp/example",
            title="Example",
            body={"root_path": "/tmp/example"},
        )
        codex_ticket = store.upsert_node(
            kind=NODE_TICKET,
            stable_key="repo:/tmp/example:RR-1",
            project_id=project["id"],
            title="Codex ticket",
            body={"ticket_id": "RR-1", "state": "in_progress"},
        )
        claude_ticket = store.upsert_node(
            kind=NODE_TICKET,
            stable_key="repo:/tmp/example:RR-2",
            project_id=project["id"],
            title="Claude ticket",
            body={"ticket_id": "RR-2", "state": "done"},
        )
        codex = store.upsert_node(
            kind=NODE_AGENT_PROVIDER,
            stable_key="codex",
            title="Codex",
            body={"provider_key": "codex", "health": "ready"},
        )
        claude = store.upsert_node(
            kind=NODE_AGENT_PROVIDER,
            stable_key="claude",
            title="Claude",
            body={"provider_key": "claude", "health": "ready"},
        )
        codex_run = store.upsert_node(
            kind=NODE_RUN,
            stable_key="run:23",
            project_id=project["id"],
            title="RR-1 run 23",
            body={
                "run_id": 23,
                "ticket_id": "RR-1",
                "attempt": 1,
                "provider_key": "codex",
                "model_alias": "gpt-5",
                "state": "running",
                "branch": "relay/rr-1",
                "workspace_path": "/tmp/workspaces/rr-1",
                "log_path": "/tmp/workspaces/rr-1/.relay/run.log",
                "started_at": 123.0,
                "ended_at": None,
                "exit_code": None,
                "provider": {"cli": "codex"},
            },
        )
        claude_run = store.upsert_node(
            kind=NODE_RUN,
            stable_key="run:24",
            project_id=project["id"],
            title="RR-2 run 24",
            body={
                "run_id": 24,
                "ticket_id": "RR-2",
                "attempt": 1,
                "provider_key": "claude",
                "model_alias": "sonnet",
                "state": "succeeded",
                "branch": "relay/rr-2",
                "workspace_path": "/tmp/workspaces/rr-2",
                "log_path": "/tmp/workspaces/rr-2/.relay/run.log",
                "started_at": 124.0,
                "ended_at": 125.0,
                "exit_code": 0,
                "provider": {"cli": "claude"},
            },
        )

        for run, ticket, provider in (
            (codex_run, codex_ticket, codex),
            (claude_run, claude_ticket, claude),
        ):
            store.upsert_edge(src_id=run["id"], dst_id=ticket["id"], kind=EDGE_EXECUTES)
            store.upsert_edge(src_id=run["id"], dst_id=provider["id"], kind=EDGE_USES_PROVIDER)

        codex_runs = store.runs_by_provider("codex")
        claude_runs = store.runs_by_provider("claude", state="succeeded")
        claude_done_tickets = store.tickets_by_state("done", provider="claude")

        self.assertEqual([run["body"]["run_id"] for run in codex_runs], [23])
        self.assertEqual([run["body"]["run_id"] for run in claude_runs], [24])
        self.assertEqual([ticket["body"]["ticket_id"] for ticket in claude_done_tickets], ["RR-2"])
        self.assertEqual(codex_runs[0]["body"]["provider"]["cli"], "codex")
        self.assertEqual(claude_runs[0]["body"]["provider"]["cli"], "claude")

    def test_blocked_and_awaiting_merge_queries(self):
        store = self.make_store()
        blocker = store.upsert_node(
            kind=NODE_TICKET,
            stable_key="repo:/tmp/example:RR-1",
            title="Blocker",
            body={"ticket_id": "RR-1", "state": "in_progress"},
        )
        blocked = store.upsert_node(
            kind=NODE_TICKET,
            stable_key="repo:/tmp/example:RR-2",
            title="Blocked",
            body={"ticket_id": "RR-2", "state": "ready"},
        )
        awaiting = store.upsert_node(
            kind=NODE_TICKET,
            stable_key="repo:/tmp/example:RR-3",
            title="Awaiting merge",
            body={"ticket_id": "RR-3", "state": "awaiting_merge"},
        )

        store.upsert_edge(src_id=blocker["id"], dst_id=blocked["id"], kind=EDGE_BLOCKS)
        store.upsert_edge(src_id=awaiting["id"], dst_id=blocker["id"], kind=EDGE_AWAITS_MERGE)

        self.assertEqual(
            [ticket["body"]["ticket_id"] for ticket in store.blocked_work()],
            ["RR-2"],
        )
        self.assertEqual(
            [ticket["body"]["ticket_id"] for ticket in store.awaiting_merge()],
            ["RR-1", "RR-3"],
        )


if __name__ == "__main__":
    unittest.main()
