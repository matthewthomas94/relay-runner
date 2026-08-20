import dataclasses
import hashlib
import json
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from services.artifact_retention import (
    ArchiveRemoteConfirmation,
    ArtifactRetentionManager,
    HistoryAvailability,
    RetentionState,
    SnapshotLeaseStore,
    confirm_github_remote,
)
from services.artifact_store import (
    ArchiveIndexWrite,
    ArtifactConcurrentUpdate,
    ArtifactInjectedFailure,
    ArtifactMaterializationConflict,
    ArtifactMutation,
    ArtifactStore,
    AttachmentWrite,
    ConfigWrite,
    TicketWrite,
)
from services.artifact_sync import ArtifactSyncEngine, ArtifactSyncMode


UTC = timezone.utc
PNG = b"\x89PNG\r\n\x1a\nfixture"


class ArtifactRetentionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-retention-tests-")
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "--initial-branch=main", "--quiet")
        (self.repo / "source.txt").write_text("source\n")
        self.git("add", "source.txt")
        self.git(
            "-c", "user.name=Retention Tests",
            "-c", "user.email=retention@example.invalid",
            "commit", "-q", "-m", "source",
        )
        self.remote = self.root / "remote.git"
        subprocess.run(
            ["git", "init", "--bare", "--quiet", str(self.remote)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        self.git("remote", "add", "origin", str(self.remote))
        self.store = ArtifactStore(
            self.repo,
            "retention-project",
            self.root / "state",
            enabled=True,
        )
        initialized = self.store.initialize(device_id="device-a")
        config = self.store.snapshot().files[".orchestrator/config.toml"].decode()
        config = config.replace(
            'remote_sync = "local_only"\n',
            'remote_sync = "enabled"\nremote_name = "origin"\n',
        )
        enabled = self.store.mutate(ArtifactMutation(
            event_id="enable-remote",
            actor_type="user",
            device_id="device-a",
            expected_base=initialized.commit_id,
            operations=(ConfigWrite(config.encode()),),
        ))
        self.synchronizer = ArtifactSyncEngine(
            self.store,
            mode=ArtifactSyncMode.ENABLED,
            remote_name="origin",
            max_attempts=1,
            base_retry_seconds=0,
            sleep=lambda _: None,
            jitter=lambda: 0,
        )
        published = self.synchronizer.publish_initial(confirmed=True)
        self.assertEqual(published.local_head, enabled.commit_id)
        self.confirmation = ArchiveRemoteConfirmation(
            service="github",
            remote_name="origin",
            remote_url_sha256=hashlib.sha256(str(self.remote).encode()).hexdigest(),
            push_url_sha256=hashlib.sha256(str(self.remote).encode()).hexdigest(),
            exposure_confirmed=True,
        )
        self.now = datetime(2026, 8, 4, 1, 2, 3, 456789, tzinfo=UTC)
        self.leases = SnapshotLeaseStore(self.store)
        self.manager = ArtifactRetentionManager(
            self.store,
            lease_store=self.leases,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            synchronizer=self.synchronizer,
            enabled=True,
            now=lambda: self.now,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_mixed_terminal_pool_uses_one_25_ticket_limit(self):
        old = self.now - timedelta(days=365)
        nonterminal_statuses = (
            "backlog", "ready", "queued", "in_progress", "verification_blocked",
            "awaiting_review", "merge_conflict",
        )
        fixtures = [
            (
                f"RR-N{index}",
                status,
                old,
                {"status": status, "depends_on": "[RR-missing]"},
            )
            for index, status in enumerate(nonterminal_statuses, 1)
        ]

        for index in range(1, 25):
            extra = {"status": "done"} if index % 2 else {"status": "backlog", "canceled": "true"}
            fixtures.append((
                f"RR-T{index:02d}",
                f"terminal {index}",
                self.now + timedelta(seconds=index),
                extra,
            ))
        self.write_ticket_batch(fixtures, event_id="mixed-24")
        plan_24 = self.manager.preview()
        self.assertEqual(len(plan_24.retained_terminal), 24)
        self.assertEqual(plan_24.candidate_ids, ())

        self.write_ticket(
            "RR-T25", "terminal 25", activity_at=self.now + timedelta(seconds=25),
            extra={"status": "done"},
        )
        plan_25 = self.manager.preview()
        self.assertEqual(len(plan_25.retained_terminal), 25)
        self.assertEqual(plan_25.candidate_ids, ())

        self.write_ticket(
            "RR-T26", "terminal 26", activity_at=self.now + timedelta(seconds=26),
            extra={"status": "backlog", "canceled": "true"},
        )
        plan_26 = self.manager.preview()
        self.assertEqual(plan_26.policy, "terminal-count-v1")
        self.assertEqual(plan_26.limit, 25)
        self.assertEqual(plan_26.candidate_ids, ("RR-T01",))
        self.assertEqual(set(plan_26.nonterminal_ids), {f"RR-N{i}" for i in range(1, 8)})
        self.assertFalse(set(plan_26.nonterminal_ids) & set(plan_26.retained_terminal_ids))

    def test_equal_activity_uses_immutable_artifact_id_tie_breaker(self):
        self.write_ticket_batch([
            (
                f"RR-{index:02d}",
                f"terminal {index}",
                self.now,
                {"status": "done", "artifact_id": f"artifact-{index:02d}"},
            )
            for index in range(26)
        ], event_id="equal-activity")

        plan = self.manager.preview()

        self.assertEqual(plan.candidate_ids, ("RR-25",))
        self.assertEqual(
            [ticket.artifact_id for ticket in plan.retained_terminal],
            [f"artifact-{index:02d}" for index in range(25)],
        )

    def test_hundreds_of_terminal_tickets_keep_exactly_newest_25(self):
        self.write_ticket_batch([
            (
                f"RR-scale-{index:03d}",
                f"terminal {index}",
                self.now + timedelta(seconds=index),
                {"status": "done"},
            )
            for index in range(300)
        ], event_id="scale-300")

        plan = self.manager.preview()

        self.assertEqual(len(plan.ranked_terminal), 300)
        self.assertEqual(len(plan.retained_terminal), 25)
        self.assertEqual(len(plan.candidates), 275)
        self.assertEqual(plan.retained_terminal_ids[0], "RR-scale-299")
        self.assertEqual(plan.candidate_ids[0], "RR-scale-274")

    def test_terminal_overage_has_only_bounded_exact_reasons(self):
        self.seed_retained_terminal()
        old = self.now - timedelta(days=365)
        fixtures = {
            "RR-lease-codex": {},
            "RR-lease-claude": {},
            "RR-unpublished": {"pending_sync": "true"},
            "RR-transaction": {"retention_transaction": "verifying"},
            "RR-retry": {"retryable_verification_failure": "true"},
            "RR-worker": {"run_state": "reviewing"},
            "RR-evict": {},
        }
        self.write_ticket_batch([
            (ticket_id, ticket_id, old, {"status": "done", **extra})
            for ticket_id, extra in fixtures.items()
        ], event_id="terminal-overage")
        head = self.store._head()
        for provider in ("codex", "claude"):
            ticket_id = f"RR-lease-{provider}"
            self.leases.acquire(
                lease_id=f"lease-{provider}", ticket_id=ticket_id,
                artifact_id=f"artifact-{ticket_id}", artifact_head=head,
                run_id=f"run-{provider}", role="worker", provider=provider, now=old,
            )

        plan = self.manager.preview()

        self.assertEqual(plan.candidate_ids, ("RR-evict",))
        self.assertEqual(plan.temporary_overage, {
            "RR-lease-claude": ("live_lease:snapshot",),
            "RR-lease-codex": ("live_lease:snapshot",),
            "RR-retry": ("retryable_verification_failure",),
            "RR-transaction": ("in_flight_transaction",),
            "RR-unpublished": ("unpublished_content",),
            "RR-worker": ("live_lease:reviewing",),
        })
        self.assertEqual(
            SnapshotLeaseStore(self.store).active_ticket_ids(),
            frozenset({"RR-lease-codex", "RR-lease-claude"}),
        )

    def test_reopen_leaves_terminal_pool_and_reterminalize_reranks(self):
        self.seed_retained_terminal()
        old = self.now - timedelta(days=365)
        self.write_ticket("RR-reopen", "Reopen", activity_at=old, extra={"status": "done"})
        self.assertEqual(self.manager.preview().candidate_ids, ("RR-reopen",))

        self.rewrite_ticket(
            "RR-reopen", "Reopen", event_id="reopen-ticket",
            activity_at=self.now + timedelta(minutes=1), extra={"status": "backlog"},
        )
        reopened = self.manager.preview()
        self.assertIn("RR-reopen", reopened.nonterminal_ids)
        self.assertNotIn("RR-reopen", [ticket.ticket_id for ticket in reopened.ranked_terminal])

        self.rewrite_ticket(
            "RR-reopen", "Reopen", event_id="reterminalize-ticket",
            activity_at=self.now + timedelta(minutes=2), extra={"status": "done"},
        )
        reterminalized = self.manager.preview()
        self.assertEqual(reterminalized.retained_terminal_ids[0], "RR-reopen")
        self.assertEqual(reterminalized.candidate_ids, ("RR-retained-00",))

    def test_missing_materialized_or_catalog_activity_fails_closed(self):
        ticket_id = "RR-missing"
        markdown = (
            "---\nid: RR-missing\nartifact_id: artifact-RR-missing\n"
            "title: Missing\nstatus: done\n---\n"
        ).encode()
        self.store.mutate(ArtifactMutation(
            event_id="write-missing", actor_type="pm", device_id="device-a",
            expected_base=self.store._head(),
            operations=(TicketWrite(ticket_id, "artifact-RR-missing", markdown),),
        ))
        with self.assertRaisesRegex(Exception, "no durable activity timestamp"):
            self.manager.preview()

        self.store.mutate(ArtifactMutation(
            event_id="remove-missing", actor_type="system", device_id="device-a",
            expected_base=self.store._head(), operations=(
                ArchiveIndexWrite((json.dumps({
                    "schema_version": 1,
                    "artifact_id": "artifact-catalog-missing",
                    "ticket_id": "RR-catalog-missing",
                    "title": "Missing catalog activity",
                    "status": "done",
                    "state": "archived",
                    "ticket_path": ".orchestrator/RR-catalog-missing.md",
                    "ticket_blob": "1" * 40,
                    "source_commit": "2" * 40,
                    "attachments": [],
                }, sort_keys=True) + "\n").encode()),
            ),
        ))
        # The malformed materialized record remains the first fail-closed
        # condition; catalog validation is independently exercised below.
        snapshot = self.store.snapshot()
        self.store.mutate(ArtifactMutation(
            event_id="fix-materialized-activity", actor_type="pm", device_id="device-a",
            expected_base=snapshot.commit_id,
            operations=(TicketWrite(
                ticket_id, "artifact-RR-missing",
                self.ticket_markdown(ticket_id, "Missing", activity_at=self.now, extra={"status": "done"}),
            ),),
        ))
        with self.assertRaisesRegex(Exception, "retention metadata is incomplete: activity_at"):
            self.manager.preview()

    def test_concurrent_terminal_mutation_invalidates_preview(self):
        self.seed_retained_terminal()
        old = self.now - timedelta(days=365)
        self.write_ticket("RR-old", "Old", activity_at=old, extra={"status": "done"})
        plan = self.manager.preview()
        self.write_ticket(
            "RR-new", "New", activity_at=self.now + timedelta(days=1), extra={"status": "done"}
        )

        with self.assertRaisesRegex(ArtifactConcurrentUpdate, "head changed"):
            self.manager.archive(plan, event_id="stale-plan", device_id="device-a")

    def test_archive_is_deterministic_atomic_reachable_and_source_isolated(self):
        self.seed_retained_terminal()
        old = self.now - timedelta(days=31)
        self.write_ticket(
            "RR-2", "Second", activity_at=old,
            extra={"status": "backlog", "canceled": "true"},
        )
        self.write_ticket("RR-1", "First", activity_at=old, extra={"status": "done"})
        self.write_attachment("RR-1", "proof.png", PNG)
        plan_a = self.manager.preview()
        plan_b = self.manager.preview()
        before = self.source_snapshot()

        result = self.manager.archive(
            plan_a,
            event_id="archive-batch",
            device_id="device-a",
        )
        repeated = self.manager.archive(
            plan_a,
            event_id="archive-batch",
            device_id="device-a",
        )

        self.assertEqual(plan_a, plan_b)
        self.assertEqual(plan_a.candidate_ids, ("RR-1", "RR-2"))
        self.assertEqual(result.state, RetentionState.ARCHIVED)
        self.assertTrue(repeated.write.idempotent)
        self.assertEqual(repeated.write.commit_id, result.write.commit_id)
        self.assertEqual(self.source_snapshot(), before)
        self.assertNotIn("refs/relay-runner/retention/", self.git("show-ref"))
        snapshot = self.store.snapshot()
        self.assertNotIn(".orchestrator/RR-1.md", snapshot.files)
        self.assertNotIn(".orchestrator/attachments/RR-1/proof.png", snapshot.files)
        catalog_lines = snapshot.files[".orchestrator/archive-index.jsonl"].decode().splitlines()
        self.assertEqual(
            [json.loads(line)["artifact_id"] for line in catalog_lines],
            ["artifact-RR-1", "artifact-RR-2"],
        )
        self.assertEqual(json.loads(catalog_lines[1])["status"], "canceled")
        source_commit = json.loads(catalog_lines[0])["source_commit"]
        self.assertTrue(self.is_ancestor(source_commit, result.write.commit_id))

    def test_historical_search_detail_restore_and_dependency_resolution(self):
        self.seed_retained_terminal()
        old = self.now - timedelta(days=31)
        self.write_ticket("RR-1", "Done predecessor", activity_at=old, extra={"status": "done"})
        self.write_ticket("RR-2", "Open predecessor", activity_at=old, extra={"status": "backlog"})
        self.write_attachment("RR-1", "proof.png", PNG)
        archived = self.manager.archive(
            self.manager.preview(),
            event_id="archive-history",
            device_id="device-a",
        )
        head_before_detail = self.store._head()

        cards = self.manager.historical_search("predecessor")
        detail = self.manager.historical_detail("artifact-RR-1")

        self.assertEqual({card.ticket_id for card in cards}, {"RR-1"})
        self.assertEqual(detail.availability, HistoryAvailability.AVAILABLE)
        self.assertIn(b"Done predecessor", detail.ticket_bytes)
        self.assertEqual(detail.attachments[0]["path"], ".orchestrator/attachments/RR-1/proof.png")
        self.assertEqual(self.store._head(), head_before_detail)
        self.assertNotIn(".orchestrator/RR-1.md", self.store.snapshot().files)
        self.assertIn(".orchestrator/RR-2.md", self.store.snapshot().files)
        self.assertTrue(self.manager.dependency_satisfied("RR-1"))
        self.assertFalse(self.manager.dependency_satisfied("RR-2"))
        archived_plan = self.manager.preview()
        self.assertIn("RR-1", [ticket.ticket_id for ticket in archived_plan.ranked_terminal])
        self.assertNotIn("RR-1", archived_plan.materialize_ids)

        restored = self.manager.restore(
            "artifact-RR-1",
            event_id="restore-one",
            device_id="device-a",
            restored_at=self.now,
        )
        retried = self.manager.restore(
            "artifact-RR-1",
            event_id="restore-one",
            device_id="device-a",
            restored_at=self.now,
        )

        self.assertEqual(restored.state, RetentionState.RESTORE_PENDING_SYNC)
        self.assertTrue(retried.write.idempotent)
        files = self.store.snapshot().files
        self.assertIn("artifact_id: artifact-RR-1", files[".orchestrator/RR-1.md"].decode())
        self.assertIn(f"activity_at: {format_instant(self.now)}", files[".orchestrator/RR-1.md"].decode())
        self.assertEqual(files[".orchestrator/attachments/RR-1/proof.png"], PNG)
        self.assertIn("RR-1", self.manager.preview().retained_terminal_ids)

    def test_archive_failures_preserve_or_recover_projection_from_canonical_ref(self):
        self.seed_retained_terminal()
        old = self.now - timedelta(days=31)
        self.write_ticket("RR-1", "Failure", activity_at=old, extra={"status": "done"})
        base = self.store._head()
        before_files = self.store.snapshot().files

        manager = ArtifactRetentionManager(
            self.store,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            synchronizer=self.synchronizer,
            enabled=True,
            now=lambda: self.now,
            failure_injector=lambda stage: (_ for _ in ()).throw(ArtifactInjectedFailure(stage))
            if stage == "before_archive_commit" else None,
        )
        with self.assertRaises(ArtifactInjectedFailure):
            manager.archive(
                manager.preview(), event_id="archive-before", device_id="device-a"
            )
        self.assertEqual(self.store._head(), base)
        self.assertEqual(self.store.snapshot().files, before_files)

        crash_stages = (
            "after_archive_prepare",
            "after_remote_verification",
            "after_local_ref_update",
            "after_archive_materialization",
        )
        for index, crash_stage in enumerate(crash_stages):
            ticket_id = "RR-1" if index == 0 else f"RR-crash-{index}"
            if index:
                self.write_ticket(
                    ticket_id,
                    crash_stage,
                    activity_at=old - timedelta(minutes=index),
                    extra={"status": "done"},
                )
            base = self.store._head()
            manager = ArtifactRetentionManager(
                self.store,
                remote_mode="enabled",
                remote_confirmation=self.confirmation,
                synchronizer=self.synchronizer,
                enabled=True,
                now=lambda: self.now,
                failure_injector=lambda stage, target=crash_stage: (
                    (_ for _ in ()).throw(ArtifactInjectedFailure(stage))
                    if stage == target else None
                ),
            )
            with self.subTest(crash_stage=crash_stage):
                with self.assertRaises(ArtifactInjectedFailure):
                    manager.archive(
                        manager.preview(),
                        event_id=f"archive-{index}",
                        device_id="device-a",
                    )
                self.assertTrue(manager.transaction_path.exists())
                if crash_stage in {"after_archive_prepare", "after_remote_verification"}:
                    self.assertEqual(self.store._head(), base)
                    self.assertIn(
                        f".orchestrator/{ticket_id}.md", self.store.snapshot().files
                    )
                recovered = self.manager.recover_archive()
                self.assertEqual(recovered.state, RetentionState.ARCHIVED)
                self.assertFalse(manager.transaction_path.exists())
                self.assertNotIn(
                    f".orchestrator/{ticket_id}.md", self.store.snapshot().files
                )

    def test_remote_archive_failure_never_advances_local_authority(self):
        self.seed_retained_terminal()
        old = self.now - timedelta(days=31)
        self.write_ticket("RR-1", "Pending", activity_at=old, extra={"status": "done"})
        base = self.store._head()
        before = self.store.snapshot().files
        actual_sync = self.synchronizer

        class OfflineSync:
            remote_name = "origin"

            def sync_confirmed(self, **kwargs):
                return actual_sync.sync_confirmed(**kwargs)

            def publish_prepared(self, *args, **kwargs):
                return dataclasses.make_dataclass("Result", [("state", object), ("recovery", str)])(
                    dataclasses.make_dataclass("State", [("value", str)])("retryable_offline"),
                    "Reconnect and retry.",
                )

            def recover_exact_ref(self, **kwargs):
                raise AssertionError("not used")

        manager = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            now=lambda: self.now,
        )

        result = manager.archive(
            manager.preview(),
            event_id="archive-offline",
            device_id="device-a",
            synchronizer=OfflineSync(),
        )

        self.assertEqual(result.state, RetentionState.ARCHIVE_PENDING_SYNC)
        self.assertEqual(self.store._head(), base)
        self.assertEqual(self.store.snapshot().files, before)
        self.assertEqual(
            manager.preview().temporary_overage["RR-1"],
            ("in_flight_transaction", "retryable_verification_failure"),
        )
        restarted = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            synchronizer=self.synchronizer,
            now=lambda: self.now,
        )
        recovered = restarted.recover_archive()
        self.assertEqual(recovered.state, RetentionState.ARCHIVED)
        self.assertNotIn(".orchestrator/RR-1.md", self.store.snapshot().files)

    def test_recovery_from_published_phase_preserves_late_manual_edit(self):
        self.seed_retained_terminal()
        self.write_ticket(
            "RR-late-edit",
            "Edited after verification",
            activity_at=self.now - timedelta(days=365),
            extra={"status": "done"},
        )
        base = self.store._head()
        manager = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            synchronizer=self.synchronizer,
            now=lambda: self.now,
            failure_injector=lambda stage: (
                (_ for _ in ()).throw(ArtifactInjectedFailure(stage))
                if stage == "after_remote_verification" else None
            ),
        )

        with self.assertRaises(ArtifactInjectedFailure):
            manager.archive(
                manager.preview(), event_id="archive-late-edit", device_id="device-a"
            )

        transaction = json.loads(manager.transaction_path.read_text(encoding="utf-8"))
        self.assertEqual(transaction["phase"], "published")
        ticket_path = self.store.materialized_path / "RR-late-edit.md"
        manual_content = ticket_path.read_bytes() + b"\nManual edit after verification.\n"
        ticket_path.write_bytes(manual_content)
        restarted = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            synchronizer=self.synchronizer,
            now=lambda: self.now,
        )

        with self.assertRaisesRegex(ArtifactMaterializationConflict, "edited manually"):
            restarted.recover_archive()

        self.assertEqual(self.store._head(), base)
        self.assertEqual(ticket_path.read_bytes(), manual_content)
        self.assertEqual(
            json.loads(manager.transaction_path.read_text(encoding="utf-8"))["phase"],
            "published",
        )

    def test_crash_after_push_is_resolved_by_refetch_without_local_loss(self):
        self.seed_retained_terminal()
        self.write_ticket(
            "RR-pushed",
            "Pushed before crash",
            activity_at=self.now - timedelta(days=365),
            extra={"status": "done"},
        )
        base = self.store._head()
        crashing_sync = ArtifactSyncEngine(
            self.store,
            mode=ArtifactSyncMode.ENABLED,
            remote_name="origin",
            max_attempts=1,
            base_retry_seconds=0,
            failure_injector=lambda stage: (
                (_ for _ in ()).throw(ArtifactInjectedFailure(stage))
                if stage == "after_prepared_push" else None
            ),
        )
        manager = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            synchronizer=crashing_sync,
            now=lambda: self.now,
        )

        with self.assertRaises(ArtifactInjectedFailure):
            manager.archive(
                manager.preview(), event_id="archive-pushed", device_id="device-a"
            )

        transaction = json.loads(manager.transaction_path.read_text(encoding="utf-8"))
        self.assertEqual(transaction["phase"], "prepared")
        self.assertEqual(self.store._head(), base)
        self.assertIn(".orchestrator/RR-pushed.md", self.store.snapshot().files)
        self.assertEqual(
            self.git("--git-dir", str(self.remote), "rev-parse", "refs/heads/relay/artifacts"),
            transaction["candidate_head"],
        )
        restarted = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            synchronizer=self.synchronizer,
            now=lambda: self.now,
        )
        recovered = restarted.recover_archive()
        self.assertEqual(recovered.state, RetentionState.ARCHIVED)
        self.assertNotIn(".orchestrator/RR-pushed.md", self.store.snapshot().files)

    def test_remote_cleanup_requires_selected_github_exposure_confirmation(self):
        self.git("remote", "add", "github", "git@github.com:relay/example.git")
        with self.assertRaisesRegex(Exception, "explicit confirmation"):
            confirm_github_remote(self.store, "github", exposure_confirmed=False)
        confirmation = confirm_github_remote(
            self.store, "github", exposure_confirmed=True
        )
        self.assertEqual(confirmation.remote_name, "github")
        self.git(
            "remote", "add", "unsafe-github",
            "https://github.com/relay/example.git?embedded=credential",
        )
        with self.assertRaisesRegex(Exception, "github.com remote"):
            confirm_github_remote(
                self.store, "unsafe-github", exposure_confirmed=True
            )

        self.seed_retained_terminal()
        self.write_ticket(
            "RR-held",
            "Held locally",
            activity_at=self.now - timedelta(days=365),
            extra={"status": "done"},
        )
        manager = ArtifactRetentionManager(
            self.store,
            remote_mode="enabled",
            synchronizer=self.synchronizer,
            enabled=True,
            now=lambda: self.now,
        )

        with self.assertRaisesRegex(Exception, "not been explicitly confirmed"):
            manager.archive(
                manager.preview(), event_id="unconfirmed", device_id="device-a"
            )
        self.assertIn(".orchestrator/RR-held.md", self.store.snapshot().files)

    def test_unconfirmed_non_github_pushurl_never_publishes(self):
        self.git("remote", "add", "github", "git@github.com:relay/example.git")
        confirmation = confirm_github_remote(
            self.store, "github", exposure_confirmed=True
        )
        unconfirmed = self.root / "unconfirmed-push.git"
        subprocess.run(
            ["git", "init", "--bare", "--quiet", str(unconfirmed)],
            check=True,
        )
        self.git("remote", "set-url", "--push", "github", str(unconfirmed))
        synchronizer = ArtifactSyncEngine(
            self.store,
            mode=ArtifactSyncMode.ENABLED,
            remote_name="github",
            max_attempts=1,
            base_retry_seconds=0,
        )
        manager = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            remote_confirmation=confirmation,
            synchronizer=synchronizer,
            now=lambda: self.now,
        )
        self.seed_retained_terminal()
        self.write_ticket(
            "RR-pushurl",
            "Keep local",
            activity_at=self.now - timedelta(days=365),
            extra={"status": "done"},
        )

        with self.assertRaisesRegex(Exception, "push destination changed"):
            manager.archive(
                manager.preview(), event_id="unconfirmed-pushurl", device_id="device-a"
            )

        self.assertEqual(self.git("ls-remote", str(unconfirmed), self.store.artifact_ref), "")
        self.assertIn(".orchestrator/RR-pushurl.md", self.store.snapshot().files)

    def test_push_destination_is_revalidated_immediately_before_publication(self):
        self.seed_retained_terminal()
        self.write_ticket(
            "RR-late-pushurl",
            "Keep after late redirect",
            activity_at=self.now - timedelta(days=365),
            extra={"status": "done"},
        )
        base = self.store._head()
        unconfirmed = self.root / "late-push.git"
        subprocess.run(
            ["git", "init", "--bare", "--quiet", str(unconfirmed)],
            check=True,
        )

        def redirect_push(stage):
            if stage == "before_prepared_push":
                self.git("remote", "set-url", "--push", "origin", str(unconfirmed))

        synchronizer = ArtifactSyncEngine(
            self.store,
            mode=ArtifactSyncMode.ENABLED,
            remote_name="origin",
            max_attempts=1,
            base_retry_seconds=0,
            sleep=lambda _: None,
            jitter=lambda: 0,
            failure_injector=redirect_push,
        )
        manager = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            synchronizer=synchronizer,
            now=lambda: self.now,
        )

        with self.assertRaisesRegex(Exception, "push destination changed"):
            manager.archive(
                manager.preview(), event_id="late-pushurl", device_id="device-a"
            )

        self.assertEqual(self.store._head(), base)
        self.assertEqual(self.git("ls-remote", str(unconfirmed), self.store.artifact_ref), "")
        self.assertIn(".orchestrator/RR-late-pushurl.md", self.store.snapshot().files)

    def test_post_push_verification_stays_bound_to_confirmed_fetch_destination(self):
        self.seed_retained_terminal()
        self.write_ticket(
            "RR-late-fetchurl",
            "Keep after late fetch redirect",
            activity_at=self.now - timedelta(days=365),
            extra={"status": "done"},
        )
        base = self.store._head()
        projection = dict(self.store.snapshot().files)
        ticket_path = self.store.materialized_path / "RR-late-fetchurl.md"
        ticket_content = ticket_path.read_bytes()
        mirror = self.root / "late-fetch.git"
        subprocess.run(
            ["git", "init", "--bare", "--quiet", str(mirror)],
            check=True,
        )
        self.git("remote", "set-url", "--push", "origin", str(self.remote))

        def redirect_fetch(stage):
            if stage != "after_prepared_push":
                return
            self.git(
                "--git-dir", str(self.remote),
                "push", str(mirror),
                f"{self.store.artifact_ref}:{self.store.artifact_ref}",
            )
            self.git("remote", "set-url", "origin", str(mirror))
            self.assertEqual(
                self.git("remote", "get-url", "--push", "origin"),
                str(self.remote),
            )
            self.git(
                "--git-dir", str(self.remote),
                "update-ref", "-d", self.store.artifact_ref,
            )

        synchronizer = ArtifactSyncEngine(
            self.store,
            mode=ArtifactSyncMode.ENABLED,
            remote_name="origin",
            max_attempts=1,
            base_retry_seconds=0,
            sleep=lambda _: None,
            jitter=lambda: 0,
            failure_injector=redirect_fetch,
        )
        manager = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            synchronizer=synchronizer,
            now=lambda: self.now,
        )

        with self.assertRaisesRegex(Exception, "fetch destination changed"):
            manager.archive(
                manager.preview(), event_id="late-fetchurl", device_id="device-a"
            )

        self.assertEqual(self.git("ls-remote", str(self.remote), self.store.artifact_ref), "")
        self.assertEqual(self.store._head(), base)
        self.assertEqual(dict(self.store.snapshot().files), projection)
        self.assertEqual(ticket_path.read_bytes(), ticket_content)
        self.assertEqual(
            json.loads(manager.transaction_path.read_text(encoding="utf-8"))["phase"],
            "prepared",
        )

    def test_preflight_push_stays_bound_to_confirmed_destination(self):
        self.seed_retained_terminal()
        self.write_ticket(
            "RR-preflight-pushurl",
            "Keep after preflight redirect",
            activity_at=self.now - timedelta(days=365),
            extra={"status": "done"},
        )
        base = self.store._head()
        projection = dict(self.store.snapshot().files)
        confirmed_remote_head = self.git(
            "--git-dir", str(self.remote), "rev-parse", self.store.artifact_ref
        )
        unconfirmed = self.root / "preflight-push.git"
        subprocess.run(
            ["git", "init", "--bare", "--quiet", str(unconfirmed)],
            check=True,
        )

        def redirect_preflight_push(stage):
            if stage == "before_push":
                self.git("remote", "set-url", "--push", "origin", str(unconfirmed))

        synchronizer = ArtifactSyncEngine(
            self.store,
            mode=ArtifactSyncMode.ENABLED,
            remote_name="origin",
            max_attempts=1,
            base_retry_seconds=0,
            sleep=lambda _: None,
            jitter=lambda: 0,
            failure_injector=redirect_preflight_push,
        )
        manager = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            synchronizer=synchronizer,
            now=lambda: self.now,
        )

        with self.assertRaisesRegex(Exception, "push destination changed"):
            manager.archive(
                manager.preview(),
                event_id="preflight-pushurl",
                device_id="device-a",
            )

        self.assertEqual(self.git("ls-remote", str(unconfirmed), self.store.artifact_ref), "")
        self.assertEqual(
            self.git("--git-dir", str(self.remote), "rev-parse", self.store.artifact_ref),
            confirmed_remote_head,
        )
        self.assertEqual(self.store._head(), base)
        self.assertEqual(dict(self.store.snapshot().files), projection)
        self.assertFalse(manager.transaction_path.exists())

    def test_prepared_candidate_is_pinned_before_journal_publication(self):
        self.seed_retained_terminal()
        self.write_ticket(
            "RR-prejournal",
            "Survive pre-journal pruning",
            activity_at=self.now - timedelta(days=365),
            extra={"status": "done"},
        )
        plan = self.manager.preview()
        base = self.store._head()
        manager = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            synchronizer=self.synchronizer,
            now=lambda: self.now,
            failure_injector=lambda stage: (
                (_ for _ in ()).throw(ArtifactInjectedFailure(stage))
                if stage == "after_archive_scratch" else None
            ),
        )

        with self.assertRaisesRegex(ArtifactInjectedFailure, "after_archive_scratch"):
            manager.archive(
                plan,
                event_id="archive-prejournal",
                device_id="device-a",
            )

        scratch_ref = manager._scratch_ref("archive-prejournal")
        candidate_head = self.git("rev-parse", scratch_ref)
        self.assertFalse(manager.transaction_path.exists())
        self.assertEqual(self.store._head(), base)
        self.assertIn(".orchestrator/RR-prejournal.md", self.store.snapshot().files)
        self.git("prune", "--expire=now")
        self.assertEqual(self.git("cat-file", "-t", candidate_head), "commit")

        restarted = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            synchronizer=self.synchronizer,
            now=lambda: self.now,
        )
        recovered = restarted.archive(
            plan,
            event_id="archive-prejournal",
            device_id="device-a",
        )

        self.assertEqual(recovered.state, RetentionState.ARCHIVED)
        self.assertNotIn(".orchestrator/RR-prejournal.md", self.store.snapshot().files)
        self.assertNotIn(scratch_ref, self.git("show-ref"))

    def test_remote_race_discards_only_unpublished_candidate_for_safe_replan(self):
        self.seed_retained_terminal()
        self.write_ticket(
            "RR-race",
            "Remote race",
            activity_at=self.now - timedelta(days=365),
            extra={"status": "done"},
        )
        base = self.store._head()

        class RaceSync:
            remote_name = "origin"

            def sync_confirmed(self, **kwargs):
                return dataclasses.make_dataclass(
                    "Result", [("state", object), ("local_head", str), ("remote_head", str)]
                )(
                    dataclasses.make_dataclass("State", [("value", str)])("clean"),
                    base,
                    base,
                )

            def publish_prepared(self, *args, **kwargs):
                return dataclasses.make_dataclass(
                    "Result",
                    [("state", object), ("remote_head", str), ("recovery", str)],
                )(
                    dataclasses.make_dataclass("State", [("value", str)])("behind"),
                    "f" * 40,
                    "Remote advanced during publication.",
                )

            def recover_exact_ref(self, **kwargs):
                raise AssertionError("not used")

        raced_manager = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            now=lambda: self.now,
        )
        plan = raced_manager.preview()

        blocked = raced_manager.archive(
            plan,
            event_id="archive-race",
            device_id="device-a",
            synchronizer=RaceSync(),
        )

        self.assertEqual(blocked.state, RetentionState.ARCHIVE_PENDING_SYNC)
        self.assertFalse(raced_manager.transaction_path.exists())
        self.assertEqual(self.store._head(), base)
        self.assertIn(".orchestrator/RR-race.md", self.store.snapshot().files)
        retried = self.manager.archive(
            plan, event_id="archive-race-retry", device_id="device-a"
        )
        self.assertEqual(retried.state, RetentionState.ARCHIVED)

    def test_fresh_recovery_materializes_nonterminal_and_newest_25_only(self):
        self.seed_retained_terminal()
        old = self.now - timedelta(days=365)
        self.write_ticket("RR-open", "Open", activity_at=old)
        self.write_ticket("RR-archived", "Archived", activity_at=old, extra={"status": "done"})
        archived = self.manager.archive(
            self.manager.preview(), event_id="archive-for-recovery", device_id="device-a"
        )
        self.assertEqual(archived.state, RetentionState.ARCHIVED)

        fresh_repo = self.root / "fresh"
        fresh_repo.mkdir()
        subprocess.run(
            ["git", "-C", str(fresh_repo), "init", "--initial-branch=main", "--quiet"],
            check=True,
        )
        (fresh_repo / "source.txt").write_text("fresh\n")
        subprocess.run(["git", "-C", str(fresh_repo), "add", "source.txt"], check=True)
        subprocess.run(
            [
                "git", "-C", str(fresh_repo),
                "-c", "user.name=Retention Tests",
                "-c", "user.email=retention@example.invalid",
                "commit", "-q", "-m", "fresh source",
            ],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(fresh_repo), "remote", "add", "origin", str(self.remote)],
            check=True,
        )
        fresh_store = ArtifactStore(
            fresh_repo,
            "retention-project",
            self.root / "fresh-state",
            enabled=True,
        )
        fresh_sync = ArtifactSyncEngine(
            fresh_store,
            mode=ArtifactSyncMode.ENABLED,
            remote_name="origin",
            max_attempts=1,
            base_retry_seconds=0,
        )
        fresh_manager = ArtifactRetentionManager(
            fresh_store,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            synchronizer=fresh_sync,
            enabled=True,
            now=lambda: self.now,
        )

        recovered = fresh_manager.recover_from_remote()

        self.assertEqual(recovered.state.value, "clean")
        files = fresh_store.snapshot().files
        materialized = [path for path in files if path.endswith(".md")]
        self.assertEqual(len(materialized), 26)
        self.assertIn(".orchestrator/RR-open.md", files)
        self.assertNotIn(".orchestrator/RR-archived.md", files)
        self.assertEqual(fresh_manager.preview().candidate_ids, ())

    def test_recovery_retarget_cannot_adopt_unconfirmed_descendant(self):
        confirmed_head = self.store._head()
        descendant = self.write_ticket(
            "RR-unconfirmed-descendant",
            "Unconfirmed descendant",
            activity_at=self.now,
        ).commit_id
        self.assertNotEqual(descendant, confirmed_head)
        unconfirmed = self.root / "recovery-retarget.git"
        subprocess.run(
            ["git", "init", "--bare", "--quiet", str(unconfirmed)],
            check=True,
        )
        self.git(
            "push",
            str(unconfirmed),
            f"{descendant}:{self.store.artifact_ref}",
        )

        fresh_repo = self.root / "retargeted-recovery"
        fresh_repo.mkdir()
        subprocess.run(
            ["git", "-C", str(fresh_repo), "init", "--initial-branch=main", "--quiet"],
            check=True,
        )
        (fresh_repo / "source.txt").write_text("fresh\n")
        subprocess.run(["git", "-C", str(fresh_repo), "add", "source.txt"], check=True)
        subprocess.run(
            [
                "git", "-C", str(fresh_repo),
                "-c", "user.name=Retention Tests",
                "-c", "user.email=retention@example.invalid",
                "commit", "-q", "-m", "fresh source",
            ],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(fresh_repo), "remote", "add", "origin", str(self.remote)],
            check=True,
        )
        fresh_store = ArtifactStore(
            fresh_repo,
            "retention-project",
            self.root / "retargeted-recovery-state",
            enabled=True,
        )

        def retarget_recovery(stage):
            if stage == "before_recovery_fetch":
                subprocess.run(
                    [
                        "git", "-C", str(fresh_repo),
                        "remote", "set-url", "origin", str(unconfirmed),
                    ],
                    check=True,
                )

        fresh_sync = ArtifactSyncEngine(
            fresh_store,
            mode=ArtifactSyncMode.ENABLED,
            remote_name="origin",
            max_attempts=1,
            base_retry_seconds=0,
            failure_injector=retarget_recovery,
        )
        fresh_manager = ArtifactRetentionManager(
            fresh_store,
            enabled=True,
            remote_mode="enabled",
            remote_confirmation=self.confirmation,
            synchronizer=fresh_sync,
            now=lambda: self.now,
        )

        with self.assertRaisesRegex(Exception, "fetch destination changed"):
            fresh_manager.recover_from_remote()

        self.assertIsNone(fresh_store._head())
        self.assertFalse(fresh_store.materialized_path.exists())
        self.assertNotEqual(
            subprocess.run(
                ["git", "-C", str(fresh_repo), "cat-file", "-e", descendant],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            ).returncode,
            0,
        )

    def test_tampered_and_missing_history_fail_closed_without_materialization(self):
        self.seed_retained_terminal()
        old = self.now - timedelta(days=31)
        self.write_ticket("RR-1", "Tamper", activity_at=old, extra={"status": "done"})
        self.manager.archive(
            self.manager.preview(), event_id="archive-tamper", device_id="device-a"
        )
        snapshot = self.store.snapshot()
        catalog = json.loads(snapshot.files[".orchestrator/archive-index.jsonl"])
        config_oid = self.store._tree_entries(snapshot.commit_id)[".orchestrator/config.toml"].oid
        catalog["ticket_blob"] = config_oid
        self.replace_catalog(catalog, "tamper-catalog")
        head = self.store._head()

        detail = self.manager.historical_detail("artifact-RR-1")

        self.assertEqual(detail.availability, HistoryAvailability.TAMPERED)
        with self.assertRaisesRegex(Exception, "mismatch"):
            self.manager.restore(
                "artifact-RR-1", event_id="restore-tampered", device_id="device-a"
            )
        self.assertEqual(self.store._head(), head)
        self.assertNotIn(".orchestrator/RR-1.md", self.store.snapshot().files)

        catalog["source_commit"] = "0" * 40
        catalog["ticket_blob"] = config_oid
        self.replace_catalog(catalog, "missing-history")
        calls = []
        missing = self.manager.historical_detail(
            "artifact-RR-1", online=True, deepen=lambda commit: calls.append(commit)
        )
        self.assertEqual(missing.availability, HistoryAvailability.NEEDS_NETWORK)
        self.assertEqual(calls, ["0" * 40])

    def test_recoverable_delete_warns_history_remains_and_can_restore(self):
        old = self.now - timedelta(days=31)
        self.write_ticket("RR-1", "Delete me", activity_at=old)

        deleted = self.manager.delete(
            "RR-1", event_id="delete-one", device_id="device-a"
        )

        self.assertEqual(deleted.state, RetentionState.DELETED_TOMBSTONE)
        self.assertIn("does not erase Git history", deleted.warnings[0])
        self.assertEqual(
            self.manager.historical_search()[0].state,
            RetentionState.DELETED_TOMBSTONE,
        )
        self.manager.restore(
            "artifact-RR-1", event_id="restore-delete", device_id="device-a"
        )
        self.assertIn(".orchestrator/RR-1.md", self.store.snapshot().files)

    def test_storage_layers_and_snapshot_lease_terminal_paths_are_separate(self):
        self.write_ticket("RR-1", "Metrics", activity_at=self.now)
        head = self.store._head()
        first = self.leases.acquire(
            lease_id="lease-metrics",
            ticket_id="RR-1",
            artifact_id="artifact-RR-1",
            artifact_head=head,
            run_id="run-metrics",
            role="reviewer",
            provider="claude",
            now=self.now - timedelta(days=90),
        )
        same = self.leases.acquire(
            lease_id="lease-metrics",
            ticket_id="RR-1",
            artifact_id="artifact-RR-1",
            artifact_head=head,
            run_id="run-metrics",
            role="reviewer",
            provider="claude",
            now=self.now,
        )
        self.assertEqual(first, same)
        self.assertIn("RR-1", self.leases.active_ticket_ids())
        released = self.leases.release(
            "lease-metrics", terminal_reason="review accepted", now=self.now
        )
        self.assertEqual(released.state, "released")
        self.assertNotIn("RR-1", self.leases.active_ticket_ids())
        self.assertEqual(
            self.leases.release("lease-metrics", terminal_reason="review accepted", now=self.now),
            released,
        )

        run_dir = self.root / "runs"
        index_dir = self.root / "indexes"
        run_dir.mkdir()
        index_dir.mkdir()
        (run_dir / "runs.db").write_bytes(b"r" * 17)
        (index_dir / "search.db").write_bytes(b"i" * 23)
        metrics = self.manager.storage_metrics(
            run_paths=(run_dir,), index_cache_paths=(index_dir,)
        )
        self.assertGreater(metrics.materialized_worktree_bytes, 0)
        self.assertGreater(metrics.reachable_git_object_bytes, 0)
        self.assertEqual(metrics.run_database_log_bytes, 17)
        self.assertEqual(metrics.derived_index_cache_bytes, 23)
        self.assertEqual(metrics.reclaimable_estimate_bytes, 23)

    # Helpers

    def seed_retained_terminal(self):
        operations = []
        for index in range(25):
            ticket_id = f"RR-retained-{index:02d}"
            artifact_id = f"artifact-{ticket_id}"
            operations.append(TicketWrite(
                ticket_id,
                artifact_id,
                self.ticket_markdown(
                    ticket_id,
                    ticket_id,
                    activity_at=self.now + timedelta(seconds=index),
                    extra={"status": "done", "artifact_id": artifact_id},
                ),
            ))
        return self.store.mutate(ArtifactMutation(
            event_id="seed-retained-terminal",
            actor_type="pm",
            device_id="device-a",
            expected_base=self.store._head(),
            operations=tuple(operations),
        ))

    def write_ticket(self, ticket_id, title, *, activity_at, extra=None):
        extra = dict(extra or {})
        artifact_id = str(extra.get("artifact_id") or f"artifact-{ticket_id}")
        markdown = self.ticket_markdown(
            ticket_id, title, activity_at=activity_at, extra=extra
        )
        return self.store.mutate(
            ArtifactMutation(
                event_id=f"write-{ticket_id}",
                actor_type="pm",
                device_id="device-a",
                expected_base=self.store._head(),
                operations=(TicketWrite(ticket_id, artifact_id, markdown),),
            )
        )

    def write_ticket_batch(self, fixtures, *, event_id):
        operations = []
        for ticket_id, title, activity_at, extra in fixtures:
            extra = dict(extra or {})
            artifact_id = str(extra.get("artifact_id") or f"artifact-{ticket_id}")
            operations.append(TicketWrite(
                ticket_id,
                artifact_id,
                self.ticket_markdown(ticket_id, title, activity_at=activity_at, extra=extra),
            ))
        return self.store.mutate(ArtifactMutation(
            event_id=event_id,
            actor_type="pm",
            device_id="device-a",
            expected_base=self.store._head(),
            operations=tuple(operations),
        ))

    def rewrite_ticket(self, ticket_id, title, *, event_id, activity_at, extra=None):
        extra = dict(extra or {})
        artifact_id = str(extra.get("artifact_id") or f"artifact-{ticket_id}")
        return self.store.mutate(ArtifactMutation(
            event_id=event_id,
            actor_type="pm",
            device_id="device-a",
            expected_base=self.store._head(),
            operations=(TicketWrite(
                ticket_id,
                artifact_id,
                self.ticket_markdown(ticket_id, title, activity_at=activity_at, extra=extra),
            ),),
        ))

    def ticket_markdown(self, ticket_id, title, *, activity_at, extra=None):
        extra = dict(extra or {})
        status = extra.pop("status", "backlog")
        fields = {
            "id": ticket_id,
            "artifact_id": f"artifact-{ticket_id}",
            "title": title,
            "status": status,
            "activity_at": format_instant(activity_at),
            **extra,
        }
        front = "\n".join(f"{key}: {value}" for key, value in fields.items())
        return f"---\n{front}\n---\n\n## Description\n\n{title}\n".encode()

    def write_attachment(self, ticket_id, filename, content):
        return self.store.mutate(
            ArtifactMutation(
                event_id=f"attach-{ticket_id}-{filename}",
                actor_type="user",
                device_id="device-a",
                expected_base=self.store._head(),
                operations=(AttachmentWrite(ticket_id, filename, "image/png", content),),
            )
        )

    def replace_catalog(self, entry, event_id):
        content = (json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n").encode()
        return self.store.mutate(
            ArtifactMutation(
                event_id=event_id,
                actor_type="system",
                device_id="device-a",
                expected_base=self.store._head(),
                operations=(ArchiveIndexWrite(content),),
            )
        )

    def source_snapshot(self):
        index = Path(self.git("rev-parse", "--git-path", "index"))
        if not index.is_absolute():
            index = self.repo / index
        refs = [
            line for line in self.git("show-ref").splitlines()
            if not line.endswith(" refs/heads/relay/artifacts")
            and not line.endswith("/relay/artifacts")
            and "refs/relay-runner/retention/" not in line
        ]
        return {
            "head": self.git("rev-parse", "HEAD"),
            "status": self.git("status", "--porcelain=v1", "--untracked-files=all"),
            "index": index.read_bytes(),
            "refs": refs,
            "remotes": self.git("remote", "-v"),
            "source": (self.repo / "source.txt").read_bytes(),
        }

    def is_ancestor(self, first, second):
        return self.store._git(
            "merge-base", "--is-ancestor", first, second, allowed_statuses={0, 1}
        ).returncode == 0

    def git(self, *arguments):
        import subprocess
        process = subprocess.run(
            ["git", "-C", str(self.repo), *arguments],
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


def format_instant(value):
    return value.astimezone(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


if __name__ == "__main__":
    unittest.main()
