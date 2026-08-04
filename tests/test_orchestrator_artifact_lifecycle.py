from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ROOT / "services"
sys.path.insert(0, str(SERVICES))

import orchestrator  # noqa: E402
from services.artifact_rollout import (  # noqa: E402
    PROJECT_OPT_IN,
    ArtifactRolloutBlocked,
)
from services.artifact_store import (  # noqa: E402
    ArtifactMutation,
    ArtifactStore,
    ConfigWrite,
    TicketWrite,
)
from orchestrator import Daemon, Worker  # noqa: E402


UTC = timezone.utc


class OrchestratorArtifactLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-daemon-artifact-")
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "--initial-branch=main", "--quiet")
        self.git("config", "user.name", "Lifecycle Tests")
        self.git("config", "user.email", "lifecycle@example.invalid")
        (self.repo / "source.txt").write_text("base\n", encoding="utf-8")
        self.git("add", "source.txt")
        self.git("commit", "--quiet", "-m", "source base")

        self.state = self.root / "state"
        self.store = ArtifactStore(
            self.repo,
            "daemon-project",
            self.state,
            enabled=True,
        )
        self.store.initialize(device_id="test-device")
        snapshot = self.store.snapshot()
        config = snapshot.files[".orchestrator/config.toml"].decode("utf-8")
        config = config.replace(
            'artifact_lifecycle = "legacy"',
            'artifact_lifecycle = "enabled"',
        )
        self.store.mutate(ArtifactMutation(
            event_id="enable-daemon-lifecycle",
            actor_type="user",
            device_id="test-device",
            expected_base=snapshot.commit_id,
            operations=(ConfigWrite(config.encode("utf-8")),),
        ))
        self.write_ticket("RR-1")

        self.registry_updated = "2026-08-04T05:00:00Z"
        registry = self.state / "projects" / "registry-v2.json"
        registry.parent.mkdir(parents=True, exist_ok=True)
        registry.write_text(json.dumps({
            "schema_version": 2,
            "active_project_id": "daemon-project",
            "projects": [{
                "project_id": "daemon-project",
                "display_name": "Daemon project",
                "selected_path": str(self.repo),
                "last_resolved_path": str(self.repo),
                "git_common_directory_fingerprint": "daemon-fingerprint",
                "availability": "available",
                "updated_at": self.registry_updated,
            }],
        }), encoding="utf-8")

        config = {
            "orchestrator": {
                "workspace_root": str(self.root / "workspaces"),
                "branch_prefix": "relay/",
                "default_workflow_path": str(SERVICES / "orchestrator_workflow.md"),
                "agent": "codex",
                "command": "/usr/bin/true",
                "max_concurrent_workers": 0,
            },
            "general": {},
        }
        with (
            patch.object(orchestrator, "_data_root", return_value=self.state),
            patch.object(
                orchestrator,
                "_program_registry_path",
                return_value=self.state / "program" / "projects.json",
            ),
        ):
            self.daemon = Daemon(config)
        self.daemon.config_loader = lambda: config

    def tearDown(self):
        for worker in list(self.daemon._workers.values()):
            worker.cancel()
        self.temporary.cleanup()

    def test_confirmed_dispatch_structured_outcome_and_reviewed_merge_publish_artifact_truth(self):
        with self.assertRaisesRegex(Exception, "confirmed project scope token"):
            self.daemon.dispatch(ticket_id="RR-1", repo_path=str(self.repo))

        with patch.object(Worker, "start", autospec=True):
            dispatched = self.daemon.dispatch(
                ticket_id="RR-1",
                repo_path=str(self.repo),
                project_scope_token=self.scope_token(),
            )

        run = dispatched["run"]
        run_id = int(run["id"])
        workspace = Path(run["workspace_path"])
        self.assertTrue((workspace / ".orchestrator/RR-1.md").is_file())
        self.assertEqual(
            self.git("-C", str(workspace), "ls-files", "--", ".orchestrator"),
            "",
        )
        lifecycle = self.daemon._artifact_lifecycle(str(self.repo))
        self.assertIsNotNone(lifecycle)
        self.assertEqual(
            [lease.lease_id for lease in lifecycle.leases.active()],
            [f"run:{run_id}:worker"],
        )

        (workspace / "source.txt").write_text("implemented\n", encoding="utf-8")
        self.git("-C", str(workspace), "add", "source.txt")
        self.git("-C", str(workspace), "commit", "--quiet", "-m", "implement source")
        source_commit = self.git("-C", str(workspace), "rev-parse", "HEAD")
        accepted = self.daemon.submit_worker_outcome(run_id, {
            "status": "completed",
            "summary": "Implemented the daemon lifecycle fixture.",
            "changed_paths": ["source.txt"],
            "verification": ["focused lifecycle test passed"],
            "source_commit": source_commit,
        })
        self.assertTrue(accepted["accepted"])

        manifest = json.loads(
            (workspace / ".orchestrator/.artifact-snapshot.json").read_text(encoding="utf-8")
        )
        outcome, reason = lifecycle.validate_worker_completion(
            workspace_path=workspace,
            ticket_id="RR-1",
            run_id=run_id,
            provider="codex",
            start_head=manifest["source_start_head"],
        )
        self.assertEqual(outcome, "completed")
        self.assertIn("accepted", reason)
        self.daemon.runs.update(run_id, state="AwaitingReview")
        lifecycle.begin_review(run_id=run_id, provider="claude")
        with self.daemon._workers_lock:
            self.daemon._workers.pop(run_id, None)

        merged = self.daemon.accept_worker_run(run_id)

        self.assertTrue(merged["accepted"])
        self.assertEqual(merged["run"]["state"], "Merged")
        self.assertEqual(lifecycle.leases.active(), ())
        canonical = self.store.snapshot().files[".orchestrator/RR-1.md"].decode("utf-8")
        self.assertIn("status: done", canonical)
        self.assertIn("reviewed source merge", canonical)
        self.assertEqual(self.git("show", "--pretty=", "--name-only", source_commit), "source.txt")
        self.assertNotIn(
            ".orchestrator",
            self.git("ls-tree", "-r", "--name-only", "HEAD"),
        )

    def test_session_capture_requires_same_confirmed_scope_and_publishes_artifact_first(self):
        with self.assertRaisesRegex(Exception, "confirmed project scope token"):
            self.daemon.session_capture(
                repo_path=str(self.repo),
                capture_id="scope-capture",
                provider="codex",
                entries=[{"kind": "decision", "title": "Use confirmed scope"}],
            )

        result = self.daemon.session_capture(
            repo_path=str(self.repo),
            capture_id="scope-capture",
            provider="claude",
            entries=[{"kind": "decision", "title": "Use confirmed scope"}],
            project_scope_token=self.scope_token(),
        )

        self.assertEqual(result["durable_authority"], "relay/artifacts")
        self.assertEqual(result["provider"], "claude")
        event_id = result["artifact_event_ids"][0]
        document = json.loads(
            self.store.snapshot().files[
                f".orchestrator/program/events/{event_id}.json"
            ]
        )
        self.assertEqual(document["project_id"], "daemon-project")
        self.assertEqual(document["provider"], "claude")
        self.assertEqual(document["record_kind"], "decision")
        self.assertEqual(result["counts"], {"Decision": 1})

    def test_rollout_diagnostics_are_bounded_default_off_and_surface_recovery_code(self):
        status = self.daemon.artifact_rollout_status()
        self.assertEqual(status["status"], "available")
        rollout = status["rollout"]
        self.assertEqual(rollout["project_opt_in_count"], 0)
        self.assertFalse(rollout["cohorts"]["new_project_default"]["enabled"])
        self.assertFalse(rollout["cohorts"]["legacy_migration_offer"]["enabled"])
        self.assertNotIn(str(self.repo), json.dumps(status, sort_keys=True))

        rollout_store = self.daemon.artifact_rollout
        rollout_store.rollout_root.mkdir(parents=True, exist_ok=True)
        rollout_store.path.write_text("{broken", encoding="utf-8")
        rollout_store.backup_path.write_text("{also-broken", encoding="utf-8")
        blocked = self.daemon.artifact_rollout_status()
        self.assertEqual(blocked["status"], "verification_blocked")
        self.assertEqual(blocked["error_code"], "rollout_state_corrupt")
        self.assertIn("restore", blocked["recovery"].lower())

    def test_rollout_kill_switch_blocks_cached_configured_writer_without_legacy_fallback(self):
        lifecycle = self.daemon._artifact_lifecycle(str(self.repo))
        self.assertIsNotNone(lifecycle)
        initial = self.daemon.artifact_rollout.decision(
            "daemon-project",
            project_kind="existing",
            configured_opt_in=True,
        )
        self.assertEqual(initial.reason_code, "configured_project_opt_in")
        head_before = self.store._head()

        self.daemon.artifact_rollout.pause_cohort(
            PROJECT_OPT_IN,
            writers_drained=True,
            sync_frozen=True,
            reason_code="verified_writer_failure",
        )
        paused = self.daemon.artifact_rollout.decision(
            "daemon-project",
            project_kind="existing",
            configured_opt_in=True,
        )
        self.assertFalse(paused.artifact_writes_enabled)
        self.assertFalse(paused.artifact_sync_enabled)
        with self.assertRaises(ArtifactRolloutBlocked) as blocked:
            self.daemon.artifact_board_claim_next_id(
                repo_path=str(self.repo),
                project_scope_token=self.scope_token(),
                request_id="paused-board-claim",
            )
        self.assertEqual(blocked.exception.code, "project_opt_in_kill_switch")
        self.assertEqual(self.store._head(), head_before)

        handler = object.__new__(orchestrator.Handler)
        handler.daemon = self.daemon
        with patch.object(orchestrator, "_read_body", return_value={
            "repo_path": str(self.repo),
            "project_scope_token": self.scope_token(),
            "request_id": "paused-http-board-claim",
        }):
            status, payload = handler._route(
                "POST",
                "/v1/artifacts/tickets/claim-next-id",
            )
        self.assertEqual(status, 409)
        self.assertEqual(payload["error_code"], "project_opt_in_kill_switch")
        self.assertIn("drained", payload["recovery"])
        self.assertEqual(self.store._head(), head_before)

        self.daemon.artifact_rollout.resume_cohort(PROJECT_OPT_IN, confirmed=True)
        self.assertIs(self.daemon._artifact_lifecycle(str(self.repo)), lifecycle)

    def test_board_authoring_uses_confirmed_typed_artifact_writer_for_id_ticket_attachment_and_delete(self):
        with self.assertRaisesRegex(Exception, "confirmed project scope token"):
            self.daemon.artifact_board_claim_next_id(
                repo_path=str(self.repo),
                project_scope_token=None,
            )

        claim = self.daemon.artifact_board_claim_next_id(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            request_id="board-claim-test",
        )
        self.assertEqual(claim["ticket_id"], "REP-1")
        markdown = b"""---
id: REP-1
title: Board artifact writer
status: backlog
priority: medium
execution_mode: implementation
depends_on: []
run_id: null
canceled: false
order: 20
---

## Description

Saved through the daemon-owned typed writer.
"""
        saved = self.daemon.artifact_board_write_ticket(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            ticket_id="REP-1",
            markdown_base64=base64.b64encode(markdown).decode("ascii"),
            request_id="board-save-test",
        )
        stored = base64.b64decode(saved["markdown_base64"])
        self.assertIn(b"artifact_id: ticket-", stored)
        self.assertIn(b"user_edited_at:", stored)
        self.assertEqual(
            stored,
            self.store.snapshot().files[".orchestrator/REP-1.md"],
        )

        png = b"\x89PNG\r\n\x1a\nboard-proof"
        self.daemon.artifact_board_write_attachment(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            ticket_id="REP-1",
            filename="proof.png",
            mime_type="image/png",
            content_base64=base64.b64encode(png).decode("ascii"),
            request_id="board-attachment-test",
        )
        self.assertEqual(
            self.store.snapshot().files[".orchestrator/attachments/REP-1/proof.png"],
            png,
        )

        deleted = self.daemon.artifact_board_delete_ticket(
            repo_path=str(self.repo),
            project_scope_token=self.scope_token(),
            ticket_id="REP-1",
            request_id="board-delete-test",
        )
        self.assertFalse(deleted["idempotent"])
        snapshot = self.store.snapshot()
        self.assertNotIn(".orchestrator/REP-1.md", snapshot.files)
        self.assertNotIn(".orchestrator/attachments/REP-1/proof.png", snapshot.files)

    def scope_token(self) -> str:
        payload = {
            "version": 1,
            "registrySchemaVersion": 2,
            "projectID": "daemon-project",
            "repositoryPath": str(self.repo.resolve()),
            "gitCommonDirectoryFingerprint": "daemon-fingerprint",
            "registryRecordUpdatedAt": datetime.fromisoformat(
                self.registry_updated.replace("Z", "+00:00")
            ).timestamp(),
            "issuedAt": datetime(2026, 8, 4, tzinfo=UTC).timestamp(),
        }
        return base64.b64encode(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")

    def write_ticket(self, ticket_id: str) -> None:
        markdown = f"""---
id: {ticket_id}
artifact_id: artifact-{ticket_id}
title: Daemon lifecycle
status: ready
priority: high
execution_mode: implementation
activity_at: 2026-08-04T00:00:00.000000Z
depends_on: []
run_id: null
canceled: false
worker_model: strong
worker_effort: high
worker_sizing_rationale: daemon fixture
worker_provider_notes: provider-neutral fixture
---

## Description

Exercise the artifact lifecycle through the daemon.
""".encode("utf-8")
        self.store.mutate(ArtifactMutation(
            event_id=f"write-{ticket_id}",
            actor_type="pm",
            device_id="test-device",
            expected_base=self.store._head(),
            operations=(TicketWrite(ticket_id, f"artifact-{ticket_id}", markdown),),
        ))

    def git(self, *arguments: str) -> str:
        command = ["git"]
        if not arguments or arguments[0] != "-C":
            command.extend(["-C", str(self.repo)])
        command.extend(arguments)
        process = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(
            process.returncode,
            0,
            msg=f"{' '.join(command)} failed: {process.stderr}",
        )
        return process.stdout.strip()


if __name__ == "__main__":
    unittest.main()
