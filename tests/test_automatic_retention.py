import hashlib
import subprocess
import sys
import unittest
from datetime import timedelta
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services"))

from tests import test_artifact_retention as fixtures
from services.artifact_history_cli import remote_store, search, show
from services.artifact_retention import ArchiveRemoteConfirmation, _configured_remote_urls
from services.artifact_store import ARTIFACT_REF, ArtifactStore
from services.automatic_retention import enable_automatic_retention, sweep_automatic_retention


class AutomaticRetentionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.ArtifactRetentionTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.store = self.fixture.store

        def confirm(store, remote_name, *, exposure_confirmed):
            self.assertTrue(exposure_confirmed)
            fetch, push = _configured_remote_urls(store, remote_name)
            return ArchiveRemoteConfirmation(
                service="github", remote_name=remote_name,
                remote_url_sha256=hashlib.sha256(fetch.encode()).hexdigest(),
                push_url_sha256=hashlib.sha256(push.encode()).hexdigest(),
                exposure_confirmed=True,
            )
        # Exercise real Git against a disposable bare remote. Only the GitHub
        # hostname requirement is replaced; destination binding is still checked.
        self.confirm = patch("services.automatic_retention.confirm_github_remote", side_effect=confirm)
        self.confirm.start()
        self.addCleanup(self.confirm.stop)

    def seed(self):
        f = self.fixture
        f.write_ticket_batch([
            (f"RR-{i:03d}", f"Completed task {i}", f.now + timedelta(seconds=i),
             {"status": "done"}) for i in range(27)
        ] + [
            ("RR-open", "Unfinished", f.now, {"status": "backlog"}),
            ("RR-working", "Still working", f.now, {"status": "in_progress"}),
        ], event_id="seed-automatic")

    def test_disabled_and_failed_backup_preserve_every_local_ticket_then_retry_cleans(self):
        self.seed()
        self.assertEqual(sweep_automatic_retention(self.store)["state"], "disabled")
        enable_automatic_retention(self.store, "origin")
        before = self.store.snapshot()
        with patch("services.automatic_retention.ArtifactSyncEngine.sync_confirmed", side_effect=OSError("offline")):
            with self.assertRaisesRegex(OSError, "offline"):
                sweep_automatic_retention(self.store)
        self.assertEqual(self.store.snapshot().files, before.files)
        self.assertEqual(self.store._head(), before.commit_id)
        result = sweep_automatic_retention(self.store)
        self.assertEqual(result["state"], "archived")
        self.assertEqual(set(result["ticket_ids"]), {"RR-000", "RR-001"})
        tickets = list((self.fixture.repo / ".orchestrator").glob("*.md"))
        self.assertEqual(len(tickets), 27)  # 25 completed plus both unfinished.
        for ticket_id in ["RR-open", "RR-working", "RR-026"]:
            self.assertTrue((self.fixture.repo / f".orchestrator/{ticket_id}.md").exists())
        head = self.store._head()
        self.assertEqual(sweep_automatic_retention(self.store)["state"], "clean")
        self.assertEqual(self.store._head(), head)
        self.fixture.write_ticket("RR-027", "New completion", activity_at=self.fixture.now + timedelta(seconds=100), extra={"status": "done"})
        self.assertEqual(sweep_automatic_retention(self.store)["ticket_ids"], ["RR-002"])
        self.assertEqual(len(list((self.fixture.repo / ".orchestrator").glob("*.md"))), 27)

    def test_new_agent_recovers_and_searches_remote_history_without_restoring_old_ticket(self):
        self.seed()
        enable_automatic_retention(self.store, "origin")
        sweep_automatic_retention(self.store)
        reader = self.fixture.root / "fresh-agent"
        reader.mkdir()
        def git(*args):
            return subprocess.run(["git", "-C", str(reader), *args], check=True, capture_output=True)
        git("init", "-q", "--initial-branch=main")
        git("-c", "user.name=Agent", "-c", "user.email=agent@example.invalid",
            "commit", "--allow-empty", "-qm", "source")
        git("remote", "add", "origin", str(self.fixture.remote))
        with remote_store(reader, "origin") as archive:
            self.assertEqual(show(archive, "RR-000")["availability"], "available")
            self.assertEqual(len(search(archive, "Completed task 0")), 1)
        self.assertFalse((reader / ".orchestrator").exists())
        git("fetch", "--no-tags", "origin", f"{ARTIFACT_REF}:{ARTIFACT_REF}")
        fresh = ArtifactStore(reader, self.store.project_id, self.fixture.root / "fresh-state", enabled=True)
        fresh.recover()
        self.assertFalse((reader / ".orchestrator/RR-000.md").exists())
        results = search(fresh, "Completed task 0")
        self.assertEqual([item["ticket_id"] for item in results], ["RR-000"])
        detail = show(fresh, "RR-000")
        self.assertEqual(detail["availability"], "available")
        self.assertIn("Completed task 0", detail["markdown"])
        self.assertIn("/blob/", detail["github_url"])
        self.assertFalse(detail["materialized"])
        self.assertEqual(len(search(fresh, "artifact-RR-000", full_text=True)), 1)
        self.assertFalse((reader / ".orchestrator/RR-000.md").exists())

    def test_changed_remote_does_not_reauthorize_automatically(self):
        self.seed()
        enable_automatic_retention(self.store, "origin")
        before = self.store._head()
        self.fixture.git("remote", "set-url", "--push", "origin", str(self.fixture.root / "other.git"))
        with self.assertRaisesRegex(Exception, "destination changed"):
            sweep_automatic_retention(self.store)
        self.assertEqual(self.store._head(), before)
        self.assertEqual(len(list((self.fixture.repo / ".orchestrator").glob("*.md"))), 29)
