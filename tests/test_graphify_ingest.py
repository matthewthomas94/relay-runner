from __future__ import annotations

import json
import os
import sqlite3
import subprocess
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
from program_status import build_program_status  # noqa: E402


class GraphifyIngestTests(unittest.TestCase):
    def make_store(self) -> GraphifyCoreStore:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return GraphifyCoreStore(Path(tmp.name) / "graphify.db")

    def test_ingests_registry_v2_identity_and_skips_unavailable_projects(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        available = _make_repo(root, "available")
        unavailable = _make_repo(root, "offline")
        _write_ticket(available, "AV-1", "Artifact-backed work", "backlog")
        _write_ticket(unavailable, "OF-1", "Unavailable work", "backlog")
        registry_path = root / "registry-v2.json"
        registry_path.write_text(json.dumps({
            "schema_version": 2,
            "active_project_id": "project-available",
            "projects": [
                {
                    "project_id": "project-available",
                    "display_name": "Available Project",
                    "selected_path": str(available),
                    "last_resolved_path": str(available.resolve()),
                    "availability": "available",
                    "last_resolved_at": "2026-08-04T05:00:00Z",
                    "remote": {
                        "mode": "local_only",
                        "remoteName": None,
                        "artifactRef": "refs/heads/relay/artifacts",
                    },
                },
                {
                    "project_id": "project-offline",
                    "display_name": "Offline Project",
                    "selected_path": str(unavailable),
                    "last_resolved_path": str(unavailable.resolve()),
                    "availability": "offline",
                },
            ],
        }))

        store = self.make_store()
        counts = ingest_registered_projects(store, registry_path=registry_path)

        self.assertEqual(counts["projects"], 1)
        project = store.find_node(kind=NODE_PROJECT, stable_key=f"repo:{available.resolve()}")
        self.assertIsNotNone(project)
        self.assertEqual(project["title"], "Available Project")
        self.assertEqual(project["body"]["project_id"], "project-available")
        self.assertTrue(project["body"]["active"])
        self.assertEqual(project["body"]["availability"], "available")
        self.assertIsNone(
            store.find_node(kind=NODE_PROJECT, stable_key=f"repo:{unavailable.resolve()}")
        )

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

    def test_filters_workspace_root_project_records_from_program_summary(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        workspace = root / "dev"
        workspace.mkdir()
        relay_repo = _make_repo(workspace, "relay-runner")
        tools_repo = _make_repo(workspace, "tools")
        _write_ticket(relay_repo, "RR-1", "Fix board", "ready")
        _write_ticket(tools_repo, "TL-1", "Update helper", "backlog")

        registry_path = root / "projects.json"
        registry_path.write_text(
            json.dumps(
                {
                    "activeWorkspaceRootID": str(workspace.resolve()),
                    "workspaceRoots": [
                        {"id": str(workspace.resolve()), "rootPath": str(workspace.resolve())}
                    ],
                    "projects": [
                        {
                            "id": str(workspace.resolve()),
                            "repoPath": str(workspace.resolve()),
                            "displayName": "dev",
                            "providers": {"codex": {}, "claude": {}},
                        },
                        {
                            "id": str(relay_repo.resolve()),
                            "repoPath": str(relay_repo.resolve()),
                            "displayName": "Relay Runner",
                            "providers": {"codex": {}},
                        },
                        {
                            "id": str(tools_repo.resolve()),
                            "repoPath": str(tools_repo.resolve()),
                            "displayName": "Tools",
                            "providers": {"claude": {}},
                        },
                    ],
                }
            )
        )

        store = self.make_store()
        store.upsert_node(
            kind=NODE_PROJECT,
            stable_key=f"repo:{workspace.resolve()}",
            title="dev",
            body={"repo_path": str(workspace.resolve()), "providers": {"codex": {}}},
        )

        counts = ingest_registered_projects(store, registry_path=registry_path)
        summary = build_program_status(store, query="summary", limit=0, now=2000.0)

        self.assertEqual(counts["projects"], 2)
        self.assertIsNone(store.find_node(kind=NODE_PROJECT, stable_key=f"repo:{workspace.resolve()}"))
        self.assertEqual(summary["counts"]["projects"], 2)
        self.assertEqual(
            {item["project"]["path"] for item in summary["items"]},
            {str(relay_repo.resolve()), str(tools_repo.resolve())},
        )
        self.assertEqual(
            {
                item["project"]["path"]: item["providers"]
                for item in summary["items"]
            },
            {
                str(relay_repo.resolve()): ["Codex"],
                str(tools_repo.resolve()): ["Claude"],
            },
        )
        self.assertNotIn(f"- dev ({workspace.resolve()})", summary["message"])
        self.assertEqual(
            {item["project"]["path"] for item in build_program_status(store, query="ready_lane", limit=0)["items"]},
            {str(relay_repo.resolve())},
        )

    def test_deletes_stale_workspace_root_project_when_registry_only_tracks_root(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        workspace = root / "dev"
        workspace.mkdir()
        relay_repo = _make_repo(workspace, "relay-runner")
        tools_repo = _make_repo(workspace, "tools")

        registry_path = root / "projects.json"
        registry_path.write_text(
            json.dumps(
                {
                    "activeProjectID": None,
                    "activeWorkspaceRootID": str(workspace.resolve()),
                    "workspaceRoots": [
                        {"id": str(workspace.resolve()), "rootPath": str(workspace.resolve())}
                    ],
                    "projects": [
                        {
                            "id": str(relay_repo.resolve()),
                            "repoPath": str(relay_repo.resolve()),
                            "displayName": "Relay Runner",
                            "providers": {"codex": {}},
                        },
                        {
                            "id": str(tools_repo.resolve()),
                            "repoPath": str(tools_repo.resolve()),
                            "displayName": "Tools",
                            "providers": {"claude": {}},
                        },
                    ],
                }
            )
        )

        store = self.make_store()
        store.upsert_node(
            kind=NODE_PROJECT,
            stable_key=f"repo:{workspace.resolve()}",
            title="dev",
            body={"repo_path": str(workspace.resolve()), "providers": {"codex": {}}},
        )

        counts = ingest_registered_projects(store, registry_path=registry_path)
        summary = build_program_status(store, query="summary", limit=0, now=2000.0)

        self.assertEqual(counts["projects"], 2)
        self.assertIsNone(store.find_node(kind=NODE_PROJECT, stable_key=f"repo:{workspace.resolve()}"))
        self.assertEqual(
            {item["project"]["path"] for item in summary["items"]},
            {str(relay_repo.resolve()), str(tools_repo.resolve())},
        )
        self.assertNotIn(f"- dev ({workspace.resolve()})", summary["message"])

    def test_preserves_active_project_that_matches_historical_workspace_root(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        parent_repo = _make_repo(root, "platform")
        _make_repo(parent_repo, "client-dashboard")
        _write_ticket(parent_repo, "PL-1", "Ship platform board", "ready")

        registry_path = root / "projects.json"
        registry_path.write_text(
            json.dumps(
                {
                    "activeProjectID": str(parent_repo.resolve()),
                    "activeWorkspaceRootID": None,
                    "workspaceRoots": [
                        {"id": str(parent_repo.resolve()), "rootPath": str(parent_repo.resolve())}
                    ],
                    "projects": [
                        {
                            "id": str(parent_repo.resolve()),
                            "repoPath": str(parent_repo.resolve()),
                            "displayName": "Platform",
                            "providers": {"claude": {}},
                        }
                    ],
                }
            )
        )

        store = self.make_store()
        counts = ingest_registered_projects(store, registry_path=registry_path)
        summary = build_program_status(store, query="summary", limit=0, now=2000.0)

        self.assertEqual(counts["projects"], 1)
        self.assertEqual(summary["counts"]["projects"], 1)
        self.assertEqual(summary["items"][0]["project"]["path"], str(parent_repo.resolve()))
        self.assertEqual(summary["items"][0]["providers"], ["Claude"])

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

    def test_prunes_deleted_ticket_nodes_so_run_history_does_not_restore_board_cards(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        repo = _make_repo(root, "program-board")
        deleted_ticket_path = _write_ticket(repo, "PB-1", "Deleted active work", "ready", run_id=301)
        _write_ticket(repo, "PB-2", "Live backlog work", "backlog")

        registry_path = root / "projects.json"
        registry_path.write_text(
            json.dumps(
                {
                    "activeProjectID": str(repo.resolve()),
                    "projects": [
                        {
                            "id": str(repo.resolve()),
                            "repoPath": str(repo.resolve()),
                            "displayName": "Program Board",
                            "providers": {"codex": {}, "claude": {}},
                        }
                    ],
                }
            )
        )
        runs_db = root / "runs.db"
        _write_runs_db(
            runs_db,
            [_run_row(root, 301, "PB-1", repo, "Running", "codex")],
        )

        store = self.make_store()
        ingest_registered_projects(store, registry_path=registry_path, runs_db_path=runs_db)
        deleted_node = store.find_node(kind=NODE_TICKET, stable_key=f"repo:{repo.resolve()}:PB-1")
        self.assertIsNotNone(deleted_node)

        deleted_ticket_path.unlink()
        counts = ingest_registered_projects(store, registry_path=registry_path, runs_db_path=runs_db)

        self.assertEqual(counts["tickets"], 1)
        self.assertEqual(counts["tickets_deleted"], 1)
        self.assertIsNone(store.find_node(kind=NODE_TICKET, stable_key=f"repo:{repo.resolve()}:PB-1"))
        self.assertEqual(store.edges(kind=EDGE_EXECUTES, dst_id=deleted_node["id"]), [])
        self.assertEqual(
            [ticket["body"]["ticket_id"] for ticket in store.nodes(kind=NODE_TICKET)],
            ["PB-2"],
        )
        backlog = build_program_status(store, query="backlog_lane", limit=0, now=2000.0)
        in_progress = build_program_status(store, query="in_progress_lane", limit=0, now=2000.0)

        self.assertEqual([item["ticket_id"] for item in backlog["items"]], ["PB-2"])
        self.assertEqual(in_progress["items"], [])
        self.assertNotIn("PB-1", backlog["message"])
        self.assertNotIn("PB-1", in_progress["message"])

    def test_archived_catalog_keeps_hundreds_of_metadata_only_ticket_nodes(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        repo = _make_repo(root, "archive-history")
        _write_ticket(
            repo,
            "AH-live",
            "Live dependent",
            "backlog",
            depends_on=["AH-000"],
        )
        entries = []
        for index in range(200):
            ticket_id = f"AH-{index:03d}"
            entries.append({
                "schema_version": 1,
                "artifact_id": f"artifact-{ticket_id}",
                "ticket_id": ticket_id,
                "title": f"Archived {index}",
                "status": "done",
                "activity_at": f"2026-01-01T00:{index % 60:02d}:00Z",
                "dependencies": [],
                "state": "archived",
                "ticket_path": f".orchestrator/{ticket_id}.md",
                "attachments": [],
            })
        _install_confirmed_archive(repo, entries)
        registry_path = root / "projects.json"
        registry_path.write_text(json.dumps({
            "activeProjectID": str(repo.resolve()),
            "projects": [{
                "id": str(repo.resolve()),
                "repoPath": str(repo.resolve()),
                "displayName": "Archive history",
            }],
        }))

        store = self.make_store()
        counts = ingest_registered_projects(store, registry_path=registry_path)
        archived = store.find_node(
            kind=NODE_TICKET,
            stable_key=f"repo:{repo.resolve()}:AH-000",
        )
        live = store.find_node(
            kind=NODE_TICKET,
            stable_key=f"repo:{repo.resolve()}:AH-live",
        )

        self.assertEqual(counts["tickets"], 201)
        self.assertEqual(counts["archived_tickets"], 200)
        self.assertFalse(archived["body"]["materialized"])
        self.assertEqual(archived["body"]["history_state"], "archived")
        self.assertIsNotNone(
            store.get_edge(src_id=live["id"], dst_id=archived["id"], kind=EDGE_DEPENDS_ON)
        )
        second = ingest_registered_projects(store, registry_path=registry_path)
        self.assertEqual(second["tickets_deleted"], 0)
        self.assertIsNotNone(store.find_node(kind=NODE_TICKET, stable_key=archived["stable_key"]))

    def test_archive_catalog_rejects_invalid_activity_timestamp(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        repo = _make_repo(root, "invalid-archive-time")
        _install_confirmed_archive(repo, [{
            "schema_version": 1,
            "artifact_id": "artifact-TIME-1",
            "ticket_id": "TIME-1",
            "title": "Invalid activity",
            "status": "done",
            "activity_at": "2026-02-30T00:00:00Z",
            "state": "archived",
            "ticket_path": ".orchestrator/TIME-1.md",
            "attachments": [],
        }])
        registry_path = root / "projects.json"
        registry_path.write_text(json.dumps({
            "activeProjectID": str(repo.resolve()),
            "projects": [{
                "id": str(repo.resolve()),
                "repoPath": str(repo.resolve()),
            }],
        }))

        with self.assertRaisesRegex(ValueError, "invalid activity_at"):
            ingest_registered_projects(self.make_store(), registry_path=registry_path)

    def test_archive_catalog_rejects_fabricated_valid_shaped_git_identities(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        repo = _make_repo(root, "tampered-archive-identity")
        _install_confirmed_archive(repo, [{
            "schema_version": 1,
            "artifact_id": "artifact-TAMPER-1",
            "ticket_id": "TAMPER-1",
            "title": "Tampered identity",
            "status": "done",
            "activity_at": "2026-01-01T00:00:00Z",
            "state": "archived",
            "ticket_path": ".orchestrator/TAMPER-1.md",
            "attachments": [],
        }])
        _rewrite_confirmed_archive(repo, {
            "source_commit": "a" * 40,
            "ticket_blob": "b" * 40,
        })
        registry_path = root / "projects.json"
        registry_path.write_text(json.dumps({
            "activeProjectID": str(repo.resolve()),
            "projects": [{
                "id": str(repo.resolve()),
                "repoPath": str(repo.resolve()),
            }],
        }))

        with self.assertRaisesRegex(ValueError, "unreachable historical identity"):
            ingest_registered_projects(self.make_store(), registry_path=registry_path)

    def test_archive_catalog_rejects_status_tamper_against_canceled_markdown(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        repo = _make_repo(root, "tampered-archive-status")
        _install_confirmed_archive(repo, [{
            "schema_version": 1,
            "artifact_id": "artifact-TAMPER-2",
            "ticket_id": "TAMPER-2",
            "title": "Canceled history",
            "status": "canceled",
            "activity_at": "2026-01-01T00:00:00Z",
            "state": "archived",
            "ticket_path": ".orchestrator/TAMPER-2.md",
            "attachments": [],
            "_source_status": "backlog",
            "_source_canceled": True,
        }])
        _rewrite_confirmed_archive(repo, {"status": "done"})
        registry_path = root / "projects.json"
        registry_path.write_text(json.dumps({
            "activeProjectID": str(repo.resolve()),
            "projects": [{
                "id": str(repo.resolve()),
                "repoPath": str(repo.resolve()),
            }],
        }))

        with self.assertRaisesRegex(ValueError, "status and canceled semantics"):
            ingest_registered_projects(self.make_store(), registry_path=registry_path)

    def test_prunes_stale_run_nodes_missing_from_run_history(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: _remove_tree(root))
        repo = _make_repo(root, "program-board")
        _write_ticket(repo, "PB-1", "Active work", "ready", run_id=290)

        registry_path = root / "projects.json"
        registry_path.write_text(
            json.dumps(
                {
                    "activeProjectID": str(repo.resolve()),
                    "projects": [
                        {
                            "id": str(repo.resolve()),
                            "repoPath": str(repo.resolve()),
                            "displayName": "Program Board",
                            "providers": {"codex": {}, "claude": {}},
                        }
                    ],
                }
            )
        )
        runs_db = root / "runs.db"
        _write_runs_db(
            runs_db,
            [_run_row(root, 290, "PB-1", repo, "Running", "codex")],
        )

        store = self.make_store()
        ingest_registered_projects(store, registry_path=registry_path, runs_db_path=runs_db)
        self.assertIsNotNone(store.find_node(kind=NODE_RUN, stable_key="run:290"))
        in_progress = build_program_status(store, query="in_progress_lane", limit=0, now=2000.0)
        self.assertEqual([item["ticket_id"] for item in in_progress["items"]], ["PB-1"])

        runs_db.unlink()
        _write_runs_db(runs_db, [])
        counts = ingest_registered_projects(store, registry_path=registry_path, runs_db_path=runs_db)

        self.assertEqual(counts["runs_deleted"], 1)
        self.assertIsNone(store.find_node(kind=NODE_RUN, stable_key="run:290"))
        self.assertEqual(store.edges(kind=EDGE_EXECUTES), [])
        active = build_program_status(store, query="active_work", limit=0, now=2000.0)
        in_progress = build_program_status(store, query="in_progress_lane", limit=0, now=2000.0)
        ready = build_program_status(store, query="ready_lane", limit=0, now=2000.0)

        self.assertEqual(active["items"], [])
        self.assertEqual(in_progress["items"], [])
        self.assertEqual([item["ticket_id"] for item in ready["items"]], ["PB-1"])

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


def _install_confirmed_archive(repo: Path, entries: list[dict]) -> None:
    _git(repo, "init", "--initial-branch=main", "--quiet")
    _git(repo, "config", "user.name", "Graphify Tests")
    _git(repo, "config", "user.email", "graphify@example.invalid")
    (repo / ".orchestrator" / "config.toml").write_text(
        'project_id = "graphify-test"\nartifact_ref = "refs/heads/relay/artifacts"\n',
        encoding="utf-8",
    )
    _git(repo, "add", ".orchestrator")
    _git(repo, "commit", "--quiet", "--allow-empty", "-m", "materialized board")
    _git(repo, "switch", "--quiet", "-c", "relay/artifacts")
    archived_paths = []
    for entry in entries:
        ticket_path = repo / str(entry["ticket_path"])
        source_status = entry.get("_source_status", entry["status"])
        source_canceled = str(entry.get("_source_canceled", False)).lower()
        ticket_path.write_text(
            f"""---
id: {entry['ticket_id']}
artifact_id: {entry['artifact_id']}
title: {entry['title']}
status: {source_status}
activity_at: {entry['activity_at']}
execution_mode: implementation
depends_on: []
run_id: null
canceled: {source_canceled}
---

## Description

Archived Graphify fixture.
""",
            encoding="utf-8",
        )
        archived_paths.append(ticket_path)
    _git(repo, "add", ".orchestrator")
    _git(repo, "commit", "--quiet", "-m", "archive source tickets")
    source_commit = _git(repo, "rev-parse", "HEAD")
    tree_entries = {}
    for line in _git(repo, "ls-tree", "-r", source_commit).splitlines():
        metadata, _, path = line.partition("\t")
        tree_entries[path] = metadata.split()[2]
    catalog = []
    for entry in entries:
        completed = {key: value for key, value in entry.items() if not key.startswith("_")}
        completed["source_commit"] = source_commit
        completed["ticket_blob"] = tree_entries[str(entry["ticket_path"])]
        catalog.append(completed)
    for ticket_path in archived_paths:
        ticket_path.unlink()
    (repo / ".orchestrator" / "archive-index.jsonl").write_text(
        "".join(json.dumps(entry, sort_keys=True) + "\n" for entry in catalog),
        encoding="utf-8",
    )
    _git(repo, "add", "-A", ".orchestrator")
    _git(repo, "commit", "--quiet", "-m", "confirm archive catalog")
    _git(repo, "switch", "--quiet", "main")


def _rewrite_confirmed_archive(repo: Path, updates: dict[str, str]) -> None:
    _git(repo, "switch", "--quiet", "relay/artifacts")
    path = repo / ".orchestrator" / "archive-index.jsonl"
    entries = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    entries[0].update(updates)
    path.write_text(
        "".join(json.dumps(entry, sort_keys=True) + "\n" for entry in entries),
        encoding="utf-8",
    )
    _git(repo, "add", ".orchestrator/archive-index.jsonl")
    _git(repo, "commit", "--quiet", "-m", "tamper archive catalog")
    _git(repo, "switch", "--quiet", "main")


def _git(repo: Path, *arguments: str) -> str:
    process = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        capture_output=True,
        text=True,
        check=False,
    )
    if process.returncode != 0:
        raise AssertionError(process.stderr or process.stdout)
    return process.stdout.strip()


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
