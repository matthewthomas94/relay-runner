import hashlib
import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from tests import test_artifact_migration as migration_fixtures
from services.artifact_history_cli import remote_store, show
from services.artifact_retention import ArchiveRemoteConfirmation, _configured_remote_urls
from services.artifact_rollout import ArtifactRolloutStore, PROJECT_OPT_IN
from services.artifact_store import ArtifactMutation, ArtifactStore, ConfigWrite
from services.automatic_retention import (
    prepare_project_retention, retention_registry_revision, sweep_automatic_retention,
)


class ProjectRetentionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = migration_fixtures.ArtifactMigrationTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        f = self.fixture
        self.rollout = ArtifactRolloutStore(f.state)
        self.remote = f.root / "archive.git"
        f.git(f.root, "init", "--bare", "-q", str(self.remote))
        f.git(f.repo, "remote", "add", "origin", str(self.remote))

        def confirm(store, remote_name, *, exposure_confirmed):
            self.assertTrue(exposure_confirmed)
            fetch, push = _configured_remote_urls(store, remote_name)
            return ArchiveRemoteConfirmation(
                service="github", remote_name=remote_name, exposure_confirmed=True,
                remote_url_sha256=hashlib.sha256(fetch.encode()).hexdigest(),
                push_url_sha256=hashlib.sha256(push.encode()).hexdigest(),
            )
        # Only substitute the GitHub hostname check. Migration, publication,
        # verification and deletion all use actual disposable Git repositories.
        substitute = patch("services.automatic_retention.confirm_github_remote", side_effect=confirm)
        substitute.start()
        self.addCleanup(substitute.stop)

    def seed(self, count):
        f = self.fixture
        root = f.repo / ".orchestrator"
        oldest = root / "RR-1.md"
        if "activity_at:" not in oldest.read_text():
            oldest.write_text(oldest.read_text().replace(
                "status: done\n", "status: done\nactivity_at: 2025-01-01T00:00:00Z\n",
            ))
        for i in range(3, count + 2):
            # One valid older writer omitted canceled; it must migrate without
            # requiring a person to repair a ticket just to run housekeeping.
            canceled = "" if i == 3 else "canceled: false\n"
            (root / f"RR-{i}.md").write_text(
                f"---\nid: RR-{i}\ntitle: Completed work {i}\nstatus: done\n"
                f"priority: medium\nrun_id: null\ndepends_on: []\n{canceled}"
                f"activity_at: 2026-01-01T00:00:{i:02d}Z\n---\n\n"
                f"## Description\n\nA findable record of completed work {i}.\n"
            )
        (root / "config.toml").write_text(f'prefix = "RR"\nnext_id = {count + 2}\n')

    def prepare(self):
        f = self.fixture
        return prepare_project_retention(
            f.repo, f.state, registry_path=f.registry, rollout=self.rollout,
        )

    def test_new_project_and_25_or_fewer_completed_tickets_are_untouched(self):
        f = self.fixture
        for count in (24, 25):
            with self.subTest(count=count):
                self.seed(count)
                before = f._repository_snapshot(f.repo)
                self.assertEqual(self.prepare()["retained"], count)
                self.assertEqual(f._repository_snapshot(f.repo), before)
                self.assertFalse((f.state / "artifacts").exists())
        empty = f.root / "new-project"
        empty.mkdir()
        f.git(empty, "init", "--initial-branch=main", "-q")
        f._write_registry(empty)
        self.assertEqual(prepare_project_retention(
            empty, f.state, registry_path=f.registry, rollout=self.rollout,
        )["retained"], 0)
        self.assertFalse((empty / ".orchestrator").exists())
        self.assertEqual(f.git(empty, "status", "--porcelain"), "")

    def test_existing_project_automatically_migrates_backs_up_and_removes_only_excess(self):
        f = self.fixture
        self.seed(26)
        f._make_dirty_source_state(f.repo)
        unrelated = f._unrelated_state(f.repo)
        self.assertIsNone(self.prepare())  # No enable command or UI action.
        store = ArtifactStore(f.repo, f.project_id, f.state, enabled=True)
        result = sweep_automatic_retention(store)
        self.assertEqual(result["ticket_ids"], ["RR-1"])
        self.assertEqual(len(list((f.repo / ".orchestrator").glob("*.md"))), 26)
        self.assertTrue((f.repo / ".orchestrator/RR-2.md").exists())  # Unfinished.
        self.assertFalse((f.repo / ".orchestrator/attachments/RR-1").exists())
        self.assertEqual(f._unrelated_state(f.repo), unrelated)
        with remote_store(f.repo, "origin") as reader:
            detail = show(reader, "RR-1")
            self.assertEqual(detail["availability"], "available")
            self.assertIn("Legacy evidence", detail["markdown"])
            self.assertEqual(len(detail["attachments"]), 1)
        head = store._head()
        self.assertIsNone(self.prepare())
        self.assertEqual(sweep_automatic_retention(store)["state"], "clean")
        self.assertEqual(store._head(), head)

    def test_first_publication_failure_retries_automatically_with_files_preserved(self):
        f = self.fixture
        self.seed(26)
        with patch("services.automatic_retention.ArtifactSyncEngine.publish_initial", side_effect=OSError("offline")):
            with self.assertRaisesRegex(OSError, "offline"):
                self.prepare()
        root = f.repo / ".orchestrator"
        self.assertEqual(len(list(root.glob("*.md"))), 27)
        self.assertNotIn("automatic_retention = true", (root / "config.toml").read_text())
        self.assertIsNone(self.prepare())
        store = ArtifactStore(f.repo, f.project_id, f.state, enabled=True)
        self.assertEqual(sweep_automatic_retention(store)["ticket_ids"], ["RR-1"])

    def test_missing_remote_and_paused_rollout_preserve_legacy_files(self):
        f = self.fixture
        self.seed(26)
        f.git(f.repo, "remote", "remove", "origin")
        before = f._repository_snapshot(f.repo)
        self.assertEqual(self.prepare()["state"], "waiting_for_remote")
        self.assertEqual(f._repository_snapshot(f.repo), before)
        f.git(f.repo, "remote", "add", "origin", str(self.remote))
        self.rollout.pause_cohort(
            PROJECT_OPT_IN, writers_drained=True, sync_frozen=True, reason_code="cas_failure",
        )
        self.assertEqual(self.prepare()["state"], "disabled")
        self.assertFalse((f.state / "artifacts").exists())

    def test_ambiguous_remotes_do_not_publish_and_selected_remote_is_honored(self):
        f = self.fixture
        self.seed(26)
        f.git(f.repo, "remote", "rename", "origin", "first")
        f.git(f.repo, "remote", "add", "second", str(self.remote))
        with self.assertRaisesRegex(Exception, "multiple destinations"):
            self.prepare()
        self.assertFalse((f.state / "artifacts").exists())
        document = json.loads(f.registry.read_text())
        document["projects"][0]["remote"]["remoteName"] = "second"
        f.registry.write_text(json.dumps(document))
        with patch("services.automatic_retention.ArtifactMigrationCoordinator.migrate", autospec=True, side_effect=RuntimeError("selected")) as migration:
            with self.assertRaisesRegex(RuntimeError, "selected"):
                self.prepare()
            self.assertEqual(migration.call_args.args[0].remote_name, "second")

    def test_registry_wakeup_tracks_open_add_create_but_ignores_access_refresh(self):
        f = self.fixture
        document = json.loads(f.registry.read_text())
        first = retention_registry_revision(f.registry)
        document["projects"][0]["last_resolved_at"] = "2026-09-16T00:00:00Z"
        document["projects"][0]["updated_at"] = "2026-09-16T00:00:00Z"
        f.registry.write_text(json.dumps(document))
        self.assertEqual(retention_registry_revision(f.registry), first)
        for project_id in ("added-project", "created-project"):
            document["projects"].append({
                "project_id": project_id, "availability": "available",
                "last_resolved_path": str(f.root / project_id),
            })
            f.registry.write_text(json.dumps(document))
            current = retention_registry_revision(f.registry)
            self.assertNotEqual(current, first)
            first = current
        document["active_project_id"] = "added-project"
        f.registry.write_text(json.dumps(document))
        self.assertNotEqual(retention_registry_revision(f.registry), first)

    def test_new_project_without_source_commit_archives_after_a_remote_is_added(self):
        f = self.fixture
        self.seed(26)
        new_repo = f.root / "newly-created"
        new_repo.mkdir()
        f.git(new_repo, "init", "--initial-branch=main", "-q")
        shutil.copytree(f.repo / ".orchestrator", new_repo / ".orchestrator")
        f.repo = new_repo
        f._write_registry(new_repo)
        (new_repo / "README.md").write_text("Uncommitted project work\n")
        f.git(new_repo, "add", "README.md", ".orchestrator")
        source_index = f.git(new_repo, "ls-files", "--stage", "--", "README.md")
        self.assertEqual(self.prepare()["state"], "waiting_for_remote")
        f.git(new_repo, "remote", "add", "backup", str(self.remote))
        self.assertIsNone(self.prepare())
        store = ArtifactStore(new_repo, f.project_id, f.state, enabled=True)
        self.assertEqual(sweep_automatic_retention(store)["ticket_ids"], ["RR-1"])
        self.assertEqual(f.git(new_repo, "ls-files", "--stage", "--", "README.md"), source_index)
        self.assertEqual((new_repo / "README.md").read_text(), "Uncommitted project work\n")
        self.assertNotEqual(subprocess.run(
            ["git", "-C", str(new_repo), "rev-parse", "--verify", "HEAD"],
            capture_output=True,
        ).returncode, 0)  # Archival must not invent a source commit.
        with remote_store(new_repo, "backup") as reader:
            self.assertIn("Legacy evidence", show(reader, "RR-1")["markdown"])

    def test_existing_canonical_store_enables_its_board_writer_automatically(self):
        f = self.fixture
        self.seed(26)
        f.coordinator().migrate(confirm_source_cleanup=True)
        store = ArtifactStore(f.repo, f.project_id, f.state, enabled=True)
        snapshot = store.snapshot()
        config = snapshot.files[".orchestrator/config.toml"].decode().replace(
            'artifact_lifecycle = "enabled"', 'artifact_lifecycle = "legacy"',
        )
        store.mutate(ArtifactMutation(
            event_id="existing-canonical-store", actor_type="system", device_id="test",
            expected_base=snapshot.commit_id, operations=(ConfigWrite(config.encode()),),
        ))
        self.assertIsNone(self.prepare())
        self.assertIn('artifact_lifecycle = "enabled"', (f.repo / ".orchestrator/config.toml").read_text())
        self.assertEqual(sweep_automatic_retention(store)["ticket_ids"], ["RR-1"])

    def test_interrupted_cleanup_recovers_even_when_projection_is_temporarily_absent(self):
        f = self.fixture
        self.seed(26)
        self.prepare()
        store = ArtifactStore(f.repo, f.project_id, f.state, enabled=True)
        replace = os.replace

        def interrupt(source, destination):
            if Path(destination) == store.materialized_path and Path(source).name.startswith(".relay-materialization-"):
                raise OSError("interrupted projection swap")
            return replace(source, destination)

        with patch("services.artifact_store.os.replace", side_effect=interrupt):
            with self.assertRaisesRegex(OSError, "interrupted projection swap"):
                sweep_automatic_retention(store)
        self.assertFalse(store.materialized_path.exists())
        self.assertTrue(store.journal_path.exists())
        self.assertIsNone(self.prepare())
        sweep_automatic_retention(store)
        self.assertEqual(len(list(store.materialized_path.glob("*.md"))), 26)
        self.assertTrue((store.materialized_path / "RR-2.md").exists())
        self.assertFalse((store.materialized_path / "RR-1.md").exists())
        self.assertFalse(store.journal_path.exists())


if __name__ == "__main__":
    unittest.main()
