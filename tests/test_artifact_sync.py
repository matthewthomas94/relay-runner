import dataclasses
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from services.artifact_store import (
    ARTIFACT_REF,
    ArtifactMutation,
    ArtifactStore,
    AttachmentWrite,
    ConfigWrite,
    TicketDelete,
    TicketWrite,
)
from services.artifact_sync import (
    ArtifactRemoteProof,
    ArtifactSyncEngine,
    ArtifactSyncMode,
    ArtifactSyncState,
)


@dataclasses.dataclass
class Device:
    name: str
    repo: Path
    state: Path
    store: ArtifactStore


class ArtifactSyncTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-sync-tests-")
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote.git"
        self.run_git(None, "init", "--bare", "--quiet", str(self.remote))
        self.run_git(self.remote, "symbolic-ref", "HEAD", "refs/heads/main")
        self.device_a = self.make_first_device("a")
        initialized = self.device_a.store.initialize(device_id="device-a")
        enabled = self.enable_remote(self.device_a, initialized.commit_id)
        self.engine(self.device_a).publish_initial(confirmed=True)
        self.device_b = self.clone_device("b")
        self.assertEqual(self.device_b.store.initialize(device_id="device-b").commit_id, enabled)

    def tearDown(self):
        self.temporary.cleanup()

    def test_setup_requires_explicit_remote_and_local_only_never_touches_network(self):
        local_repo = self.root / "local-only"
        local_repo.mkdir()
        self.run_git(local_repo, "init", "--initial-branch=main", "--quiet")
        (local_repo / "source.txt").write_text("source\n")
        self.commit_source(local_repo, "source")
        store = ArtifactStore(
            local_repo,
            "local-project",
            self.root / "local-state",
            enabled=True,
        )
        store.initialize(device_id="local-device")
        result = ArtifactSyncEngine(
            store,
            mode=ArtifactSyncMode.LOCAL_ONLY,
            remote_name=None,
        ).sync()
        self.assertEqual(result.state, ArtifactSyncState.LOCAL_ONLY)
        self.assertEqual(self.run_git(local_repo, "remote"), "")

        with self.assertRaisesRegex(Exception, "explicitly selected"):
            ArtifactSyncEngine(
                store,
                mode=ArtifactSyncMode.ENABLED,
                remote_name=None,
            )
        local_store_head = store._head()
        local_config = store.snapshot().files[".orchestrator/config.toml"].decode()
        local_config = re_sub_line(local_config, "remote_sync", 'remote_sync = "enabled"')
        local_config = re_sub_line(local_config, "remote_name", 'remote_name = "missing"')
        store.mutate(
            ArtifactMutation(
                event_id="select-missing",
                actor_type="user",
                device_id="local-device",
                operations=(ConfigWrite(local_config.encode()),),
                expected_base=local_store_head,
            )
        )
        with self.assertRaisesRegex(Exception, "will not create"):
            ArtifactSyncEngine(
                store,
                mode=ArtifactSyncMode.ENABLED,
                remote_name="missing",
            ).sync()

    def test_missing_remote_ref_requires_confirmed_first_normal_push(self):
        other_remote = self.root / "empty.git"
        self.run_git(None, "init", "--bare", "--quiet", str(other_remote))
        device = self.make_first_device("missing", remote=other_remote)
        initialized = device.store.initialize(device_id="missing-device")
        self.enable_remote(device, initialized.commit_id)
        engine = self.engine(device)

        held = engine.publish_initial(confirmed=False)
        self.assertEqual(held.state, ArtifactSyncState.MISSING_REMOTE_REF)
        self.assertEqual(
            self.run_git(other_remote, "show-ref", "--verify", ARTIFACT_REF, allow=(0, 1, 128)),
            "",
        )

        published = engine.publish_initial(confirmed=True)
        self.assertEqual(published.state, ArtifactSyncState.CLEAN)
        self.assertEqual(
            self.run_git(other_remote, "rev-parse", ARTIFACT_REF),
            published.local_head,
        )

    def test_prepared_publication_refetches_proofs_before_local_ref_moves(self):
        base = self.device_a.store._head()
        content = self.ticket_bytes("RR-prepared", "Prepared", "artifact-RR-prepared")
        prepared = self.device_a.store.prepare_mutation(
            self.mutation(
                self.device_a,
                "prepared-ticket",
                TicketWrite("RR-prepared", "artifact-RR-prepared", content),
                expected_base=base,
            )
        )
        proof = ArtifactRemoteProof(
            source_commit=prepared.commit_id,
            path=".orchestrator/RR-prepared.md",
            blob_id=self.device_a.store._tree_entries(prepared.commit_id)[
                ".orchestrator/RR-prepared.md"
            ].oid,
            sha256=hashlib.sha256(content).hexdigest(),
        )

        failed = self.engine(self.device_a).publish_prepared(
            prepared.commit_id,
            expected_remote_head=base,
            proofs=(dataclasses.replace(proof, sha256="0" * 64),),
        )

        self.assertEqual(failed.state, ArtifactSyncState.FAILED)
        self.assertEqual(self.device_a.store._head(), base)
        self.assertNotIn(".orchestrator/RR-prepared.md", self.device_a.store.snapshot().files)
        self.assertEqual(self.run_git(self.remote, "rev-parse", ARTIFACT_REF), prepared.commit_id)

        verified = self.engine(self.device_a).publish_prepared(
            prepared.commit_id,
            expected_remote_head=base,
            proofs=(proof,),
        )
        self.assertEqual(verified.state, ArtifactSyncState.CLEAN)
        self.assertEqual(verified.remote_head, prepared.commit_id)
        self.assertEqual(self.device_a.store._head(), base)

    def test_fresh_device_recovers_only_exact_remote_artifact_ref(self):
        remote_head = self.write_ticket(
            self.device_a, "recovery-ticket", "RR-recovery", "Recovered"
        )
        self.assertEqual(self.engine(self.device_a).sync().state, ArtifactSyncState.CLEAN)
        fresh_repo = self.root / "fresh-device"
        fresh_repo.mkdir()
        self.run_git(fresh_repo, "init", "--initial-branch=main", "--quiet")
        (fresh_repo / "source.txt").write_text("fresh source\n")
        self.commit_source(fresh_repo, "fresh source")
        self.run_git(fresh_repo, "remote", "add", "origin", str(self.remote))
        fresh = Device(
            "fresh",
            fresh_repo,
            self.root / "state-fresh",
            ArtifactStore(
                fresh_repo,
                "project-sync",
                self.root / "state-fresh",
                enabled=True,
            ),
        )
        validated = []

        result = self.engine(fresh).recover_exact_ref(
            expected_remote_url_sha256=self.confirmed_fetch_digest(fresh),
            validate_head=lambda head: validated.append(head)
        )

        self.assertEqual(result.state, ArtifactSyncState.CLEAN)
        self.assertEqual(result.local_head, remote_head)
        self.assertEqual(validated, [remote_head])
        self.assertIn(".orchestrator/RR-recovery.md", fresh.store.snapshot().files)
        refs = self.run_git(fresh_repo, "for-each-ref", "--format=%(refname)").splitlines()
        self.assertEqual(
            refs,
            ["refs/heads/main", ARTIFACT_REF],
        )

    def test_fresh_device_restart_materializes_after_recovery_ref_update_crash(self):
        remote_head = self.write_ticket(
            self.device_a, "recovery-crash-ticket", "RR-recovery-crash", "Recovered"
        )
        self.assertEqual(self.engine(self.device_a).sync().state, ArtifactSyncState.CLEAN)
        fresh_repo = self.root / "fresh-device-crash"
        fresh_repo.mkdir()
        self.run_git(fresh_repo, "init", "--initial-branch=main", "--quiet")
        (fresh_repo / "source.txt").write_text("fresh source\n")
        self.commit_source(fresh_repo, "fresh source")
        self.run_git(fresh_repo, "remote", "add", "origin", str(self.remote))
        fresh_state = self.root / "state-fresh-crash"
        fresh = Device(
            "fresh-crash",
            fresh_repo,
            fresh_state,
            ArtifactStore(fresh_repo, "project-sync", fresh_state, enabled=True),
        )

        def crash_after_ref_update(stage):
            if stage == "after_recovery_ref_update":
                raise RuntimeError(stage)

        with self.assertRaisesRegex(RuntimeError, "after_recovery_ref_update"):
            self.engine(
                fresh,
                failure_injector=crash_after_ref_update,
            ).recover_exact_ref(
                expected_remote_url_sha256=self.confirmed_fetch_digest(fresh)
            )

        self.assertEqual(fresh.store._head(), remote_head)
        self.assertFalse(fresh.store.materialized_path.exists())
        self.assertFalse(fresh.store.metadata_path.exists())
        self.assertFalse(fresh.store.journal_path.exists())

        restarted = Device(
            "fresh-crash-restarted",
            fresh_repo,
            fresh_state,
            ArtifactStore(fresh_repo, "project-sync", fresh_state, enabled=True),
        )
        result = self.engine(restarted).recover_exact_ref(
            expected_remote_url_sha256=self.confirmed_fetch_digest(restarted)
        )

        self.assertEqual(result.state, ArtifactSyncState.CLEAN)
        self.assertEqual(result.local_head, remote_head)
        recovered_ticket = restarted.store.materialized_path / "RR-recovery-crash.md"
        self.assertTrue(recovered_ticket.is_file())
        self.assertIn("Recovered", recovered_ticket.read_text())
        metadata = json.loads(restarted.store.metadata_path.read_text())
        self.assertEqual(metadata["commit_id"], remote_head)
        self.assertFalse(restarted.store.journal_path.exists())

    def test_second_device_recovery_preserves_manual_materialization_edits(self):
        self.write_ticket(
            self.device_a, "manual-base", "RR-manual", "Shared before edit"
        )
        self.assertEqual(self.engine(self.device_a).sync().state, ArtifactSyncState.CLEAN)
        self.assertEqual(self.engine(self.device_b).sync().state, ArtifactSyncState.CLEAN)
        local_head = self.device_b.store._head()
        ticket_path = self.device_b.repo / ".orchestrator/RR-manual.md"
        manual_content = ticket_path.read_bytes().replace(
            b"Shared before edit", b"Manual materialization edit"
        )
        ticket_path.write_bytes(manual_content)

        remote_head = self.write_ticket(
            self.device_a, "remote-ahead", "RR-remote", "Remote ahead"
        )
        self.assertEqual(self.engine(self.device_a).sync().state, ArtifactSyncState.CLEAN)

        result = self.engine(self.device_b).recover_exact_ref(
            expected_remote_url_sha256=self.confirmed_fetch_digest(self.device_b)
        )

        self.assertEqual(result.state, ArtifactSyncState.FAILED)
        self.assertIn("edited manually", result.recovery)
        self.assertEqual(self.device_b.store._head(), local_head)
        self.assertEqual(ticket_path.read_bytes(), manual_content)
        self.assertEqual(self.run_git(self.remote, "rev-parse", ARTIFACT_REF), remote_head)

    def test_two_devices_rebase_unrelated_offline_events_and_preserve_source_state(self):
        shared = self.write_ticket(self.device_a, "base-ticket", "RR-1", "Base")
        self.assertEqual(self.engine(self.device_a).sync().state, ArtifactSyncState.CLEAN)
        self.assertEqual(self.engine(self.device_b).sync().state, ArtifactSyncState.CLEAN)

        local_a = self.write_ticket(self.device_a, "offline-a", "RR-2", "Device A")
        local_b = self.write_ticket(self.device_b, "offline-b", "RR-3", "Device B")
        self.make_dirty_source_fixture(self.device_b.repo)
        before = self.source_snapshot(self.device_b.repo)

        self.assertEqual(self.engine(self.device_a).sync().state, ArtifactSyncState.CLEAN)
        result_b = self.engine(self.device_b).sync()

        self.assertEqual(result_b.state, ArtifactSyncState.CLEAN)
        self.assertEqual(result_b.observed_state, ArtifactSyncState.CONFLICT)
        self.assertEqual(self.source_snapshot(self.device_b.repo), before)
        files = self.device_b.store.snapshot().files
        self.assertIn(".orchestrator/RR-2.md", files)
        self.assertIn(".orchestrator/RR-3.md", files)
        self.assertNotEqual(result_b.local_head, local_b)
        self.assertTrue(self.is_ancestor(local_a, result_b.local_head, self.device_b.repo))
        self.assertEqual(
            self.run_git(self.remote, "rev-parse", "refs/heads/main"),
            self.run_git(self.device_a.repo, "rev-parse", "refs/remotes/origin/main"),
        )
        state = json.loads(
            (self.device_b.state / "artifacts/project-sync/sync-state.json").read_text()
        )
        self.assertEqual(state["state"], "clean")

    def test_same_ticket_conflict_has_three_way_evidence_and_explicit_resolution(self):
        base = self.write_ticket(self.device_a, "shared-ticket", "RR-4", "Shared")
        self.engine(self.device_a).sync()
        self.engine(self.device_b).sync()

        remote_event = self.ticket_mutation(
            self.device_a,
            "edit-a",
            "RR-4",
            "From A",
            artifact_id="artifact-RR-4",
        )
        self.device_a.store.mutate(remote_event)
        local_event = self.ticket_mutation(
            self.device_b,
            "edit-b",
            "RR-4",
            "From B",
            artifact_id="artifact-RR-4",
        )
        self.device_b.store.mutate(local_event)
        self.engine(self.device_a).sync()

        conflict = self.engine(self.device_b).sync()
        self.assertEqual(conflict.state, ArtifactSyncState.CONFLICT)
        report = conflict.conflict_report
        self.assertIsNotNone(report)
        self.assertEqual(report.merge_base, base)
        evidence = report.conflicts[0]
        self.assertEqual(evidence.path, ".orchestrator/RR-4.md")
        self.assertEqual(evidence.kind, "same_ticket")
        self.assertTrue(evidence.base_oid)
        self.assertTrue(evidence.local_oid)
        self.assertTrue(evidence.remote_oid)

        merged = self.ticket_bytes("RR-4", "Reviewed merge", "artifact-RR-4")
        resolved = self.engine(self.device_b).resolve_conflict(
            report,
            {evidence.path: merged},
            resolution_event_id="resolve-RR-4",
            device_id="device-b",
            provider="claude",
        )
        self.assertEqual(resolved.state, ArtifactSyncState.CLEAN)
        self.assertIn(
            "Reviewed merge",
            self.device_b.store.snapshot().files[evidence.path].decode(),
        )
        retry = self.device_b.store.mutate(local_event)
        self.assertTrue(retry.idempotent)
        self.assertEqual(retry.commit_id, resolved.local_head)
        message = self.run_git(
            self.device_b.repo, "show", "-s", "--format=%B", resolved.local_head
        )
        self.assertIn("Relay-Resolved-Event: edit-b", message)

    def test_conflict_taxonomy_covers_display_config_attachment_and_delete_edit(self):
        scenarios = (
            ("display_id_collision", self.prepare_display_collision),
            ("config_collision", self.prepare_config_collision),
            ("attachment_collision", self.prepare_attachment_collision),
            ("delete_edit", self.prepare_delete_edit_collision),
        )
        for expected_kind, prepare in scenarios:
            with self.subTest(kind=expected_kind):
                self.reset_devices()
                prepare()
                self.engine(self.device_a).sync()
                result = self.engine(self.device_b).sync()
                self.assertEqual(result.state, ArtifactSyncState.CONFLICT)
                self.assertIn(expected_kind, {item.kind for item in result.conflict_report.conflicts})
                self.assertNotIn("force", (result.recovery or "").lower())

    def test_push_race_retries_bounded_and_never_duplicates_event(self):
        self.write_ticket(self.device_b, "race-b", "RR-7", "B")
        injected = False

        def advance_remote(stage):
            nonlocal injected
            if stage != "before_push" or injected:
                return
            injected = True
            self.write_ticket(self.device_a, "race-a", "RR-8", "A")
            self.engine(self.device_a).sync()

        engine = self.engine(
            self.device_b,
            failure_injector=advance_remote,
            max_attempts=3,
        )
        result = engine.sync()

        self.assertEqual(result.state, ArtifactSyncState.CLEAN)
        self.assertEqual(result.attempts, 2)
        log = self.run_git(
            self.device_b.repo,
            "log",
            "--format=%B%x00",
            ARTIFACT_REF,
        )
        self.assertEqual(log.count("Relay-Event-ID: race-b"), 1)
        self.assertIn(".orchestrator/RR-7.md", self.device_b.store.snapshot().files)
        self.assertIn(".orchestrator/RR-8.md", self.device_b.store.snapshot().files)

    def test_exact_quarantine_fetch_excludes_source_refs_and_rejects_foreign_artifact(self):
        private_repo = self.root / "private-source"
        self.run_git(None, "clone", "-q", str(self.remote), str(private_repo))
        (private_repo / "private.txt").write_text("ordinary source history\n")
        self.commit_source(private_repo, "private source")
        private_oid = self.run_git(private_repo, "rev-parse", "HEAD")
        self.run_git(private_repo, "push", "-q", "origin", "HEAD:refs/heads/private-source")
        self.assertFalse(self.object_exists(self.device_b.repo, private_oid))

        status = self.engine(self.device_b).status()
        self.assertEqual(status.state, ArtifactSyncState.CLEAN)
        self.assertFalse(self.object_exists(self.device_b.repo, private_oid))

        foreign_remote = self.root / "foreign.git"
        self.run_git(None, "init", "--bare", "--quiet", str(foreign_remote))
        foreign_repo = self.root / "foreign-work"
        self.run_git(None, "clone", "-q", str(self.remote), str(foreign_repo))
        (foreign_repo / "foreign-source.txt").write_text("must not import\n")
        self.commit_source(foreign_repo, "foreign source")
        foreign_oid = self.run_git(foreign_repo, "rev-parse", "HEAD")
        self.run_git(
            foreign_repo,
            "push",
            "-q",
            str(foreign_remote),
            f"{foreign_oid}:{ARTIFACT_REF}",
        )
        self.run_git(self.device_b.repo, "remote", "add", "foreign", str(foreign_remote))
        config = self.config_bytes(self.device_b, remote_name="foreign")
        current = self.device_b.store._head()
        self.device_b.store.mutate(
            self.mutation(
                self.device_b,
                "select-foreign",
                ConfigWrite(config),
                expected_base=current,
            )
        )
        engine = ArtifactSyncEngine(
            self.device_b.store,
            mode=ArtifactSyncMode.ENABLED,
            remote_name="foreign",
            base_retry_seconds=0,
        )
        result = engine.sync()
        self.assertEqual(result.state, ArtifactSyncState.FOREIGN_REF)
        self.assertFalse(self.object_exists(self.device_b.repo, foreign_oid))

    def test_local_unowned_commit_fails_closed_and_error_classification_is_recoverable(self):
        head = self.device_b.store._head()
        tree = self.run_git(self.device_b.repo, "rev-parse", f"{head}^{{tree}}")
        unowned = self.commit_tree(self.device_b.repo, tree, head, "manual artifact commit\n")
        self.run_git(self.device_b.repo, "update-ref", ARTIFACT_REF, unowned, head)
        result = self.engine(self.device_b).sync()
        self.assertEqual(result.state, ArtifactSyncState.LOCAL_AHEAD_BLOCKED)
        self.assertIn("not owned by project", result.recovery)

        cases = {
            "Could not resolve host github.com": ArtifactSyncState.RETRYABLE_OFFLINE,
            "Authentication failed": ArtifactSyncState.RETRYABLE_AUTH,
            "protected branch hook declined": ArtifactSyncState.PROTECTED_REF,
            "rejected non-fast-forward": ArtifactSyncState.AHEAD,
            "couldn't find remote ref": ArtifactSyncState.MISSING_REMOTE_REF,
        }
        for message, expected in cases.items():
            operation = "push" if "rejected" in message else "fetch"
            state, recovery = ArtifactSyncEngine.classify_git_failure(
                message, operation=operation
            )
            self.assertEqual(state, expected)
            self.assertTrue(recovery)

    # Scenario preparation

    def prepare_display_collision(self):
        self.device_a.store.mutate(
            self.ticket_mutation(
                self.device_a, "display-a", "RR-9", "A", artifact_id="artifact-display-a"
            )
        )
        self.device_b.store.mutate(
            self.ticket_mutation(
                self.device_b, "display-b", "RR-9", "B", artifact_id="artifact-display-b"
            )
        )

    def prepare_config_collision(self):
        for device, event, next_id in (
            (self.device_a, "config-a", 20),
            (self.device_b, "config-b", 30),
        ):
            content = self.config_bytes(device).decode().replace("next_id = 1", f"next_id = {next_id}").encode()
            device.store.mutate(
                self.mutation(device, event, ConfigWrite(content), expected_base=device.store._head())
            )

    def prepare_attachment_collision(self):
        for device, event, marker in (
            (self.device_a, "attachment-a", b"A"),
            (self.device_b, "attachment-b", b"B"),
        ):
            device.store.mutate(
                self.mutation(
                    device,
                    event,
                    AttachmentWrite(
                        "RR-10",
                        "same.png",
                        "image/png",
                        b"\x89PNG\r\n\x1a\n" + marker,
                    ),
                    expected_base=device.store._head(),
                )
            )

    def prepare_delete_edit_collision(self):
        self.write_ticket(self.device_a, "delete-base", "RR-11", "Base")
        self.engine(self.device_a).sync()
        self.engine(self.device_b).sync()
        self.device_a.store.mutate(
            self.mutation(
                self.device_a,
                "delete-a",
                TicketDelete("RR-11"),
                expected_base=self.device_a.store._head(),
            )
        )
        self.device_b.store.mutate(
            self.ticket_mutation(
                self.device_b,
                "edit-after-delete",
                "RR-11",
                "Edited",
                artifact_id="artifact-RR-11",
            )
        )

    # Fixture helpers

    def reset_devices(self):
        # Recreate a pristine two-device fixture within the same test method.
        suffix = hashlib.sha256(os.urandom(16)).hexdigest()[:8]
        self.remote = self.root / f"remote-{suffix}.git"
        self.run_git(None, "init", "--bare", "--quiet", str(self.remote))
        self.run_git(self.remote, "symbolic-ref", "HEAD", "refs/heads/main")
        self.device_a = self.make_first_device(f"a-{suffix}")
        initialized = self.device_a.store.initialize(device_id=f"device-a-{suffix}")
        self.enable_remote(self.device_a, initialized.commit_id)
        self.engine(self.device_a).publish_initial(confirmed=True)
        self.device_b = self.clone_device(f"b-{suffix}")
        self.device_b.store.initialize(device_id=f"device-b-{suffix}")

    def make_first_device(self, name, remote=None):
        repo = self.root / f"device-{name}"
        repo.mkdir()
        self.run_git(repo, "init", "--initial-branch=main", "--quiet")
        (repo / "source.txt").write_text(f"source {name}\n")
        self.commit_source(repo, "source root")
        selected_remote = remote or self.remote
        self.run_git(repo, "remote", "add", "origin", str(selected_remote))
        self.run_git(repo, "push", "-q", "-u", "origin", "main")
        state = self.root / f"state-{name}"
        store = ArtifactStore(repo, "project-sync", state, enabled=True)
        return Device(name, repo, state, store)

    def clone_device(self, name):
        repo = self.root / f"device-{name}"
        self.run_git(None, "clone", "-q", str(self.remote), str(repo))
        self.run_git(
            repo,
            "fetch",
            "-q",
            "--no-tags",
            "origin",
            f"{ARTIFACT_REF}:{ARTIFACT_REF}",
        )
        state = self.root / f"state-{name}"
        return Device(name, repo, state, ArtifactStore(repo, "project-sync", state, enabled=True))

    def enable_remote(self, device, base):
        content = self.config_bytes(device)
        result = device.store.mutate(
            self.mutation(device, f"enable-{device.name}", ConfigWrite(content), expected_base=base)
        )
        return result.commit_id

    def config_bytes(self, device, remote_name="origin"):
        current = device.store.snapshot().files[".orchestrator/config.toml"].decode()
        current = re_sub_line(current, "remote_sync", 'remote_sync = "enabled"')
        current = re_sub_line(current, "remote_name", f'remote_name = "{remote_name}"')
        return current.encode()

    def engine(self, device, **kwargs):
        return ArtifactSyncEngine(
            device.store,
            mode=ArtifactSyncMode.ENABLED,
            remote_name="origin",
            base_retry_seconds=0,
            sleep=lambda _: None,
            jitter=lambda: 0,
            **kwargs,
        )

    def confirmed_fetch_digest(self, device):
        destination = self.run_git(device.repo, "remote", "get-url", "origin")
        return hashlib.sha256(destination.encode()).hexdigest()

    def write_ticket(self, device, event_id, ticket_id, title):
        mutation = self.ticket_mutation(device, event_id, ticket_id, title)
        return device.store.mutate(mutation).commit_id

    def ticket_mutation(self, device, event_id, ticket_id, title, artifact_id=None):
        artifact_id = artifact_id or f"artifact-{ticket_id}"
        return self.mutation(
            device,
            event_id,
            TicketWrite(ticket_id, artifact_id, self.ticket_bytes(ticket_id, title, artifact_id)),
            expected_base=device.store._head(),
        )

    def mutation(self, device, event_id, *operations, expected_base=None):
        return ArtifactMutation(
            event_id=event_id,
            actor_type="pm",
            device_id=f"device-{device.name}",
            provider="codex" if device.name.startswith("a") else "claude",
            expected_base=expected_base,
            operations=tuple(operations),
            summary=event_id,
        )

    def ticket_bytes(self, ticket_id, title, artifact_id):
        return (
            f"---\nid: {ticket_id}\nartifact_id: {artifact_id}\n"
            f"title: {title}\nstatus: backlog\n---\n\n"
            f"## Description\n\n{title}\n"
        ).encode()

    def make_dirty_source_fixture(self, repo):
        remote = self.run_git(repo, "remote", "get-url", "origin")
        self.run_git(repo, "push", "-q", "origin", "main")
        (repo / "ahead.txt").write_text("ahead\n")
        self.commit_source(repo, "local ahead")
        (repo / "source.txt").write_text("unstaged\n")
        (repo / "staged.txt").write_text("staged\n")
        self.run_git(repo, "add", "staged.txt")
        (repo / "untracked.txt").write_text("untracked\n")

    def source_snapshot(self, repo):
        index_path = Path(self.run_git(repo, "rev-parse", "--git-path", "index"))
        if not index_path.is_absolute():
            index_path = repo / index_path
        refs = [
            line
            for line in self.run_git(repo, "show-ref", allow=(0, 1)).splitlines()
            if not line.endswith(f" {ARTIFACT_REF}")
            and not line.endswith("/relay/artifacts")
            and "refs/relay-runner/sync/" not in line
        ]
        files = {}
        for path in repo.rglob("*"):
            if path.is_file() and ".git" not in path.parts and ".orchestrator" not in path.parts:
                files[path.relative_to(repo).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
        return {
            "head": self.run_git(repo, "rev-parse", "HEAD"),
            "status": self.run_git(repo, "status", "--porcelain=v1", "--untracked-files=all"),
            "refs": sorted(refs),
            "remotes": self.run_git(repo, "remote", "-v"),
            "index": hashlib.sha256(index_path.read_bytes()).hexdigest(),
            "files": dict(sorted(files.items())),
        }

    def commit_source(self, repo, message):
        self.run_git(repo, "add", "-A")
        self.run_git(
            repo,
            "-c",
            "user.name=Relay Sync Tests",
            "-c",
            "user.email=relay-sync@example.invalid",
            "commit",
            "-q",
            "-m",
            message,
        )

    def commit_tree(self, repo, tree, parent, message):
        process = subprocess.run(
            ["git", "-C", str(repo), "commit-tree", tree, "-p", parent],
            input=message.encode(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                **os.environ,
                "GIT_AUTHOR_NAME": "Manual",
                "GIT_AUTHOR_EMAIL": "manual@example.invalid",
                "GIT_COMMITTER_NAME": "Manual",
                "GIT_COMMITTER_EMAIL": "manual@example.invalid",
            },
            check=True,
        )
        return process.stdout.decode().strip()

    def object_exists(self, repo, oid):
        process = subprocess.run(
            ["git", "-C", str(repo), "cat-file", "-e", oid],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        return process.returncode == 0

    def is_ancestor(self, ancestor, descendant, repo):
        return subprocess.run(
            ["git", "-C", str(repo), "merge-base", "--is-ancestor", ancestor, descendant],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        ).returncode == 0

    def run_git(self, repo, *arguments, allow=(0,)):
        command = ["git"]
        if repo is not None:
            command.extend(["-C", str(repo)])
        command.extend(arguments)
        process = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertIn(
            process.returncode,
            allow,
            msg=f"{' '.join(command)} failed: {process.stderr.decode()}",
        )
        return process.stdout.decode().strip()


def re_sub_line(content, key, replacement):
    lines = content.splitlines()
    for index, line in enumerate(lines):
        if line.strip().startswith(f"{key} ="):
            lines[index] = replacement
            break
    else:
        lines.append(replacement)
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    unittest.main()
