from __future__ import annotations

import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from graphify_core import (  # noqa: E402
    EDGE_AWAITS_MERGE,
    EDGE_CONTAINS,
    EDGE_DEPENDS_ON,
    EDGE_EXECUTES,
    EDGE_MENTIONS_FILE,
    EDGE_USES_PROVIDER,
    NODE_AGENT_PROVIDER,
    NODE_FILE,
    NODE_PROJECT,
    NODE_RUN,
    NODE_TICKET,
    GraphifyCoreStore,
)
from graphify_ingest import ingest_registered_projects  # noqa: E402


class GraphifyIngestTests(unittest.TestCase):
    def make_store(self) -> GraphifyCoreStore:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return GraphifyCoreStore(Path(tmp.name) / "graphify.db")

    def test_ingests_registered_projects_tickets_dependencies_and_runs_idempotently(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        client_repo = _make_repo(root, "client-dashboard")
        mouse_repo = _make_repo(root, "mouse-assist")

        ticket_paths = [
            _write_ticket(client_repo, "CD-1", "Prepare data", "done"),
            _write_ticket(client_repo, "CD-2", "Render dashboard", "in_progress", depends_on=["CD-1"], run_id=101),
            _write_ticket(mouse_repo, "MA-1", "Add overlay", "done"),
            _write_ticket(mouse_repo, "MA-2", "Polish controls", "ready", depends_on=["MA-1"], run_id=202),
        ]
        ticket_snapshots = {path: path.read_text() for path in ticket_paths}

        registry_path = root / "projects.json"
        registry_path.write_text(
            json.dumps(
                {
                    "activeProjectID": str(client_repo.resolve()),
                    "projects": [
                        {
                            "id": str(client_repo.resolve()),
                            "repoPath": str(client_repo.resolve()),
                            "alias": "client",
                            "displayName": "Client Dashboard",
                            "lastSeenAt": "2026-06-06T00:00:00Z",
                            "lastActivationSource": "programmatic",
                            "providers": {
                                "codex": {
                                    "lastActivatedAt": "2026-06-06T00:00:00Z",
                                    "lastActivationSource": "programmatic",
                                }
                            },
                        },
                        {
                            "id": str(mouse_repo.resolve()),
                            "repoPath": str(mouse_repo.resolve()),
                            "alias": "mouse",
                            "displayName": "Mouse Assist",
                            "lastSeenAt": "2026-06-06T00:01:00Z",
                            "lastActivationSource": "programmatic",
                            "providers": {
                                "claude": {
                                    "lastActivatedAt": "2026-06-06T00:01:00Z",
                                    "lastActivationSource": "programmatic",
                                }
                            },
                        },
                    ],
                }
            )
        )

        runs_db = root / "runs.db"
        _write_runs_db(
            runs_db,
            [
                _run_row(root, 101, "CD-2", client_repo, "Running", "codex"),
                _run_row(root, 102, "CD-1", client_repo, "Failed", "codex", exit_code=1),
                _run_row(root, 201, "MA-1", mouse_repo, "Stalled", "claude", last_error="Daemon restarted"),
                _run_row(root, 202, "MA-2", mouse_repo, "Succeeded", "claude", exit_code=0, ended_at=20.0),
            ],
        )

        store = self.make_store()
        counts = ingest_registered_projects(store, registry_path=registry_path, runs_db_path=runs_db)
        node_count = len(store.nodes())
        edge_count = len(store.edges())
        ingest_registered_projects(store, registry_path=registry_path, runs_db_path=runs_db)

        self.assertEqual(counts["projects"], 2)
        self.assertEqual(counts["tickets"], 4)
        self.assertEqual(counts["dependencies"], 2)
        self.assertEqual(counts["runs"], 4)
        self.assertEqual(len(store.nodes()), node_count)
        self.assertEqual(len(store.edges()), edge_count)
        for path, contents in ticket_snapshots.items():
            self.assertEqual(path.read_text(), contents)

        self.assertEqual(len(store.nodes(kind=NODE_PROJECT)), 2)
        self.assertEqual(
            sorted(ticket["body"]["ticket_id"] for ticket in store.nodes(kind=NODE_TICKET)),
            ["CD-1", "CD-2", "MA-1", "MA-2"],
        )
        self.assertEqual(
            sorted(provider["body"]["provider_key"] for provider in store.nodes(kind=NODE_AGENT_PROVIDER)),
            ["claude", "codex"],
        )

        client_project = store.find_node(kind=NODE_PROJECT, stable_key=f"repo:{client_repo.resolve()}")
        mouse_project = store.find_node(kind=NODE_PROJECT, stable_key=f"repo:{mouse_repo.resolve()}")
        cd1 = store.find_node(kind=NODE_TICKET, stable_key=f"repo:{client_repo.resolve()}:CD-1")
        cd2 = store.find_node(kind=NODE_TICKET, stable_key=f"repo:{client_repo.resolve()}:CD-2")
        ma1 = store.find_node(kind=NODE_TICKET, stable_key=f"repo:{mouse_repo.resolve()}:MA-1")
        ma2 = store.find_node(kind=NODE_TICKET, stable_key=f"repo:{mouse_repo.resolve()}:MA-2")
        self.assertIsNotNone(client_project)
        self.assertIsNotNone(mouse_project)
        self.assertIsNotNone(store.get_edge(src_id=client_project["id"], dst_id=cd2["id"], kind=EDGE_CONTAINS))
        self.assertIsNotNone(store.get_edge(src_id=cd2["id"], dst_id=cd1["id"], kind=EDGE_DEPENDS_ON))
        self.assertIsNotNone(store.get_edge(src_id=ma2["id"], dst_id=ma1["id"], kind=EDGE_DEPENDS_ON))

        runs = {run["body"]["run_id"]: run for run in store.nodes(kind=NODE_RUN)}
        self.assertEqual(runs[101]["body"]["state"], "active")
        self.assertEqual(runs[102]["body"]["state"], "failed")
        self.assertEqual(runs[201]["body"]["state"], "stalled")
        self.assertEqual(runs[202]["body"]["state"], "succeeded")
        self.assertEqual(runs[202]["body"]["program_state"], "awaiting_merge")
        self.assertIsNotNone(store.get_edge(src_id=runs[101]["id"], dst_id=cd2["id"], kind=EDGE_EXECUTES))
        self.assertIsNotNone(store.get_edge(src_id=runs[202]["id"], dst_id=ma2["id"], kind=EDGE_EXECUTES))
        self.assertIsNotNone(store.get_edge(src_id=ma2["id"], dst_id=runs[202]["id"], kind=EDGE_AWAITS_MERGE))
        self.assertEqual(len(store.edges(kind=EDGE_USES_PROVIDER)), 4)
        self.assertEqual(
            [run["body"]["run_id"] for run in store.runs_by_provider("codex", state="active")],
            [101],
        )
        self.assertEqual(
            [ticket["body"]["ticket_id"] for ticket in store.awaiting_merge(project_id=mouse_project["id"])],
            ["MA-2"],
        )

    def test_can_skip_project_file_indexing_for_status_refresh(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        repo = _make_repo(root, "status-refresh")
        _write_ticket(repo, "SR-1", "Summarize status", "ready")
        docs_dir = repo / "docs"
        docs_dir.mkdir()
        (docs_dir / "plan.md").write_text("# Plan\nStatusRefreshNeedle lives here.\n")

        registry_path = root / "projects.json"
        registry_path.write_text(
            json.dumps(
                {
                    "activeProjectID": str(repo.resolve()),
                    "projects": [
                        {
                            "id": str(repo.resolve()),
                            "repoPath": str(repo.resolve()),
                            "displayName": "Status Refresh",
                        }
                    ],
                }
            )
        )

        store = self.make_store()
        counts = ingest_registered_projects(store, registry_path=registry_path, index_files=False)
        project = store.find_node(kind=NODE_PROJECT, stable_key=f"repo:{repo.resolve()}")

        self.assertEqual(counts["projects"], 1)
        self.assertEqual(counts["tickets"], 1)
        self.assertEqual(counts["files_indexed"], 0)
        self.assertEqual(store.file_manifests(project_id=project["id"]), [])
        self.assertEqual(store.search_files("StatusRefreshNeedle", project_id=project["id"]), [])

    def test_indexes_project_files_incrementally_and_searches_without_live_grep(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        repo = _make_repo(root, "graphify-index")
        _write_ticket(
            repo,
            "GI-1",
            "Index docs",
            "ready",
            body_text="The implementation should touch docs/plan.md for the file index.",
        )
        docs_dir = repo / "docs"
        docs_dir.mkdir()
        plan = docs_dir / "plan.md"
        plan.write_text("# Plan\nRareGraphifyNeedle lives here.\n")
        services_dir = repo / "services"
        services_dir.mkdir()
        worker = services_dir / "worker.py"
        worker.write_text("def run():\n    return 'WorkerNeedle'\n")
        ignored_dir = repo / ".git"
        ignored_dir.mkdir()
        (ignored_dir / "ignored.md").write_text("IgnoredNeedle")
        deps_dir = repo / "node_modules" / "pkg"
        deps_dir.mkdir(parents=True)
        (deps_dir / "dep.js").write_text("DependencyNeedle")

        registry_path = root / "projects.json"
        registry_path.write_text(
            json.dumps(
                {
                    "activeProjectID": str(repo.resolve()),
                    "projects": [
                        {
                            "id": str(repo.resolve()),
                            "repoPath": str(repo.resolve()),
                            "alias": "graphify",
                            "displayName": "Graphify Index",
                            "providers": {"codex": {}, "claude": {}},
                        }
                    ],
                }
            )
        )

        store = self.make_store()
        counts = ingest_registered_projects(store, registry_path=registry_path)
        project = store.find_node(kind=NODE_PROJECT, stable_key=f"repo:{repo.resolve()}")
        ticket = store.find_node(kind=NODE_TICKET, stable_key=f"repo:{repo.resolve()}:GI-1")
        self.assertIsNotNone(project)
        self.assertIsNotNone(ticket)
        manifests = store.file_manifests(project_id=project["id"])

        self.assertEqual(counts["files_indexed"], 2)
        self.assertEqual([manifest["rel_path"] for manifest in manifests], ["docs/plan.md", "services/worker.py"])
        plan_manifest = store.get_file_manifest(project_id=project["id"], rel_path="docs/plan.md")
        self.assertEqual(plan_manifest["language"], "markdown")
        self.assertEqual(plan_manifest["size_bytes"], plan.stat().st_size)
        self.assertIsInstance(plan_manifest["mtime_ns"], int)
        self.assertIsInstance(plan_manifest["indexed_at"], float)
        self.assertEqual(store.search_files("RareGraphifyNeedle", project_id=project["id"])[0]["rel_path"], "docs/plan.md")
        self.assertEqual(store.search_files("IgnoredNeedle", project_id=project["id"]), [])
        self.assertEqual(store.search_files("DependencyNeedle", project_id=project["id"]), [])

        file_node = store.get_node(plan_manifest["id"])
        self.assertEqual(file_node["kind"], NODE_FILE)
        self.assertIsNotNone(store.get_edge(src_id=project["id"], dst_id=file_node["id"], kind=EDGE_CONTAINS))
        self.assertIsNotNone(store.get_edge(src_id=ticket["id"], dst_id=file_node["id"], kind=EDGE_MENTIONS_FILE))

        unchanged_counts = ingest_registered_projects(store, registry_path=registry_path)
        unchanged_manifest = store.get_file_manifest(project_id=project["id"], rel_path="docs/plan.md")
        self.assertEqual(unchanged_counts["files_indexed"], 0)
        self.assertEqual(unchanged_counts["files_unchanged"], 2)
        self.assertEqual(unchanged_manifest["indexed_at"], plan_manifest["indexed_at"])

        next_mtime = plan_manifest["mtime_ns"] + 1_000_000_000
        plan.write_text("# Plan\nChangedGraphifyNeedle replaces the old text.\n")
        os.utime(plan, ns=(next_mtime, next_mtime))
        changed_counts = ingest_registered_projects(store, registry_path=registry_path)
        self.assertEqual(changed_counts["files_indexed"], 1)
        self.assertEqual(changed_counts["files_unchanged"], 1)
        self.assertEqual(store.search_files("RareGraphifyNeedle", project_id=project["id"]), [])
        self.assertEqual(store.search_files("ChangedGraphifyNeedle", project_id=project["id"])[0]["rel_path"], "docs/plan.md")

        worker.unlink()
        deleted_counts = ingest_registered_projects(store, registry_path=registry_path)
        worker_manifest = store.get_file_manifest(project_id=project["id"], rel_path="services/worker.py")
        self.assertEqual(deleted_counts["files_deleted"], 1)
        self.assertIsNotNone(worker_manifest["deleted_at"])
        self.assertEqual(store.search_files("WorkerNeedle", project_id=project["id"]), [])


def _make_repo(root: Path, name: str) -> Path:
    repo = root / name
    (repo / ".orchestrator").mkdir(parents=True)
    return repo


def _write_ticket(
    repo: Path,
    ticket_id: str,
    title: str,
    status: str,
    *,
    depends_on: list[str] | None = None,
    run_id: int | None = None,
    body_text: str | None = None,
) -> Path:
    path = repo / ".orchestrator" / f"{ticket_id}.md"
    deps = "[" + ", ".join(depends_on or []) + "]"
    run_id_text = "null" if run_id is None else str(run_id)
    path.write_text(
        f"""---
id: {ticket_id}
title: {title}
status: {status}
priority: high
depends_on: {deps}
run_id: {run_id_text}
canceled: false
---

## Description

{body_text or title}
"""
    )
    return path


def _write_runs_db(path: Path, rows: list[dict]) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.execute(
            """
            CREATE TABLE runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ticket_id TEXT NOT NULL,
                repo_path TEXT NOT NULL,
                workspace_path TEXT NOT NULL,
                branch TEXT NOT NULL,
                state TEXT NOT NULL,
                attempt INTEGER NOT NULL DEFAULT 1,
                pid INTEGER,
                started_at REAL NOT NULL,
                ended_at REAL,
                exit_code INTEGER,
                log_path TEXT,
                last_error TEXT,
                activity TEXT,
                activity_at REAL
            )
            """
        )
        for row in rows:
            conn.execute(
                """
                INSERT INTO runs(
                    id, ticket_id, repo_path, workspace_path, branch, state,
                    attempt, pid, started_at, ended_at, exit_code, log_path,
                    last_error, activity, activity_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    row["id"],
                    row["ticket_id"],
                    row["repo_path"],
                    row["workspace_path"],
                    row["branch"],
                    row["state"],
                    row["attempt"],
                    None,
                    row["started_at"],
                    row["ended_at"],
                    row["exit_code"],
                    row["log_path"],
                    row["last_error"],
                    None,
                    None,
                ),
            )
        conn.commit()
    finally:
        conn.close()


def _run_row(
    root: Path,
    run_id: int,
    ticket_id: str,
    repo: Path,
    state: str,
    provider: str,
    *,
    exit_code: int | None = None,
    ended_at: float | None = None,
    last_error: str | None = None,
) -> dict:
    log_path = root / f"{run_id}-{provider}.log"
    if provider == "codex":
        log_path.write_text(json.dumps({"type": "thread.started"}) + "\n")
    else:
        log_path.write_text(json.dumps({"type": "assistant", "message": {}}) + "\n")
    return {
        "id": run_id,
        "ticket_id": ticket_id,
        "repo_path": str(repo.resolve()),
        "workspace_path": str(root / "workspaces" / str(run_id)),
        "branch": f"relay/{ticket_id.lower()}",
        "state": state,
        "attempt": 1,
        "started_at": 10.0,
        "ended_at": ended_at,
        "exit_code": exit_code,
        "log_path": str(log_path),
        "last_error": last_error,
    }


def _remove_tree(path: Path) -> None:
    for child in sorted(path.rglob("*"), reverse=True):
        if child.is_file() or child.is_symlink():
            child.unlink()
        else:
            child.rmdir()
    path.rmdir()


if __name__ == "__main__":
    unittest.main()
