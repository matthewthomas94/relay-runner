import base64
import hashlib
import json
import os
import stat
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from services.artifact_lifecycle import (
    ArtifactLifecycleCoordinator,
    WorkerOutcomeStatus,
)
from services.artifact_store import (
    ArtifactMutation,
    ArtifactStore,
    AttachmentWrite,
    ConfigWrite,
    TicketWrite,
)


UTC = timezone.utc
PNG = b"\x89PNG\r\n\x1a\nworker-proof"


class ArtifactLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-lifecycle-tests-")
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git(self.repo, "init", "--initial-branch=main", "--quiet")
        (self.repo / "source.txt").write_text("base\n")
        self.commit(self.repo, "source base")
        self.state = self.root / "state"
        self.store = ArtifactStore(
            self.repo,
            "lifecycle-project",
            self.state,
            enabled=True,
        )
        self.store.initialize(device_id="daemon-device")
        self.enable_lifecycle()
        self.now = datetime(2026, 8, 4, 5, 6, 7, 123456, tzinfo=UTC)
        self.registry = self.state / "projects/registry-v2.json"
        self.registry.parent.mkdir(parents=True)
        self.registry_updated = "2026-08-04T05:00:00Z"
        self.registry.write_text(json.dumps({
            "schema_version": 2,
            "active_project_id": "lifecycle-project",
            "projects": [{
                "project_id": "lifecycle-project",
                "display_name": "Lifecycle",
                "selected_path": str(self.repo),
                "last_resolved_path": str(self.repo),
                "git_common_directory_fingerprint": "fingerprint-a",
                "availability": "available",
                "updated_at": self.registry_updated,
            }],
        }))
        self.coordinator = ArtifactLifecycleCoordinator(
            self.store,
            registry_path=self.registry,
            device_id="daemon-device",
            now=lambda: self.now,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_scope_requires_current_registered_project_identity(self):
        token = self.scope_token()

        validated = self.coordinator.validate_scope(token)

        self.assertEqual(validated.project_id, "lifecycle-project")
        self.assertEqual(validated.repository_path, str(self.store.repo_path))
        with self.assertRaisesRegex(Exception, "requires a confirmed"):
            self.coordinator.validate_scope(None)
        stale = self.scope_token(fingerprint="stale")
        with self.assertRaisesRegex(Exception, "stale gitCommonDirectoryFingerprint"):
            self.coordinator.validate_scope(stale)
        internal = self.coordinator.validate_scope(
            None, internally_confirmed_project_id="lifecycle-project"
        )
        self.assertEqual(internal.project_id, "lifecycle-project")

    def test_scope_accepts_registered_path_alias_resolving_to_same_repository(self):
        alias = self.root / "repository-alias"
        alias.symlink_to(self.repo, target_is_directory=True)

        validated = self.coordinator.validate_scope(
            self.scope_token(repository_path=str(alias))
        )

        self.assertEqual(validated.repository_path, str(self.store.repo_path))

    def test_claim_materializes_only_immutable_ticket_dependencies_and_owned_attachments(self):
        self.write_ticket("RR-1", "Done dependency", status="done")
        self.write_ticket("RR-2", "Assigned", depends_on=("RR-1",))
        self.write_ticket("RR-3", "Unrelated")
        self.write_attachment("RR-2", "proof.png", PNG)
        worktree = self.create_worktree("run-1")

        snapshot = self.coordinator.claim_and_materialize(
            ticket_id="RR-2",
            run_id=1,
            provider="codex",
            workspace_path=worktree,
        )

        self.assertEqual(snapshot.artifact_head, self.store._head())
        self.assertEqual(snapshot.lease_id, "run:1:worker")
        self.assertIn(".orchestrator/RR-2.md", snapshot.files)
        self.assertIn(".orchestrator/attachments/RR-2/proof.png", snapshot.files)
        self.assertIn(".orchestrator/dependencies/RR-1.json", snapshot.files)
        self.assertNotIn(".orchestrator/RR-1.md", snapshot.files)
        self.assertNotIn(".orchestrator/RR-3.md", snapshot.files)
        ticket = (worktree / ".orchestrator/RR-2.md").read_text()
        self.assertIn("status: in_progress", ticket)
        self.assertIn("run_id: 1", ticket)
        dependency = json.loads(
            (worktree / ".orchestrator/dependencies/RR-1.json").read_text()
        )
        self.assertEqual(dependency["status"], "done")
        self.assertFalse(dependency["archived"])
        mode = (worktree / ".orchestrator/RR-2.md").stat().st_mode
        self.assertFalse(mode & stat.S_IWUSR)
        self.assertEqual(self.git(worktree, "ls-files", "--", ".orchestrator"), "")
        self.assertEqual(
            self.coordinator.leases.active_ticket_ids(), frozenset({"RR-2"})
        )
        canonical = self.store.snapshot().files[".orchestrator/RR-2.md"].decode()
        self.assertIn("run_state: claimed", canonical)

    def test_completed_worker_source_only_outcome_review_merge_and_dependency_are_atomic(self):
        self.write_ticket("RR-1", "Work")
        self.write_ticket("RR-2", "Dependent", status="backlog", depends_on=("RR-1",))
        self.write_ticket(
            "RR-3",
            "Canceled dependent",
            status="backlog",
            depends_on=("RR-1",),
            canceled=True,
        )
        self.write_ticket(
            "RR-4",
            "Draft dependent",
            status="backlog",
            depends_on=("RR-1",),
            draft=True,
        )
        excluded_before = {
            ticket_id: self.store.snapshot().files[f".orchestrator/{ticket_id}.md"]
            for ticket_id in ("RR-3", "RR-4")
        }
        worktree = self.create_worktree("run-2")
        snapshot = self.coordinator.claim_and_materialize(
            ticket_id="RR-1", run_id=2, provider="claude", workspace_path=worktree
        )
        start_head = self.git(worktree, "rev-parse", "HEAD")
        (worktree / "source.txt").write_text("implemented\n")
        self.commit(worktree, "feat: implementation")
        source_commit = self.git(worktree, "rev-parse", "HEAD")
        outcome = self.coordinator.submit_outcome(
            run_id=2,
            ticket_id="RR-1",
            provider="claude",
            payload={
                "status": "completed",
                "summary": "Implemented the scoped source change.",
                "changed_paths": ["source.txt"],
                "verification": ["focused tests passed"],
                "source_commit": source_commit,
            },
        )
        retry = self.coordinator.submit_outcome(
            run_id=2,
            ticket_id="RR-1",
            provider="claude",
            payload={
                "status": "completed",
                "summary": "Implemented the scoped source change.",
                "changed_paths": ["source.txt"],
                "verification": ["focused tests passed"],
                "source_commit": source_commit,
            },
        )

        declared, reason = self.coordinator.validate_worker_completion(
            workspace_path=worktree,
            ticket_id="RR-1",
            run_id=2,
            provider="claude",
            start_head=start_head,
        )
        self.assertEqual(outcome, retry)
        self.assertEqual(declared, "completed")
        self.assertIn("accepted", reason)

        ticket_path = worktree / ".orchestrator/RR-1.md"
        manifest_path = worktree / ".orchestrator/.artifact-snapshot.json"
        original_ticket = ticket_path.read_bytes()
        original_manifest = manifest_path.read_bytes()
        tampered_ticket = original_ticket + b"\nworker-mutated snapshot\n"
        ticket_path.chmod(0o644)
        ticket_path.write_bytes(tampered_ticket)
        altered_manifest = json.loads(original_manifest)
        altered_manifest["files"][".orchestrator/RR-1.md"] = {
            "bytes": len(tampered_ticket),
            "sha256": hashlib.sha256(tampered_ticket).hexdigest(),
        }
        manifest_path.chmod(0o644)
        manifest_path.write_text(json.dumps(altered_manifest, sort_keys=True))
        rejected, tamper_reason = self.coordinator.validate_worker_completion(
            workspace_path=worktree,
            ticket_id="RR-1",
            run_id=2,
            provider="claude",
            start_head=start_head,
        )
        self.assertIsNone(rejected)
        self.assertIn("snapshot manifest changed", tamper_reason)
        ticket_path.write_bytes(original_ticket)
        ticket_path.chmod(0o444)
        manifest_path.write_bytes(original_manifest)
        manifest_path.chmod(0o444)
        self.assertEqual(
            self.git(worktree, "diff", "--name-only", f"{start_head}..{source_commit}"),
            "source.txt",
        )
        self.coordinator.begin_review(run_id=2, provider="codex")
        active = self.coordinator.leases.active()
        self.assertEqual([lease.role for lease in active], ["reviewer"])

        self.git(self.repo, "merge", "--no-ff", "--quiet", "run-2", "-m", "merge run 2")
        merged_head = self.git(self.repo, "rev-parse", "HEAD")
        published = self.coordinator.publish_merge_success(
            run_id=2,
            ticket_id="RR-1",
            provider="claude",
            merged_source_commit=merged_head,
        )
        duplicate = self.coordinator.publish_merge_success(
            run_id=2,
            ticket_id="RR-1",
            provider="claude",
            merged_source_commit=merged_head,
        )

        self.assertEqual(published.promoted_ticket_ids, ("RR-2",))
        self.assertTrue(duplicate.idempotent)
        self.assertEqual(self.coordinator.leases.active(), ())
        files = self.store.snapshot().files
        first = files[".orchestrator/RR-1.md"].decode()
        second = files[".orchestrator/RR-2.md"].decode()
        self.assertIn("status: done", first)
        self.assertIn("run_state: merged", first)
        self.assertIn("reviewed source merge", first)
        self.assertIn("status: ready", second)
        for ticket_id, content in excluded_before.items():
            self.assertEqual(files[f".orchestrator/{ticket_id}.md"], content)
        self.assertEqual(
            self.git(self.repo, "show", "--pretty=", "--name-only", source_commit),
            "source.txt",
        )
        self.assertNotIn(".orchestrator", self.git(self.repo, "ls-tree", "-r", "--name-only", "HEAD"))

    def test_done_cannot_publish_before_source_merge(self):
        self.write_ticket("RR-1", "Work")
        worktree = self.create_worktree("run-3")
        self.coordinator.claim_and_materialize(
            ticket_id="RR-1", run_id=3, provider="codex", workspace_path=worktree
        )
        (worktree / "source.txt").write_text("worker\n")
        self.commit(worktree, "feat: worker")
        source_commit = self.git(worktree, "rev-parse", "HEAD")
        self.coordinator.submit_outcome(
            run_id=3,
            ticket_id="RR-1",
            provider="codex",
            payload={
                "status": "completed",
                "summary": "Done.",
                "changed_paths": ["source.txt"],
                "verification": [],
                "source_commit": source_commit,
            },
        )
        self.coordinator.begin_review(run_id=3, provider="codex")

        with self.assertRaisesRegex(Exception, "requires the reviewed source merge"):
            self.coordinator.publish_merge_success(
                run_id=3,
                ticket_id="RR-1",
                provider="codex",
                merged_source_commit=source_commit,
            )
        canonical = self.store.snapshot().files[".orchestrator/RR-1.md"].decode()
        self.assertNotIn("status: done", canonical)
        self.assertEqual(self.coordinator.leases.active()[0].role, "reviewer")

    def test_verification_blocked_is_reviewed_without_advancing_dependency(self):
        self.write_ticket("RR-1", "Physical proof")
        self.write_ticket("RR-2", "Dependent", status="backlog", depends_on=("RR-1",))
        worktree = self.create_worktree("run-4")
        self.coordinator.claim_and_materialize(
            ticket_id="RR-1", run_id=4, provider="codex", workspace_path=worktree
        )
        (worktree / "source.txt").write_text("reviewable\n")
        self.commit(worktree, "fix: reviewable")
        source_commit = self.git(worktree, "rev-parse", "HEAD")
        self.coordinator.submit_outcome(
            run_id=4,
            ticket_id="RR-1",
            provider="codex",
            payload={
                "status": "verification_blocked",
                "summary": "Source implementation is complete.",
                "changed_paths": ["source.txt"],
                "verification": ["source tests passed"],
                "source_commit": source_commit,
                "verification_blocker": "Signed installed app needs physical input.",
                "verification_resume": "Install signed build and perform physical input.",
            },
        )
        self.coordinator.begin_review(run_id=4, provider="claude")
        self.git(self.repo, "merge", "--no-ff", "--quiet", "run-4", "-m", "merge run 4")
        merged = self.git(self.repo, "rev-parse", "HEAD")

        result = self.coordinator.publish_merge_success(
            run_id=4,
            ticket_id="RR-1",
            provider="codex",
            merged_source_commit=merged,
        )

        self.assertEqual(result.promoted_ticket_ids, ())
        files = self.store.snapshot().files
        self.assertIn("status: verification_blocked", files[".orchestrator/RR-1.md"].decode())
        self.assertIn("verification_blocker:", files[".orchestrator/RR-1.md"].decode())
        self.assertIn("status: backlog", files[".orchestrator/RR-2.md"].decode())

    def test_failure_retry_cancel_merge_conflict_and_restart_leases_are_idempotent(self):
        self.write_ticket("RR-1", "Lifecycle")
        worktree = self.create_worktree("run-5")
        self.coordinator.claim_and_materialize(
            ticket_id="RR-1", run_id=5, provider="codex", workspace_path=worktree
        )
        failed = self.coordinator.record_failure(
            run_id=5,
            ticket_id="RR-1",
            provider="codex",
            reason="provider authentication failed",
        )
        duplicate = self.coordinator.record_failure(
            run_id=5,
            ticket_id="RR-1",
            provider="codex",
            reason="provider authentication failed",
        )
        self.assertTrue(duplicate.idempotent)
        self.assertEqual(failed.commit_id, duplicate.commit_id)
        self.assertEqual(self.coordinator.leases.active(), ())
        self.assertIn("status: backlog", self.ticket_text("RR-1"))

        retry_tree = self.create_worktree("run-6")
        self.coordinator.claim_and_materialize(
            ticket_id="RR-1", run_id=6, provider="claude", workspace_path=retry_tree
        )
        self.coordinator.record_failure(
            run_id=6,
            ticket_id="RR-1",
            provider="claude",
            reason="review asked for changes",
            retry=True,
        )
        self.assertIn("status: ready", self.ticket_text("RR-1"))

        cancel_tree = self.create_worktree("run-7")
        self.coordinator.claim_and_materialize(
            ticket_id="RR-1", run_id=7, provider="codex", workspace_path=cancel_tree
        )
        self.coordinator.record_failure(
            run_id=7,
            ticket_id="RR-1",
            provider="codex",
            reason="user canceled",
            canceled=True,
        )
        self.assertEqual(self.coordinator.leases.active(), ())

        live_tree = self.create_worktree("run-8")
        self.coordinator.claim_and_materialize(
            ticket_id="RR-1", run_id=8, provider="codex", workspace_path=live_tree
        )
        self.assertEqual(self.coordinator.recover_leases(lambda _: "Running"), ())
        released = self.coordinator.recover_leases(lambda _: None)
        self.assertEqual(released, ("run:8:worker",))

    def test_outcomes_are_bounded_private_and_provider_neutral(self):
        for run_id, provider in ((9, "codex"), (10, "claude")):
            ticket_id = f"RR-{run_id}"
            self.write_ticket(ticket_id, provider)
            worktree = self.create_worktree(f"run-{run_id}")
            self.coordinator.claim_and_materialize(
                ticket_id=ticket_id,
                run_id=run_id,
                provider=provider,
                workspace_path=worktree,
            )
            (worktree / "source.txt").write_text(provider + "\n")
            self.commit(worktree, f"feat: {provider}")
            commit = self.git(worktree, "rev-parse", "HEAD")
            outcome = self.coordinator.submit_outcome(
                run_id=run_id,
                ticket_id=ticket_id,
                provider=provider,
                payload={
                    "status": "completed",
                    "summary": "Equivalent implementation outcome.",
                    "changed_paths": ["source.txt"],
                    "verification": ["same verification"],
                    "source_commit": commit,
                },
            )
            self.assertEqual(outcome.status, WorkerOutcomeStatus.COMPLETED)
            self.assertEqual(outcome.summary, "Equivalent implementation outcome.")

        with self.assertRaisesRegex(Exception, "prohibited Git content"):
            self.coordinator.submit_outcome(
                run_id=10,
                ticket_id="RR-10",
                provider="claude",
                payload={
                    "status": "completed",
                    "summary": "Different",
                    "changed_paths": ["source.txt"],
                    "verification": [],
                    "source_commit": self.git(self.repo, "rev-parse", "HEAD"),
                    "raw_log": "private",
                },
            )
        with self.assertRaisesRegex(Exception, "invalid source changed path"):
            self.coordinator.submit_outcome(
                run_id=10,
                ticket_id="RR-10",
                provider="claude",
                payload={
                    "status": "completed",
                    "summary": "Different",
                    "changed_paths": [".orchestrator/RR-10.md"],
                    "verification": [],
                    "source_commit": self.git(self.repo, "rev-parse", "HEAD"),
                },
            )
        log = self.root / "large.log"
        log.write_bytes(b"x" * 4096)
        self.assertEqual(self.coordinator.cap_local_log(log, max_bytes=100), 100)
        self.assertEqual(log.stat().st_size, 100)

    # Helpers

    def enable_lifecycle(self):
        snapshot = self.store.snapshot()
        config = snapshot.files[".orchestrator/config.toml"].decode()
        config = config.replace('artifact_lifecycle = "legacy"', 'artifact_lifecycle = "enabled"')
        self.store.mutate(ArtifactMutation(
            event_id="enable-lifecycle",
            actor_type="user",
            device_id="daemon-device",
            expected_base=snapshot.commit_id,
            operations=(ConfigWrite(config.encode()),),
        ))

    def scope_token(self, *, fingerprint="fingerprint-a", repository_path=None):
        payload = {
            "version": 1,
            "registrySchemaVersion": 2,
            "projectID": "lifecycle-project",
            "repositoryPath": repository_path or str(self.store.repo_path),
            "gitCommonDirectoryFingerprint": fingerprint,
            "registryRecordUpdatedAt": datetime.fromisoformat(
                self.registry_updated.replace("Z", "+00:00")
            ).timestamp(),
            "issuedAt": self.now.timestamp(),
        }
        return base64.b64encode(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        ).decode()

    def write_ticket(
        self,
        ticket_id,
        title,
        *,
        status="ready",
        depends_on=(),
        canceled=False,
        draft=False,
    ):
        fields = [
            f"id: {ticket_id}",
            f"artifact_id: artifact-{ticket_id}",
            f"title: {title}",
            f"status: {status}",
            "activity_at: 2026-08-04T00:00:00.000000Z",
            f"depends_on: [{', '.join(depends_on)}]",
            f"canceled: {str(canceled).lower()}",
            f"draft: {str(draft).lower()}",
            "worker_model: strong",
            "worker_effort: high",
            "worker_sizing_rationale: fixture",
            "worker_provider_notes: provider-neutral fixture",
        ]
        markdown = (
            "---\n" + "\n".join(fields) + "\n---\n\n## Description\n\n" + title + "\n"
        ).encode()
        return self.store.mutate(ArtifactMutation(
            event_id=f"write-{ticket_id}",
            actor_type="pm",
            device_id="daemon-device",
            expected_base=self.store._head(),
            operations=(TicketWrite(ticket_id, f"artifact-{ticket_id}", markdown),),
        ))

    def write_attachment(self, ticket_id, filename, content):
        self.store.mutate(ArtifactMutation(
            event_id=f"attach-{ticket_id}",
            actor_type="user",
            device_id="daemon-device",
            expected_base=self.store._head(),
            operations=(AttachmentWrite(ticket_id, filename, "image/png", content),),
        ))

    def create_worktree(self, branch):
        path = self.root / branch
        self.git(self.repo, "worktree", "add", "-q", "-b", branch, str(path), "main")
        return path

    def ticket_text(self, ticket_id):
        return self.store.snapshot().files[f".orchestrator/{ticket_id}.md"].decode()

    def commit(self, repo, message):
        self.git(repo, "add", "source.txt")
        self.git(
            repo,
            "-c", "user.name=Lifecycle Tests",
            "-c", "user.email=lifecycle@example.invalid",
            "commit", "-q", "-m", message,
        )

    def git(self, repo, *arguments):
        process = subprocess.run(
            ["git", "-C", str(repo), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(
            process.returncode,
            0,
            msg=f"git {' '.join(arguments)} failed: {process.stderr.decode()}",
        )
        return process.stdout.decode().strip()


if __name__ == "__main__":
    unittest.main()
