import copy
import base64
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from services.global_notes import GlobalNoteLibrary
from services.artifact_store import ArtifactValidationError
from services.personal_file_storage import (CATALOG_PATH, MARKER_PATH, GitHubFiles,
    PersonalFileStorage, StorageError, git_blob_id, handle_personal_storage_request)
from services.personal_notes import PersonalNoteManager

CREATED = "2026-10-11T01:00:00Z"


class FakeGitHub:
    """Immutable object/commit backend; never uses a real account or network."""
    def __init__(self):
        self.user = {"id": 23, "login": "actual-github-login", "suggested_repository": "actual-github-login-rr-files"}
        self.repository = None
        self.blobs = {}
        self.commits = {}
        self.current = None
        self.sequence = 0
        self.offline = False
        self.fail_after_publish = False
        self.created = []
        self.published = []

    def _check(self):
        if self.offline:
            raise StorageError("pending", "Offline; local files preserved")

    def account(self):
        self._check()
        return copy.deepcopy(self.user)

    def repo(self, full_name):
        self._check()
        if self.repository is None or self.repository["full_name"] != full_name:
            raise StorageError("missing", "Missing repository")
        return copy.deepcopy(self.repository)

    def api(self, method, path, body=None):
        self._check()
        if (method, path) != ("POST", "user/repos"):
            raise AssertionError((method, path))
        self.created.append(body)
        name = self.user["login"] + "/" + body["name"]
        self.repository = {"id": 101, "node_id": "R_node101", "owner": {"id": self.user["id"]},
            "full_name": name, "private": body["private"], "visibility": "private", "permissions": {"push": True},
            "default_branch": "main", "html_url": "https://github.com/" + name,
            "clone_url": "https://github.com/" + name + ".git", "description": body["description"]}
        self.current = "0" * 40
        self.commits[self.current] = {}
        return copy.deepcopy(self.repository)

    def head(self, full_name, branch):
        self.repo(full_name)
        return self.current

    def tree(self, full_name, commit):
        self.repo(full_name)
        if commit not in self.commits:
            raise StorageError("missing", "Missing immutable commit")
        return dict(self.commits[commit])

    def read_blob(self, full_name, blob, expected_size=None):
        self.repo(full_name)
        if blob not in self.blobs:
            raise StorageError("missing", "Missing blob")
        content = self.blobs[blob]
        if git_blob_id(content) != blob or (expected_size is not None and len(content) != expected_size):
            raise StorageError("conflict", "Corrupt remote blob")
        return content

    def publish(self, full_name, branch, changes, expected=None):
        self.repo(full_name)
        tree = dict(self.commits[self.current])
        for path, value in (expected or {}).items():
            if tree.get(path) not in (value, git_blob_id(changes[path])):
                raise StorageError("conflict", "Concurrent change")
        for path, content in changes.items():
            blob = git_blob_id(content)
            self.blobs[blob] = content
            tree[path] = blob
        self.sequence += 1
        self.current = f"{self.sequence:040x}"
        self.commits[self.current] = tree
        self.published.append(dict(changes))
        if self.fail_after_publish:
            self.fail_after_publish = False
            raise StorageError("pending", "Interrupted after publication")
        return self.current


class PersonalStorageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.github = FakeGitHub()
        self.now = 100_000.0
        self.storage = PersonalFileStorage(self.root, github=self.github, clock=lambda: self.now)

    def tearDown(self):
        self.storage.db.close()
        self.temporary.cleanup()

    def connect(self):
        return self.storage.configure(confirm=True)

    def document(self, content=b"personal text", **kwargs):
        return self.storage.put("doc-one", "documents/one.txt", content, **kwargs)

    def test_local_only_start_has_no_github_side_effect(self):
        self.document()
        self.assertEqual(self.storage.status()["state"], "local_only")
        self.assertEqual(self.github.created, [])
        self.assertEqual(self.github.published, [])
        self.storage.policy(budget_bytes=1, retention_days=0)
        self.assertEqual(self.storage.read("doc-one"), b"personal text")
        self.assertTrue(self.storage.status()["over_budget"])
        self.assertGreater(self.storage.status()["usage"]["unsynced_bytes"], 0)

    def test_provision_private_actual_account_and_require_explicit_enable(self):
        with self.assertRaises(StorageError):
            self.storage.configure()
        result = self.connect()
        self.assertEqual(result["destination"]["full_name"], "actual-github-login/actual-github-login-rr-files")
        self.assertTrue(self.github.created[0]["private"])
        self.assertIn(MARKER_PATH, self.github.commits[self.github.current])

    def test_existing_unrelated_private_or_public_repository_is_never_adopted(self):
        for private in (True, False):
            with self.subTest(private=private):
                self.github.api("POST", "user/repos", {"name": self.github.user["suggested_repository"], "private": private, "description": "unrelated"})
                with self.assertRaises(StorageError):
                    self.connect()
                self.assertEqual(self.github.published, [])

    def test_provision_retry_after_uncertain_create_is_safe_and_idempotent(self):
        original = self.github.api
        def interrupted(method, endpoint, body=None):
            result = original(method, endpoint, body)
            self.github.api = original
            raise StorageError("pending", "Connection interrupted after creation")
        self.github.api = interrupted
        with self.assertRaises(StorageError):
            self.connect()
        self.connect()
        self.assertEqual(len(self.github.created), 1)

    def test_approval_gate_disconnect_and_permission_loss(self):
        self.connect()
        self.document()
        self.storage.sync()
        self.assertIsNone(self.storage.reference("doc-one")["remote_commit"])
        self.storage.sync(approve=True)
        self.assertIsNotNone(self.storage.reference("doc-one")["remote_commit"])
        count = len(self.github.published)
        self.storage.disconnect()
        self.document(b"changed after disconnect")
        self.storage.sync()
        self.assertEqual(count, len(self.github.published))
        self.storage.configure(confirm=True)
        self.github.repository["permissions"]["push"] = False
        result = self.storage.sync()
        self.assertEqual(result["state"], "auth_failure")
        self.assertEqual(self.storage.read("doc-one"), b"changed after disconnect")

    def test_account_identity_url_and_privacy_changes_pause_publication(self):
        self.connect()
        self.document(approved=True)
        original = copy.deepcopy(self.github.repository)
        for key, value in (("id", 102), ("node_id", "R_replaced"), ("clone_url", "https://github.com/other/repo.git"), ("private", False)):
            self.github.repository = {**original, key: value}
            self.assertEqual(self.storage.sync()["state"], "conflict")
        self.github.repository = original
        self.github.user["id"] = 99
        self.assertEqual(self.storage.sync()["state"], "conflict")

    def test_offline_and_interrupted_upload_keep_unique_local_revision(self):
        self.connect()
        self.document()
        self.github.offline = True
        self.assertEqual(self.storage.sync(approve=True)["state"], "pending")
        self.assertEqual(self.storage.read("doc-one"), b"personal text")
        self.github.offline = False
        self.github.fail_after_publish = True
        self.storage.sync()
        self.assertIsNone(self.storage.reference("doc-one")["remote_commit"])
        self.storage.sync()
        self.assertEqual(len(self.storage.list_files()["files"]), 1)
        self.assertIsNotNone(self.storage.reference("doc-one")["remote_commit"])

    def test_exact_proof_eviction_retrieval_and_pin_active_protection(self):
        self.connect()
        self.document(b"x" * 20000)
        self.storage.put("active-one", "tasks/active.txt", b"a" * 20000, category="tasks", active=True)
        self.storage.put("pinned-one", "documents/pinned.txt", b"p" * 20000)
        self.storage.pin("pinned-one", True)
        self.storage.sync(approve=True)
        before = self.storage.usage()["total_bytes"]
        result = self.storage.policy(budget_bytes=1, retention_days=0)
        self.assertGreaterEqual(result["reclaimed_bytes"], 20000)
        self.assertLess(self.storage.usage()["total_bytes"], before)
        self.assertFalse(self.storage.reference("doc-one")["materialized"])
        self.assertTrue(self.storage.reference("active-one")["materialized"])
        self.assertTrue(self.storage.reference("pinned-one")["materialized"])
        self.assertEqual(self.storage.read("doc-one"), b"x" * 20000)
        self.assertFalse(list(self.storage.files_root.rglob("*.tmp-*")))

    def test_remote_checksum_or_commit_failure_prevents_eviction(self):
        self.connect()
        self.document()
        self.storage.sync(approve=True)
        ref = self.storage.reference("doc-one")
        self.github.blobs[ref["remote_blob"]] = b"corrupted"
        self.storage.policy(budget_bytes=1, retention_days=0)
        self.assertTrue(self.storage.reference("doc-one")["materialized"])
        self.assertEqual(self.storage.read("doc-one"), b"personal text")
        self.github.blobs[ref["remote_blob"]] = b"personal text"
        del self.github.commits[ref["remote_commit"]]
        self.storage.policy(budget_bytes=1, retention_days=0)
        self.assertTrue(self.storage.reference("doc-one")["materialized"])

    def test_remote_catalog_recovers_searchable_files_on_new_device(self):
        self.connect()
        self.document(b"remote-only", metadata={"title": "Planning notes"})
        self.storage.sync(approve=True)
        other_temp = tempfile.TemporaryDirectory()
        self.addCleanup(other_temp.cleanup)
        other = PersonalFileStorage(Path(other_temp.name), github=self.github)
        self.addCleanup(other.db.close)
        other.configure(confirm=True)
        rows = other.list_files("Planning")["files"]
        self.assertEqual(len(rows), 1)
        self.assertFalse(rows[0]["materialized"])
        self.assertEqual(other.read("doc-one"), b"remote-only")

    def test_concurrent_remote_current_revision_does_not_overwrite_local(self):
        self.connect()
        self.document(b"baseline")
        self.storage.sync(approve=True)
        other_temp = tempfile.TemporaryDirectory()
        self.addCleanup(other_temp.cleanup)
        other = PersonalFileStorage(other_temp.name, github=self.github)
        self.addCleanup(other.db.close)
        other.configure(confirm=True)
        self.document(b"device one")
        other.put("doc-one", "documents/one.txt", b"device two")
        other.sync()
        self.assertEqual(self.storage.sync()["state"], "conflict")
        self.assertEqual(self.storage.read("doc-one"), b"device one")
        self.assertEqual(other.read("doc-one"), b"device two")

    def test_task_adoption_is_durable_idempotent_and_excludes_runtime_paths(self):
        source = self.storage.files_root / "tasks/GEN-1/run/output.md"
        source.parent.mkdir(parents=True)
        source.write_text("result")
        ref = self.storage.register_file(source, artifact_id="general-one", adopt=True)
        self.assertFalse(source.exists())
        self.assertEqual(self.storage.read(ref["artifact_id"]), b"result")
        self.assertEqual(self.storage.register_file(source, artifact_id="general-one", adopt=True)["sha256"], ref["sha256"])
        for path in ("tasks/a/worker.log", "documents/.env", "documents/private.sqlite", "../secrets.txt"):
            with self.assertRaises(ValueError):
                self.storage.put("invalid", path, b"secret", category=path.split("/")[0])

    def test_local_external_change_is_preserved_on_cleanup(self):
        self.connect()
        self.document()
        self.storage.sync(approve=True)
        path = self.root / self.storage.reference("doc-one")["local_path"]
        path.write_bytes(b"external edit")
        self.storage.policy(budget_bytes=1, retention_days=0)
        self.assertEqual(path.read_bytes(), b"external edit")

    def test_route_adapter_returns_provider_neutral_references(self):
        self.document()
        self.assertIsNone(handle_personal_storage_request(self.storage, "GET", "/v1/unrelated"))
        response = handle_personal_storage_request(self.storage, "POST", "/v1/personal-storage/retrieve", {"artifact_id": "doc-one"})
        self.assertEqual(response["reference"]["artifact_id"], "doc-one")

    def test_foreground_documents_are_discovered_approved_archived_and_restored(self):
        source = self.storage.files_root / "documents/draft.md"
        source.write_text("a user draft")
        rows = self.storage.list_files()["files"]
        self.assertEqual(len(rows), 1)
        identity = rows[0]["artifact_id"]
        self.assertFalse(rows[0]["approved"])
        self.assertEqual(rows[0]["logical_path"], "documents/draft.md")
        self.connect()
        self.assertEqual(self.storage.sync()["state"], "pending")
        self.assertIsNone(self.storage.reference(identity)["remote_commit"])
        self.storage.sync(approve=True)
        original = self.storage.reference(identity)["sha256"]
        self.storage.policy(budget_bytes=1, retention_days=0)
        self.assertFalse(source.exists())
        self.assertFalse(self.storage.reference(identity)["materialized"])
        self.assertEqual(self.storage.read(identity), b"a user draft")
        self.assertEqual(source.read_text(), "a user draft")
        source.write_text("an unsynchronized edit")
        self.storage.list_files()
        edited = self.storage.reference(identity)
        self.assertFalse(edited["approved"])
        self.assertNotEqual(edited["sha256"], original)
        self.storage.policy(budget_bytes=1, retention_days=0)
        self.assertEqual(source.read_text(), "an unsynchronized edit")
        self.assertEqual(self.storage.read(identity, original), b"a user draft")
        self.assertEqual(source.read_text(), "an unsynchronized edit")

    def test_document_discovery_excludes_cache_hidden_symlink_and_runtime_files(self):
        root = self.storage.files_root / "documents"
        self.document()
        for name in (".env", "trace.log", "state.sqlite", "key.pem", "a" * 64 + ".txt"):
            (root / name).write_text("excluded")
        (root / ".hidden").mkdir()
        (root / ".hidden/private.txt").write_text("excluded")
        outside = self.root / "secret.txt"
        outside.write_text("outside")
        (root / "link.txt").symlink_to(outside)
        (root / "linked-folder").symlink_to(self.root, target_is_directory=True)
        (root / "doc-one/extra.txt").write_text("cache-side operational file")
        (self.storage.files_root / "tasks").mkdir()
        (self.storage.files_root / "tasks/unreviewed.txt").write_text("not reviewed")
        self.assertEqual([row["artifact_id"] for row in self.storage.list_files()["files"]], ["doc-one"])

    def test_general_tasks_project_sync_preserves_working_files_and_git_history(self):
        project = self.root / "general-tasks"
        project.mkdir()
        source = project / "draft.md"
        source.write_text("a general project draft")
        for hidden in (".git", ".orchestrator"):
            (project / hidden).mkdir()
            (project / hidden / "private.txt").write_text("private local history")
        (project / "worker.log").write_text("private trace")
        rows = self.storage.list_files()["files"]
        self.assertEqual(len(rows), 1)
        identity = rows[0]["artifact_id"]
        self.assertEqual(rows[0]["logical_path"], "tasks/general-tasks/draft.md")
        self.assertFalse(rows[0]["approved"])
        self.connect()
        self.storage.sync()
        self.assertIsNone(self.storage.reference(identity)["remote_commit"])
        self.storage.sync(approve=True)
        original = self.storage.reference(identity)["sha256"]
        status = self.storage.policy(budget_bytes=1, retention_days=0)
        self.assertEqual(source.read_text(), "a general project draft")
        self.assertGreaterEqual(status["usage"]["protected_bytes"], source.stat().st_size)
        self.assertFalse(self.storage.reference(identity)["materialized"])
        self.assertEqual(self.storage.read(identity), b"a general project draft")
        source.write_text("unapproved new work")
        self.storage.list_files()
        self.assertFalse(self.storage.reference(identity)["approved"])
        self.assertEqual(self.storage.read(identity, original), b"a general project draft")
        self.assertEqual(source.read_text(), "unapproved new work")
        status = self.storage.policy(budget_bytes=1, retention_days=0)
        self.assertGreaterEqual(status["usage"]["protected_bytes"], source.stat().st_size)
        self.assertEqual(status["usage"]["git_object_bytes"], len("private local history"))
        for hidden in (".git", ".orchestrator"):
            self.assertTrue((project / hidden / "private.txt").exists())
        published = " ".join(path for changes in self.github.published for path in changes)
        self.assertNotIn("private.txt", published)
        self.assertNotIn("worker.log", published)

    def test_general_tasks_discovery_never_creates_project_or_follows_symlinks(self):
        project = self.root / "general-tasks"
        self.storage.list_files()
        self.assertFalse(project.exists())
        outside = self.root / "another-project"
        outside.mkdir()
        (outside / "private.md").write_text("outside the built-in project")
        project.symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.storage.list_files()["files"], [])
        project.unlink()
        project.mkdir()
        (project / "linked.md").symlink_to(outside / "private.md")
        (project / "linked-directory").symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.storage.list_files()["files"], [])

    def test_old_general_run_files_and_logs_count_as_preserved_local_content(self):
        folder = self.storage.files_root / "tasks/GEN-1/old-run"
        folder.mkdir(parents=True)
        (folder / "worker.log").write_bytes(b"private trace" * 100)
        (folder / "result.json").write_bytes(b"local result")
        status = self.storage.policy(budget_bytes=1, retention_days=0)
        expected = len(b"private trace" * 100) + len(b"local result")
        self.assertEqual(status["usage"]["unmanaged_bytes"], expected)
        self.assertGreaterEqual(status["usage"]["unsynced_bytes"], expected)
        self.assertTrue(any("traces" in reason for reason in status["overage_reasons"]))
        self.assertTrue((folder / "worker.log").exists())
        self.connect()
        self.storage.sync(approve=True)
        self.assertFalse(any("worker.log" in path or "result.json" in path for path in self.github.commits[self.github.current]))

    def test_symlink_cache_substitution_never_writes_or_reclaims_external_content(self):
        self.connect()
        self.document()
        self.storage.sync(approve=True)
        path = self.root / self.storage.reference("doc-one")["local_path"]
        outside = self.root / "outside.txt"
        outside.write_text("unique outside work")
        path.unlink()
        path.symlink_to(outside)
        with self.assertRaises(StorageError):
            self.storage.read("doc-one")
        with self.assertRaises(StorageError):
            self.storage.put("doc-one", "documents/one.txt", b"personal text")
        self.assertEqual(outside.read_text(), "unique outside work")

    def test_remote_updates_are_imported_without_losing_history_or_local_source_edits(self):
        self.connect()
        self.document(b"original")
        self.storage.sync(approve=True)
        other_temp = tempfile.TemporaryDirectory()
        self.addCleanup(other_temp.cleanup)
        other = PersonalFileStorage(other_temp.name, github=self.github)
        self.addCleanup(other.db.close)
        other.configure(confirm=True)
        other.put("doc-one", "documents/one.txt", b"other device")
        other.sync()
        self.assertEqual(self.storage.sync()["state"], "synced")
        self.assertEqual(self.storage.read("doc-one"), b"other device")
        catalog = json.loads(self.github.blobs[self.github.commits[self.github.current][CATALOG_PATH]])
        revisions = next(file for file in catalog["files"] if file["artifact_id"] == "doc-one")["versions"]
        self.assertEqual({row["sha256"] for row in revisions}, {hashlib.sha256(value).hexdigest() for value in (b"original", b"other device")})

    def test_rejected_remote_catalog_preserves_current_search_and_partial_imports(self):
        self.connect()
        original = self.document()
        self.storage.sync(approve=True)
        pristine = json.loads(self.github.blobs[self.github.commits[self.github.current][CATALOG_PATH]])
        for failure in ("missing-current", "invalid-versions", "invalid-collection"):
            with self.subTest(failure=failure):
                catalog = copy.deepcopy(pristine)
                partial = {**copy.deepcopy(catalog["files"][0]), "artifact_id": "remote-partial",
                           "logical_path": "documents/remote-partial.txt"}
                catalog["files"].insert(0, partial)
                if failure == "missing-current":
                    catalog["files"][1]["current_sha"] = "a" * 64
                    catalog["files"][1]["versions"] = []
                elif failure == "invalid-versions":
                    catalog["files"][1]["versions"] = None
                else:
                    catalog["files"] = "invalid"
                self.github.publish(self.github.repository["full_name"], "main", {CATALOG_PATH: json.dumps(catalog).encode()})
                self.assertEqual(self.storage.sync()["state"], "conflict")
                self.assertEqual(self.storage.reference("doc-one")["sha256"], original["sha256"])
                self.assertEqual([row["artifact_id"] for row in self.storage.list_files("one")["files"]], ["doc-one"])
                self.assertEqual(self.storage.read("doc-one"), b"personal text")
                self.assertIsNone(self.storage.db.execute("SELECT 1 FROM files WHERE artifact_id='remote-partial'").fetchone())
                self.assertIsNone(self.storage._get("source_path:remote-partial"))
                self.assertIsNone(self.storage._get("remote_current:remote-partial"))

    def test_rejected_remote_note_receipt_rolls_back_imported_tombstone(self):
        library = GlobalNoteLibrary(self.root, "test-device", lambda: [])
        self.storage.attach_notes(library)
        original = self.note(library)
        self.connect()
        self.storage.sync(approve=True)
        catalog = json.loads(self.github.blobs[self.github.commits[self.github.current][CATALOG_PATH]])
        catalog["notes"][0]["deleted"] = True
        catalog["note_events"].append({"event_id": "bad", "digest": "invalid"})
        self.github.publish(self.github.repository["full_name"], "main", {CATALOG_PATH: json.dumps(catalog).encode()})
        self.assertEqual(self.storage.sync()["state"], "conflict")
        self.assertEqual(len(library.list()["notes"]), 1)
        self.assertEqual(library.manager.get("N1")["note"], original["note"])
        self.assertFalse(self.storage._get("remote_note:" + original["note"]["identity"]["artifact_id"])["deleted"])

    def note(self, library, request="note", state="completed"):
        return library.manager.create(request_id=request, created_at=CREATED, capture_started_at=CREATED,
            captured_at=CREATED, recording_state=state, checkpoint_reason="complete" if state == "completed" else "checkpoint",
            capture_ended_at=CREATED if state == "completed" else None,
            segments=[{"segment_id": "seg1", "captured_at": CREATED, "text": "A stable transcript."}])

    def test_notes_migration_reclaims_real_git_objects_and_restores_identity(self):
        library = GlobalNoteLibrary(self.root, "test-device", lambda: [])
        self.storage.attach_notes(library)
        saved = self.note(library)
        code = library.list()["notes"][0]["global_code"]
        self.assertGreater(self.storage.usage()["git_object_bytes"], 0)
        self.connect()
        self.storage.sync(approve=True)
        self.assertTrue(self.storage._get("notes_migrated"))
        self.assertIsInstance(library.manager, PersonalNoteManager)
        self.assertFalse((self.root / "notes" / ".git").exists())
        self.assertEqual(self.storage.usage()["git_object_bytes"], 0)
        self.assertEqual(library.manager.get(code)["note"], saved["note"])
        retried = self.note(library)
        self.assertEqual(retried["note"]["identity"], saved["note"]["identity"])
        self.storage.policy(budget_bytes=1, retention_days=0)
        self.assertFalse(self.storage.reference(saved["note"]["identity"]["artifact_id"])["materialized"])
        restored = library.manager.get(code)
        self.assertEqual(restored["note"]["identity"], saved["note"]["identity"])
        self.assertEqual(restored["note"]["segments"], saved["note"]["segments"])
        bundle = self.storage.read("legacy-global-notes-history")
        bundle_path = self.root / "recovered.bundle"
        bundle_path.write_bytes(bundle)
        subprocess.run(["git", "clone", "--bare", str(bundle_path), str(self.root / "recovery.git")], capture_output=True, check=True)
        self.assertTrue((self.root / "recovery.git" / "objects").exists())

    def test_recording_blocks_note_migration_and_offline_archive_preserves_git(self):
        library = GlobalNoteLibrary(self.root, "test-device", lambda: [])
        self.storage.attach_notes(library)
        self.note(library, state="recording")
        self.connect()
        self.storage.sync(approve=True)
        self.assertFalse(self.storage._get("notes_migrated", False))
        self.assertTrue((self.root / "notes/.git").is_dir())

    def test_migrated_global_note_catalog_keeps_ui_route_and_sync_state(self):
        library = GlobalNoteLibrary(self.root, "test-device", lambda: [])
        self.storage.attach_notes(library)
        original = self.note(library)
        self.connect()
        self.storage.sync(approve=True)
        catalog = library.list()
        card = catalog["notes"][0]
        # Swift maps this stable route to the repository-independent notes API.
        self.assertEqual(card["repository_path"], str((self.root / "notes").resolve()))
        self.assertNotEqual(card["repository_path"], str(library.manager.store.repo_path))
        self.assertEqual(catalog["sync"]["mode"], "enabled")
        self.assertEqual(catalog["sync"]["state"], "synced")
        self.storage.policy(budget_bytes=1, retention_days=0)
        self.assertFalse(self.storage.reference(card["artifact_id"])["materialized"])
        self.assertEqual(library.manager.get(card["note_id"])["note"], original["note"])
        self.github.offline = True
        self.storage.sync()
        self.assertEqual(library.list()["sync"]["state"], "pending")
        self.storage.disconnect()
        self.assertEqual(library.list()["sync"]["mode"], "local_only")
        self.assertEqual(library.list()["sync"]["state"], "disconnected")

    def test_plain_retry_does_not_prepare_or_upload_unapproved_notes(self):
        library = GlobalNoteLibrary(self.root, "test-device", lambda: [])
        self.storage.attach_notes(library)
        self.note(library)
        self.connect()
        self.storage.sync()
        self.assertEqual(self.storage.list_files()["files"], [])
        self.assertFalse(self.storage._get("notes_migrated", False))

    def test_new_device_global_note_code_content_and_deletion_survive(self):
        library = GlobalNoteLibrary(self.root, "test-device", lambda: [])
        self.storage.attach_notes(library)
        original = self.note(library)
        self.connect()
        self.storage.sync(approve=True)
        other_temp = tempfile.TemporaryDirectory()
        self.addCleanup(other_temp.cleanup)
        other = PersonalFileStorage(other_temp.name, github=self.github)
        self.addCleanup(other.db.close)
        other_library = GlobalNoteLibrary(Path(other_temp.name), "second-device", lambda: [])
        other.attach_notes(other_library)
        other.configure(confirm=True)
        self.assertEqual(other_library.manager.get("N1")["note"], original["note"])
        identity = original["note"]["identity"]
        other_library.manager.delete(note_id=identity["note_id"], artifact_id=identity["artifact_id"], request_id="delete")
        self.assertEqual(other_library.list()["notes"], [])
        next_note = self.note(other_library, request="next")
        self.assertEqual(next_note["note"]["identity"]["note_id"], "RR-N2")

    def test_notes_cleanup_failure_recovers_without_losing_notes(self):
        library = GlobalNoteLibrary(self.root, "test-device", lambda: [])
        self.storage.attach_notes(library)
        original = self.note(library)
        self.connect()
        with patch("services.global_notes.shutil.rmtree", side_effect=OSError("interrupted cleanup")):
            self.assertEqual(self.storage.sync(approve=True)["state"], "pending")
        self.assertTrue(self.storage._get("notes_migrated"))
        self.assertTrue((self.root / "notes/.git").exists())
        self.assertEqual(library.manager.get("N1")["note"], original["note"])
        self.storage.sync()
        self.assertIsNone(self.storage._get("notes_migration_cleanup"))
        self.assertFalse((self.root / "notes").exists())
        self.assertEqual(library.manager.get("N1")["note"], original["note"])

    def test_remote_note_deletion_updates_unchanged_local_catalog(self):
        library = GlobalNoteLibrary(self.root, "test-device", lambda: [])
        self.storage.attach_notes(library)
        original = self.note(library)
        self.connect()
        self.storage.sync(approve=True)
        other_temp = tempfile.TemporaryDirectory()
        self.addCleanup(other_temp.cleanup)
        other = PersonalFileStorage(other_temp.name, github=self.github)
        self.addCleanup(other.db.close)
        other_library = GlobalNoteLibrary(Path(other_temp.name), "second-device", lambda: [])
        other.attach_notes(other_library)
        other.configure(confirm=True)
        identity = original["note"]["identity"]
        other_library.manager.delete(note_id=identity["note_id"], artifact_id=identity["artifact_id"], request_id="delete")
        self.assertEqual(other.sync()["state"], "synced")
        self.assertEqual(self.storage.sync()["state"], "synced")
        self.assertEqual(library.list()["notes"], [])

    def test_fresh_device_retries_preserve_original_notes_and_latest_revision(self):
        library = GlobalNoteLibrary(self.root, "test-device", lambda: [])
        self.storage.attach_notes(library)
        original = self.note(library)
        first_update = copy.deepcopy(original["note"])
        first_update["segments"][0]["text"] = "first update"
        library.manager.update(request_id="first", update=first_update)
        latest_update = copy.deepcopy(first_update)
        latest_update["segments"][0]["text"] = "latest update"
        library.manager.update(request_id="latest", update=latest_update)
        self.connect()
        self.storage.sync(approve=True)
        other_temp = tempfile.TemporaryDirectory()
        self.addCleanup(other_temp.cleanup)
        other = PersonalFileStorage(other_temp.name, github=self.github)
        self.addCleanup(other.db.close)
        other_library = GlobalNoteLibrary(Path(other_temp.name), "second-device", lambda: [])
        other.attach_notes(other_library)
        other.configure(confirm=True)
        retried_create = self.note(other_library)
        self.assertTrue(retried_create["idempotent"])
        self.assertEqual(retried_create["note"], original["note"])
        retried_update = other_library.manager.update(request_id="first", update=first_update)
        self.assertTrue(retried_update["idempotent"])
        self.assertEqual(retried_update["note"]["segments"][0]["text"], "first update")
        self.assertEqual(other_library.manager.get("N1")["note"]["segments"][0]["text"], "latest update")

    def test_active_personal_recording_is_never_uploaded_or_archived(self):
        library = GlobalNoteLibrary(self.root, "test-device", lambda: [])
        self.storage.attach_notes(library)
        self.storage._set("notes_migrated", True)
        self.storage.db.commit()
        original = self.note(library, state="recording")
        identity = original["note"]["identity"]
        self.connect()
        self.assertEqual(self.storage.sync(approve=True)["state"], "pending")
        self.assertIsNone(self.storage.reference(identity["artifact_id"])["remote_commit"])
        tree = self.github.commits[self.github.current]
        self.assertFalse(any(path.startswith("files/" + identity["artifact_id"] + "/") for path in tree))
        with self.assertRaises(ArtifactValidationError):
            library.manager.archive(note_id=identity["note_id"], artifact_id=identity["artifact_id"], archived_at=CREATED, request_id="archive")
        finished = copy.deepcopy(original["note"])
        finished.update(recording_state="completed", checkpoint_reason="complete", capture_ended_at=CREATED)
        library.manager.update(request_id="complete", update=finished)
        self.assertEqual(self.storage.sync(approve=True)["state"], "synced")
        self.assertIsNotNone(self.storage.reference(identity["artifact_id"])["remote_commit"])

    def test_resumed_cleanup_preserves_legacy_notes_changed_after_snapshot(self):
        library = GlobalNoteLibrary(self.root, "test-device", lambda: [])
        self.storage.attach_notes(library)
        legacy = library.manager
        self.note(library)
        self.connect()
        with patch("services.global_notes.shutil.rmtree", side_effect=OSError("interrupted cleanup")):
            self.storage.sync(approve=True)
        changed = self.note(SimpleNamespace(manager=legacy), request="post-crash")
        self.assertEqual(self.storage.sync()["state"], "pending")
        self.assertTrue((self.root / "notes/.git").exists())
        self.assertEqual(legacy.get(changed["note"]["identity"]["artifact_id"])["note"], changed["note"])

    def test_destination_change_keeps_only_remote_archived_proof(self):
        self.connect()
        self.document()
        self.storage.sync(approve=True)
        destination = self.storage.status()["destination"]
        self.storage.policy(budget_bytes=1, retention_days=0)
        self.github.repository["id"] = 999
        self.github.repository["node_id"] = "new-repo"
        with self.assertRaises(StorageError):
            self.storage.configure(confirm=True)
        self.assertEqual(self.storage.status()["destination"], destination)
        self.assertEqual(self.storage.reference("doc-one")["remote_repo"], str(destination["repository_id"]))


class GitHubTransportTests(unittest.TestCase):
    def test_append_publication_uses_tree_identity_and_rechecks_immutable_bytes(self):
        content = b"verified bytes"
        blob = git_blob_id(content)
        transport = GitHubFiles(executable="not-invoked")
        calls = []

        def api(method, endpoint, body=None):
            calls.append((method, endpoint, body))
            if endpoint.endswith("/git/ref/heads/main"):
                return {"object": {"sha": "old-commit"}}
            if endpoint.endswith("/git/commits/old-commit"):
                return {"tree": {"sha": "old-tree"}}
            if endpoint.endswith("/git/trees/old-tree?recursive=1"):
                return {"tree": []}
            if endpoint.endswith("/git/blobs"):
                return {"sha": blob}
            if endpoint.endswith("/git/trees"):
                self.assertEqual(body["base_tree"], "old-tree")
                return {"sha": "new-tree"}
            if endpoint.endswith("/git/commits"):
                self.assertEqual(body["parents"], ["old-commit"])
                return {"sha": "new-commit"}
            if endpoint.endswith("/git/refs/heads/main"):
                self.assertEqual(body, {"sha": "new-commit", "force": False})
                return {}
            if endpoint.endswith("/git/commits/new-commit"):
                return {"tree": {"sha": "new-tree"}}
            if endpoint.endswith("/git/trees/new-tree?recursive=1"):
                return {"tree": [{"path": "files/a.txt", "sha": blob, "type": "blob"}]}
            if endpoint.endswith("/git/blobs/" + blob):
                return {"sha": blob, "size": len(content), "encoding": "base64", "content": base64.b64encode(content).decode()}
            self.fail((method, endpoint, body))

        transport.api = api
        self.assertEqual(transport.publish("owner/private", "main", {"files/a.txt": content}, {"files/a.txt": None}), "new-commit")
        self.assertEqual(calls[-1][1], "repos/owner/private/git/blobs/" + blob)
        original = transport.api
        def corrupt(method, endpoint, body=None):
            result = original(method, endpoint, body)
            if endpoint.endswith("/git/blobs/" + blob):
                result["content"] = base64.b64encode(b"corrupt").decode()
            return result
        transport.api = corrupt
        with self.assertRaises(StorageError):
            transport.publish("owner/private", "main", {"files/a.txt": content}, {"files/a.txt": None})


if __name__ == "__main__":
    unittest.main()
