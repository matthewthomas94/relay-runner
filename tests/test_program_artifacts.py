from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from services.artifact_store import (
    ARTIFACT_REF,
    ArtifactEventCollision,
    ArtifactMutation,
    ArtifactStore,
    ArtifactValidationError,
    TicketWrite,
)

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
if SERVICES not in sys.path:
    sys.path.insert(0, SERVICES)

from graphify_core import (  # noqa: E402
    NODE_DECISION,
    NODE_IDEA,
    NODE_PROGRAM_EVENT,
    NODE_RISK,
    NODE_STATUS,
    GraphifyCoreStore,
)
from graphify_ingest import ingest_registered_projects  # noqa: E402
from program_artifacts import (  # noqa: E402
    ProgramArtifactMigrationError,
    export_graphify_project_captures,
    graph_capture_manifest,
    replace_graphify_with_clean_rebuild,
)
from session_capture import capture_session_review  # noqa: E402


class ProgramArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-program-artifacts-")
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.state = self.root / "state"
        self.repo.mkdir()
        self.git("init", "--initial-branch=main", "--quiet")
        (self.repo / "source.txt").write_text("source\n", encoding="utf-8")
        self.git("add", "source.txt")
        self.git(
            "-c", "user.name=Relay Tests",
            "-c", "user.email=relay-tests@example.invalid",
            "commit", "-q", "-m", "source root",
        )
        self.artifacts = ArtifactStore(
            self.repo,
            "project-001",
            self.state,
            enabled=True,
        )
        base = self.artifacts.initialize(device_id="device-001").commit_id
        self.artifacts.mutate(
            ArtifactMutation(
                event_id="seed-ticket",
                actor_type="pm",
                device_id="device-001",
                operations=(
                    TicketWrite(
                        "RR-1",
                        "artifact-0001",
                        b"""---
id: RR-1
title: Program ownership
status: done
priority: high
depends_on: []
run_id: null
canceled: false
---

## Description

Move project records into artifacts.
""",
                    ),
                ),
                expected_base=base,
                summary="Seed ticket",
            )
        )
        self.registry = self.root / "projects.json"
        self.registry.write_text(
            json.dumps(
                {
                    "activeProjectID": str(self.repo.resolve()),
                    "projects": [
                        {
                            "id": str(self.repo.resolve()),
                            "repoPath": str(self.repo.resolve()),
                            "displayName": "Program Fixture",
                            "providers": {"codex": {}, "claude": {}},
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        self.graph_path = self.state / "graphify.db"
        self.graph = GraphifyCoreStore(self.graph_path)
        ingest_registered_projects(
            self.graph,
            registry_path=self.registry,
            index_files=False,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", *args],
            cwd=self.repo,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout.strip()

    def seed_all_capture_kinds(self, capture_id: str = "legacy-capture") -> None:
        capture_session_review(
            self.graph,
            repo_path=self.repo,
            ticket_id="RR-1",
            provider="codex",
            capture_id=capture_id,
            occurred_at=1000.0,
            context="private caller context must not become durable",
            entries=[
                {"kind": "shipped", "title": "Shipped ownership"},
                {"kind": "decision", "title": "Use artifact events"},
                {"kind": "risk", "title": "Migration ambiguity"},
                {"kind": "idea", "title": "Rebuild indexes"},
                {"kind": "status", "status": "verified"},
            ],
        )

    def test_exports_every_capture_kind_idempotently_and_clean_rebuild_is_lossless(self):
        self.seed_all_capture_kinds()

        first = export_graphify_project_captures(
            self.graph,
            self.artifacts,
            state_root=self.state,
            device_id="device-001",
            provider="codex",
        )
        second = export_graphify_project_captures(
            self.graph,
            self.artifacts,
            state_root=self.state,
            device_id="device-001",
            provider="claude",
        )

        self.assertEqual(first["status"], "verified")
        self.assertEqual(first["records"], 5)
        self.assertTrue(second["idempotent"])
        self.assertEqual(first["artifact_commit"], second["artifact_commit"])
        self.assertTrue(Path(first["backup_path"]).exists())
        event_paths = [
            path
            for path in self.git("ls-tree", "-r", "--name-only", ARTIFACT_REF).splitlines()
            if "/program/events/" in path
        ]
        self.assertEqual(len(event_paths), 5)
        durable_text = "\n".join((self.repo / path).read_text() for path in event_paths)
        self.assertNotIn("private caller context", durable_text)
        self.assertNotIn("raw_entry", durable_text)

        tampered_path = self.repo / event_paths[0]
        tampered_path.write_text('{"summary":"tampered projection"}\n', encoding="utf-8")

        clean_path = self.state / "clean.db"
        clean = GraphifyCoreStore(clean_path)
        counts = ingest_registered_projects(
            clean,
            registry_path=self.registry,
            index_files=False,
        )
        expected = graph_capture_manifest(clean)
        self.assertEqual(counts["program_events"], 5)
        self.assertEqual(len(expected), 5)
        self.assertNotIn(
            "tampered projection",
            json.dumps([node["body"] for node in clean.nodes()]),
        )

        rebuild = replace_graphify_with_clean_rebuild(
            graphify_path=self.graph_path,
            registry_path=self.registry,
            runs_db_path=None,
            expected_capture_manifest=expected,
            backup_path=self.state / "graphify-before-clean-rebuild.db",
        )
        reopened = GraphifyCoreStore(self.graph_path)
        self.assertEqual(rebuild["capture_manifest"], expected)
        self.assertEqual(graph_capture_manifest(reopened), expected)
        self.assertEqual(
            {node["kind"] for node in reopened.nodes() if node["kind"] in {
                NODE_PROGRAM_EVENT, NODE_DECISION, NODE_RISK, NODE_IDEA, NODE_STATUS
            }},
            {NODE_PROGRAM_EVENT, NODE_DECISION, NODE_RISK, NODE_IDEA, NODE_STATUS},
        )

    def test_interrupted_export_resumes_without_duplicate_commit(self):
        self.seed_all_capture_kinds("interrupted")

        with self.assertRaisesRegex(RuntimeError, "injected"):
            export_graphify_project_captures(
                self.graph,
                self.artifacts,
                state_root=self.state,
                device_id="device-001",
                failure_injector=lambda stage: (_ for _ in ()).throw(RuntimeError("injected"))
                if stage == "after_artifact_commit" else None,
            )
        committed_head = self.git("rev-parse", ARTIFACT_REF)

        result = export_graphify_project_captures(
            self.graph,
            self.artifacts,
            state_root=self.state,
            device_id="device-001",
        )

        self.assertTrue(result["idempotent"])
        self.assertEqual(self.git("rev-parse", ARTIFACT_REF), committed_head)
        journal = json.loads(Path(result["journal_path"]).read_text())
        self.assertEqual(journal["stage"], "verified")
        self.assertEqual(journal["manifest_sha256"], journal["post_manifest_sha256"])

    def test_ambiguous_records_write_review_report_and_do_not_commit(self):
        self.seed_all_capture_kinds("valid")
        project = self.graph.find_node(
            kind="Project",
            stable_key=f"repo:{self.repo.resolve()}",
        )
        self.graph.upsert_node(
            kind=NODE_DECISION,
            stable_key="capture:orphan:0",
            title="Orphan",
            body={"capture_id": "orphan", "entry_index": 0},
        )
        self.graph.upsert_node(
            kind=NODE_RISK,
            stable_key="capture:valid:0-duplicate",
            project_id=project["id"],
            title="Duplicate",
            body={
                "capture_id": "valid",
                "entry_index": 0,
                "capture_source": "session_capture",
                "occurred_at": 1000.0,
                "evidence": {"repo_path": str(self.repo.resolve())},
            },
        )
        self.graph.upsert_node(
            kind=NODE_IDEA,
            stable_key="capture:cross-project:0",
            project_id="foreign-graph-project",
            title="Cross project",
            body={
                "capture_id": "cross-project",
                "entry_index": 0,
                "capture_source": "session_capture",
                "occurred_at": 1000.0,
                "evidence": {"repo_path": str(self.repo.resolve())},
            },
        )
        self.graph.upsert_node(
            kind=NODE_STATUS,
            stable_key="capture:malformed:0",
            project_id=project["id"],
            title="Malformed",
            body={
                "capture_id": "malformed",
                "entry_index": 0,
                "evidence": {"repo_path": str(self.repo.resolve())},
            },
        )
        before = self.git("rev-parse", ARTIFACT_REF)

        with self.assertRaises(ProgramArtifactMigrationError) as raised:
            export_graphify_project_captures(
                self.graph,
                self.artifacts,
                state_root=self.state,
                device_id="device-001",
            )

        self.assertEqual(self.git("rev-parse", ARTIFACT_REF), before)
        issue_kinds = {issue["kind"] for issue in raised.exception.report["issues"]}
        self.assertTrue(
            {"orphaned_capture", "duplicate_capture", "cross_project_capture", "malformed_capture"}
            <= issue_kinds
        )
        report_path = self.state / "artifacts/project-001/program-migration/report.json"
        self.assertEqual(json.loads(report_path.read_text())["status"], "review_required")

    def test_artifact_first_capture_excludes_private_context_rejects_secrets_and_is_provider_neutral(self):
        codex = capture_session_review(
            self.graph,
            repo_path=self.repo,
            ticket_id="RR-1",
            provider="codex",
            capture_id="codex-capture",
            occurred_at=1000.0,
            context="sensitive transcript stays local",
            entries=[
                {
                    "kind": "decision",
                    "title": "Use one durable schema",
                    "raw_transcript": "private speech is excluded",
                }
            ],
            artifact_store=self.artifacts,
            artifact_device_id="device-001",
        )
        claude = capture_session_review(
            self.graph,
            repo_path=self.repo,
            ticket_id="RR-1",
            provider="claude",
            capture_id="claude-capture",
            occurred_at=1001.0,
            entries=[{"kind": "decision", "title": "Use one durable schema"}],
            artifact_store=self.artifacts,
            artifact_device_id="device-001",
        )
        files = self.artifacts.snapshot().files
        codex_doc = json.loads(files[f".orchestrator/program/events/{codex['artifact_event_ids'][0]}.json"])
        claude_doc = json.loads(files[f".orchestrator/program/events/{claude['artifact_event_ids'][0]}.json"])
        self.assertEqual(set(codex_doc), set(claude_doc))
        self.assertEqual(codex_doc["provider"], "codex")
        self.assertEqual(claude_doc["provider"], "claude")
        self.assertNotIn("sensitive transcript", json.dumps(codex_doc))
        self.assertNotIn("private speech", json.dumps(codex_doc))

        with self.assertRaises(ArtifactValidationError):
            capture_session_review(
                self.graph,
                repo_path=self.repo,
                provider="codex",
                capture_id="secret-capture",
                entries=[{"kind": "note", "title": "api_key = sk-abcdefghijklmnopqrstuvwxyz"}],
                artifact_store=self.artifacts,
                artifact_device_id="device-001",
            )
        self.assertIsNone(
            self.graph.find_node(kind=NODE_PROGRAM_EVENT, stable_key="capture:secret-capture:0")
        )

        with self.assertRaises(ArtifactEventCollision):
            capture_session_review(
                self.graph,
                repo_path=self.repo,
                provider="codex",
                capture_id="codex-capture",
                occurred_at=1000.0,
                entries=[{"kind": "decision", "title": "Changed immutable content"}],
                artifact_store=self.artifacts,
                artifact_device_id="device-001",
            )


if __name__ == "__main__":
    unittest.main()
