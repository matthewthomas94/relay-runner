import dataclasses
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from services.artifact_retention import (
    ArtifactRetentionManager,
    HistoryAvailability,
    RetentionState,
    SnapshotLeaseStore,
)
from services.artifact_store import (
    ArchiveIndexWrite,
    ArtifactInjectedFailure,
    ArtifactMutation,
    ArtifactStore,
    AttachmentWrite,
    TicketWrite,
)


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
        self.store = ArtifactStore(
            self.repo,
            "retention-project",
            self.root / "state",
            enabled=True,
        )
        self.store.initialize(device_id="device-a")
        self.now = datetime(2026, 8, 4, 1, 2, 3, 456789, tzinfo=UTC)
        self.leases = SnapshotLeaseStore(self.store)
        self.manager = ArtifactRetentionManager(
            self.store,
            lease_store=self.leases,
            enabled=True,
            now=lambda: self.now,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_activity_uses_durable_max_and_exact_utc_boundary(self):
        boundary = self.now - timedelta(days=30)
        self.write_ticket(
            "RR-1",
            "Boundary",
            activity_at=boundary - timedelta(days=1),
            extra={"status_updated_at": format_instant(boundary)},
        )
        self.write_ticket(
            "RR-2",
            "Older",
            activity_at=boundary - timedelta(microseconds=1),
        )
        offset_boundary = boundary.astimezone(timezone(timedelta(hours=10)))
        self.write_ticket(
            "RR-3",
            "Offset boundary",
            activity_at=offset_boundary,
        )

        plan = self.manager.preview()

        self.assertEqual(plan.candidate_ids, ("RR-2",))
        self.assertEqual({ticket.ticket_id for ticket in plan.recent}, {"RR-1", "RR-3"})
        self.assertEqual(
            next(ticket for ticket in plan.recent if ticket.ticket_id == "RR-1").activity_at,
            boundary,
        )

    def test_every_active_dependency_sync_pin_and_lease_exemption_is_fail_safe(self):
        old = self.now - timedelta(days=31)
        fixtures = (
            ("RR-1", {"status": "ready"}),
            ("RR-2", {"status": "in_progress"}),
            ("RR-3", {"status": "verification_blocked"}),
            ("RR-4", {"status": "awaiting_review"}),
            ("RR-5", {"status": "merge_conflict"}),
            ("RR-6", {"blocked": "true"}),
            ("RR-7", {"pending_sync": "true"}),
            ("RR-8", {"unpublished_conflict": "true"}),
            ("RR-9", {"pinned": "true"}),
            ("RR-10", {"run_state": "reviewing"}),
            ("RR-11", {"depends_on": "[RR-99]"}),
            ("RR-12", {}),
        )
        for ticket_id, extra in fixtures:
            self.write_ticket(ticket_id, ticket_id, activity_at=old, extra=extra)
        head = self.store._head()
        lease = self.leases.acquire(
            lease_id="lease-12",
            ticket_id="RR-12",
            artifact_id="artifact-RR-12",
            artifact_head=head,
            run_id="run-12",
            role="worker",
            provider="codex",
            now=old,
        )

        plan = self.manager.preview()

        self.assertEqual(plan.candidates, ())
        exemptions = {
            ticket.ticket_id: ticket.exemptions
            for ticket in plan.exempt
        }
        self.assertIn("snapshot_lease", exemptions["RR-12"])
        self.assertIn("unresolved_dependency:RR-99", exemptions["RR-11"])
        self.assertEqual(self.leases.active_ticket_ids(), frozenset({"RR-12"}))
        reloaded = SnapshotLeaseStore(self.store).active()[0]
        self.assertEqual(reloaded.lease_id, lease.lease_id)
        self.assertEqual(reloaded.heartbeat_at, old)

    def test_archive_is_deterministic_atomic_reachable_and_source_isolated(self):
        old = self.now - timedelta(days=31)
        self.write_ticket("RR-2", "Second", activity_at=old)
        self.write_ticket("RR-1", "First", activity_at=old)
        self.write_attachment("RR-1", "proof.png", PNG)
        plan_a = self.manager.preview()
        plan_b = self.manager.preview()
        before = self.source_snapshot()

        result = self.manager.archive(
            plan_a,
            event_id="archive-batch",
            device_id="device-a",
        )

        self.assertEqual(plan_a, plan_b)
        self.assertEqual(plan_a.candidate_ids, ("RR-1", "RR-2"))
        self.assertEqual(result.state, RetentionState.ARCHIVED)
        self.assertEqual(self.source_snapshot(), before)
        snapshot = self.store.snapshot()
        self.assertNotIn(".orchestrator/RR-1.md", snapshot.files)
        self.assertNotIn(".orchestrator/attachments/RR-1/proof.png", snapshot.files)
        catalog_lines = snapshot.files[".orchestrator/archive-index.jsonl"].decode().splitlines()
        self.assertEqual(
            [json.loads(line)["artifact_id"] for line in catalog_lines],
            ["artifact-RR-1", "artifact-RR-2"],
        )
        source_commit = json.loads(catalog_lines[0])["source_commit"]
        self.assertTrue(self.is_ancestor(source_commit, result.write.commit_id))

    def test_historical_search_detail_restore_and_dependency_resolution(self):
        old = self.now - timedelta(days=31)
        self.write_ticket("RR-1", "Done predecessor", activity_at=old, extra={"status": "done"})
        self.write_ticket("RR-2", "Open predecessor", activity_at=old)
        self.write_attachment("RR-1", "proof.png", PNG)
        archived = self.manager.archive(
            self.manager.preview(),
            event_id="archive-history",
            device_id="device-a",
        )
        head_before_detail = self.store._head()

        cards = self.manager.historical_search("predecessor")
        detail = self.manager.historical_detail("artifact-RR-1")

        self.assertEqual({card.ticket_id for card in cards}, {"RR-1", "RR-2"})
        self.assertEqual(detail.availability, HistoryAvailability.AVAILABLE)
        self.assertIn(b"Done predecessor", detail.ticket_bytes)
        self.assertEqual(detail.attachments[0]["path"], ".orchestrator/attachments/RR-1/proof.png")
        self.assertEqual(self.store._head(), head_before_detail)
        self.assertNotIn(".orchestrator/RR-1.md", self.store.snapshot().files)
        self.assertTrue(self.manager.dependency_satisfied("RR-1"))
        self.assertFalse(self.manager.dependency_satisfied("RR-2"))

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

        self.assertEqual(restored.state, RetentionState.MATERIALIZED_RECENT)
        self.assertTrue(retried.write.idempotent)
        files = self.store.snapshot().files
        self.assertIn("artifact_id: artifact-RR-1", files[".orchestrator/RR-1.md"].decode())
        self.assertIn(f"activity_at: {format_instant(self.now)}", files[".orchestrator/RR-1.md"].decode())
        self.assertEqual(files[".orchestrator/attachments/RR-1/proof.png"], PNG)

    def test_archive_failures_preserve_or_recover_projection_from_canonical_ref(self):
        old = self.now - timedelta(days=31)
        self.write_ticket("RR-1", "Failure", activity_at=old)
        base = self.store._head()
        before_files = self.store.snapshot().files

        manager = ArtifactRetentionManager(
            self.store,
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

        self.store.failure_injector = lambda stage: (
            (_ for _ in ()).throw(ArtifactInjectedFailure(stage))
            if stage == "after_ref_update" else None
        )
        with self.assertRaises(ArtifactInjectedFailure):
            self.manager.archive(
                self.manager.preview(), event_id="archive-after", device_id="device-a"
            )
        advanced = self.store._head()
        self.assertNotEqual(advanced, base)
        self.store.failure_injector = None
        self.assertEqual(self.store.recover(), advanced)
        self.assertNotIn(".orchestrator/RR-1.md", self.store.snapshot().files)

    def test_remote_archive_failure_rewinds_only_unpublished_archive(self):
        old = self.now - timedelta(days=31)
        self.write_ticket("RR-1", "Pending", activity_at=old)
        base = self.store._head()
        before = self.store.snapshot().files
        manager = ArtifactRetentionManager(
            self.store,
            enabled=True,
            remote_mode="enabled",
            now=lambda: self.now,
        )

        class OfflineSync:
            def sync(self):
                return dataclasses.make_dataclass("Result", [("state", object), ("recovery", str)])(
                    dataclasses.make_dataclass("State", [("value", str)])("retryable_offline"),
                    "Reconnect and retry.",
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

    def test_tampered_and_missing_history_fail_closed_without_materialization(self):
        old = self.now - timedelta(days=31)
        self.write_ticket("RR-1", "Tamper", activity_at=old)
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

    def write_ticket(self, ticket_id, title, *, activity_at, extra=None):
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
        markdown = f"---\n{front}\n---\n\n## Description\n\n{title}\n".encode()
        return self.store.mutate(
            ArtifactMutation(
                event_id=f"write-{ticket_id}",
                actor_type="pm",
                device_id="device-a",
                expected_base=self.store._head(),
                operations=(TicketWrite(ticket_id, f"artifact-{ticket_id}", markdown),),
            )
        )

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
