from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ROOT / "services"
sys.path.insert(0, str(SERVICES))

from artifact_migration import (  # noqa: E402
    ArtifactMigrationBlocked,
    ArtifactMigrationCoordinator,
    ArtifactMigrationInjectedFailure,
)
from artifact_store import ARTIFACT_REF, ArtifactStore  # noqa: E402


class ArtifactMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-migration-tests-")
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.state = self.root / "state"
        self.registry = self.state / "projects/registry-v2.json"
        self.runs = self.state / "runs.db"
        self.project_id = "migration-project"
        self._make_legacy_repo(self.repo)
        self._write_registry(self.repo)

    def tearDown(self):
        self.temporary.cleanup()

    def coordinator(self, repo: Path | None = None, **kwargs) -> ArtifactMigrationCoordinator:
        return ArtifactMigrationCoordinator(
            repo or self.repo,
            kwargs.pop("project_id", self.project_id),
            kwargs.pop("state_root", self.state),
            registry_path=kwargs.pop("registry_path", self.registry),
            runs_db_path=kwargs.pop("runs_db_path", self.runs),
            graphify_path=kwargs.pop("graphify_path", None),
            device_id=kwargs.pop("device_id", "migration-test-device"),
            **kwargs,
        )

    def test_preview_is_read_only_and_records_complete_manifest_identity_and_source_state(self):
        self._make_dirty_source_state(self.repo)
        before = self._repository_snapshot(self.repo)

        preview = self.coordinator().preview()

        after = self._repository_snapshot(self.repo)
        self.assertTrue(preview.can_migrate, preview.blockers)
        self.assertEqual(before, after)
        self.assertEqual(preview.source_branch, "main")
        self.assertEqual(preview.default_branch, "main")
        self.assertEqual(preview.registry_record["project_id"], self.project_id)
        self.assertIn(".orchestrator/RR-1.md", preview.manifest["files"])
        self.assertIn(".orchestrator/attachments/RR-1/proof.png", preview.manifest["files"])
        self.assertEqual(preview.manifest["referenced_attachments"]["RR-1"], ["attachments/RR-1/proof.png"])
        self.assertEqual(preview.manifest["dependencies"]["RR-2"], ["RR-1"])
        self.assertEqual(preview.remote["state"], "not_configured")
        self.assertFalse((self.state / "artifacts" / self.project_id).exists())

    def test_local_only_migration_isolated_cutover_round_trips_and_resumes_idempotently(self):
        self._make_dirty_source_state(self.repo)
        unrelated_before = self._unrelated_state(self.repo)
        source_before = self.git(self.repo, "rev-parse", "HEAD")
        registry_before = self.registry.read_bytes()

        result = self.coordinator().migrate(confirm_source_cleanup=True)

        self.assertEqual(result.stage, "complete")
        self.assertEqual(result.remote_result["mode"], "local_only")
        self.assertNotEqual(result.source_commit, source_before)
        self.assertEqual(unrelated_before, self._unrelated_state(self.repo))
        self.assertEqual(self.git(self.repo, "symbolic-ref", "--short", "HEAD"), "main")
        self.assertEqual(self.git(self.repo, "rev-list", "--parents", "-n", "1", ARTIFACT_REF).count(" "), 0)
        self.assertEqual(self.git(self.repo, "ls-tree", "-r", "--name-only", "HEAD", "--", ".orchestrator"), "")
        materialized = self.repo / ".orchestrator"
        config = (materialized / "config.toml").read_text()
        self.assertIn('project_id = "migration-project"', config)
        self.assertIn('artifact_lifecycle = "enabled"', config)
        self.assertIn('remote_sync = "local_only"', config)
        ticket = (materialized / "RR-1.md").read_text()
        self.assertIn("artifact_id: ticket-", ticket)
        self.assertIn("activity_at:", ticket)
        self.assertIn("## Run log\n\n- attempt 7 reviewed", ticket)
        self.assertEqual(
            (materialized / "attachments/RR-1/proof.png").read_bytes(),
            self._png(),
        )
        journal = json.loads(Path(result.journal_path).read_text())
        self.assertEqual(journal["artifact_commit"], result.artifact_commit)
        self.assertEqual(journal["source_commit"], result.source_commit)
        self.assertEqual(journal["manifest_digest"], result.manifest_digest)
        self.assertTrue(Path(journal["registry_backup"]).exists())
        self.assertFalse(journal["retention_preview"]["committed"])
        self.assertTrue(journal["rollback"]["artifact_ref_retained"])
        self.assertNotEqual(self.registry.read_bytes(), registry_before)
        second = self.coordinator().migrate(confirm_source_cleanup=True)
        self.assertTrue(second.idempotent)
        self.assertEqual(second.artifact_commit, result.artifact_commit)
        self.assertEqual(second.source_commit, result.source_commit)

    def test_preflight_refuses_every_unsafe_legacy_and_active_run_condition_without_repo_mutation(self):
        cases = []

        malformed = self.root / "malformed"
        self._make_legacy_repo(malformed)
        (malformed / ".orchestrator/RR-1.md").write_text("not a ticket\n")
        cases.append((malformed, "legacy_tree"))

        missing = self.root / "missing"
        self._make_legacy_repo(missing)
        (missing / ".orchestrator/attachments/RR-1/proof.png").unlink()
        cases.append((missing, "legacy_tree"))

        symlinked = self.root / "symlinked"
        self._make_legacy_repo(symlinked)
        (symlinked / ".orchestrator/attachments/RR-1/proof.png").unlink()
        (symlinked / ".orchestrator/attachments/RR-1/proof.png").symlink_to(
            symlinked / "source.txt"
        )
        cases.append((symlinked, "legacy_tree"))

        for index, (repo, blocker_kind) in enumerate(cases):
            registry = self.root / f"registry-{index}.json"
            self._write_registry(repo, registry_path=registry)
            before = self._repository_snapshot(repo)
            coordinator = self.coordinator(repo, registry_path=registry)
            preview = coordinator.preview()
            self.assertIn(blocker_kind, {item["kind"] for item in preview.blockers})
            with self.assertRaises(ArtifactMigrationBlocked):
                coordinator.migrate(confirm_source_cleanup=True)
            self.assertEqual(before, self._repository_snapshot(repo))
            self.assertIsNone(self.optional_git(repo, "rev-parse", "--verify", ARTIFACT_REF))

        self._write_runs(self.runs, state="Running")
        before = self._repository_snapshot(self.repo)
        preview = self.coordinator().preview()
        self.assertIn("active_runs", {item["kind"] for item in preview.blockers})
        with self.assertRaises(ArtifactMigrationBlocked):
            self.coordinator().migrate(confirm_source_cleanup=True)
        self.assertEqual(before, self._repository_snapshot(self.repo))
        self.assertIsNone(self.optional_git(self.repo, "rev-parse", "--verify", ARTIFACT_REF))

    def test_interruption_after_bootstrap_resumes_without_duplicate_commit(self):
        def fail(stage: str) -> None:
            if stage == "after_artifact_bootstrap":
                raise RuntimeError("power loss")

        with self.assertRaises(ArtifactMigrationInjectedFailure):
            self.coordinator(failure_injector=fail).migrate(confirm_source_cleanup=True)
        artifact = self.git(self.repo, "rev-parse", ARTIFACT_REF)
        self.assertEqual(
            json.loads(self.coordinator().journal_path.read_text())["stage"],
            "bootstrap_verified",
        )
        self.assertNotEqual(self.git(self.repo, "ls-tree", "-r", "--name-only", "HEAD", "--", ".orchestrator"), "")

        resumed = self.coordinator().migrate(confirm_source_cleanup=True)

        self.assertEqual(resumed.stage, "complete")
        self.assertEqual(
            self.git(self.repo, "rev-list", "--count", ARTIFACT_REF),
            "1",
        )
        self.assertEqual(resumed.artifact_commit, artifact)

    def test_rollback_after_cutover_restores_exact_legacy_tree_in_new_commit_and_retains_ref(self):
        self._make_dirty_source_state(self.repo)
        unrelated_before = self._unrelated_state(self.repo)
        legacy_before = self._tree_bytes(self.repo / ".orchestrator")
        registry_before = self.registry.read_bytes()
        migrated = self.coordinator().migrate(confirm_source_cleanup=True)
        artifact_before = self.git(self.repo, "rev-parse", ARTIFACT_REF)

        rollback = self.coordinator().rollback()

        self.assertEqual(rollback.stage, "rolled_back")
        self.assertTrue(rollback.artifact_ref_retained)
        self.assertEqual(self.git(self.repo, "rev-parse", ARTIFACT_REF), artifact_before)
        self.assertEqual(self._tree_bytes(self.repo / ".orchestrator"), legacy_before)
        self.assertEqual(self.registry.read_bytes(), registry_before)
        self.assertEqual(unrelated_before, self._unrelated_state(self.repo))
        self.assertNotEqual(rollback.source_commit, migrated.source_commit)
        self.assertIn(
            "Relay-Migration-Rollback:",
            self.git(self.repo, "show", "-s", "--format=%B", rollback.source_commit),
        )
        self.assertEqual(self.coordinator().rollback().idempotent, True)

    def test_remote_first_push_is_explicit_normal_and_never_publishes_source(self):
        remote = self.root / "remote.git"
        subprocess.run(["git", "init", "--bare", "--quiet", str(remote)], check=True)
        self.git(self.repo, "remote", "add", "origin", str(remote))
        self._write_registry(self.repo, remote_name="origin", remote_mode="enabled")

        result = self.coordinator().migrate(
            confirm_source_cleanup=True,
            confirm_first_push=True,
        )

        remote_artifact = self.git_dir(remote, "rev-parse", ARTIFACT_REF)
        self.assertEqual(remote_artifact, result.artifact_commit)
        self.assertEqual(result.remote_result["force"], False)
        self.assertFalse(result.remote_result["source_ref_published"])
        self.assertIsNone(self.optional_git_dir(remote, "rev-parse", "refs/heads/main"))

    def test_verified_same_project_remote_ref_is_adopted_without_force_or_source_publication(self):
        remote = self.root / "adoption.git"
        subprocess.run(["git", "init", "--bare", "--quiet", str(remote)], check=True)
        publisher = self.root / "publisher"
        publisher_state = self.root / "publisher-state"
        publisher_registry = publisher_state / "projects/registry-v2.json"
        self._make_legacy_repo(publisher, explicit_activity=True)
        self.git(publisher, "remote", "add", "origin", str(remote))
        self._write_registry(
            publisher,
            registry_path=publisher_registry,
            remote_name="origin",
            remote_mode="enabled",
        )
        published = self.coordinator(
            publisher,
            state_root=publisher_state,
            registry_path=publisher_registry,
            runs_db_path=publisher_state / "runs.db",
        ).migrate(confirm_source_cleanup=True, confirm_first_push=True)

        consumer = self.root / "consumer"
        consumer_state = self.root / "consumer-state"
        consumer_registry = consumer_state / "projects/registry-v2.json"
        self._make_legacy_repo(consumer, explicit_activity=True)
        self.git(consumer, "remote", "add", "origin", str(remote))
        self._write_registry(
            consumer,
            registry_path=consumer_registry,
            remote_name="origin",
            remote_mode="enabled",
        )

        adopted = self.coordinator(
            consumer,
            state_root=consumer_state,
            registry_path=consumer_registry,
            runs_db_path=consumer_state / "runs.db",
        ).migrate(confirm_source_cleanup=True)

        self.assertEqual(adopted.artifact_commit, published.artifact_commit)
        self.assertEqual(adopted.remote_result["state"], "pushed_current_head")
        journal = json.loads(Path(adopted.journal_path).read_text())
        self.assertTrue(journal["artifact_adopted"])
        self.assertEqual(self.git_dir(remote, "rev-parse", ARTIFACT_REF), adopted.artifact_commit)

    def test_unconfirmed_remote_stays_local_only_and_foreign_ref_is_never_adopted(self):
        remote = self.root / "remote.git"
        subprocess.run(["git", "init", "--bare", "--quiet", str(remote)], check=True)
        self.git(self.repo, "remote", "add", "origin", str(remote))
        self._write_registry(self.repo, remote_name="origin", remote_mode="enabled")
        local = self.coordinator().migrate(confirm_source_cleanup=True, confirm_first_push=False)
        self.assertEqual(local.remote_result["mode"], "local_only")
        self.assertIsNone(self.optional_git_dir(remote, "rev-parse", ARTIFACT_REF))

        foreign_repo = self.root / "foreign-source"
        foreign_repo.mkdir()
        self.git(foreign_repo, "init", "--initial-branch=main", "--quiet")
        (foreign_repo / "source.txt").write_text("foreign\n")
        self.git(foreign_repo, "add", "source.txt")
        self.commit(foreign_repo, "foreign source")
        foreign_store = ArtifactStore(
            foreign_repo,
            "foreign-project",
            self.root / "foreign-state",
            enabled=True,
        )
        foreign_store.initialize(device_id="foreign-device")
        self.git(foreign_repo, "remote", "add", "target", str(remote))
        self.git(foreign_repo, "push", "target", f"{ARTIFACT_REF}:{ARTIFACT_REF}")

        victim = self.root / "victim"
        victim_state = self.root / "victim-state"
        victim_registry = victim_state / "projects/registry-v2.json"
        self._make_legacy_repo(victim)
        self.git(victim, "remote", "add", "origin", str(remote))
        self._write_registry(
            victim,
            registry_path=victim_registry,
            state_root=victim_state,
            remote_name="origin",
            remote_mode="enabled",
        )
        before_head = self.git(victim, "rev-parse", "HEAD")
        coordinator = self.coordinator(
            victim,
            state_root=victim_state,
            registry_path=victim_registry,
            runs_db_path=victim_state / "runs.db",
        )
        with self.assertRaisesRegex(ArtifactMigrationBlocked, "belongs to project"):
            coordinator.migrate(confirm_source_cleanup=True)
        self.assertEqual(self.git(victim, "rev-parse", "HEAD"), before_head)
        self.assertIsNone(self.optional_git(victim, "rev-parse", "--verify", ARTIFACT_REF))

    def test_codex_and_claude_produce_equivalent_artifact_snapshots(self):
        snapshots = []
        for provider in ("codex", "claude"):
            repo = self.root / provider
            state = self.root / f"{provider}-state"
            registry = state / "projects/registry-v2.json"
            self._make_legacy_repo(repo, explicit_activity=True)
            self._write_registry(repo, registry_path=registry, state_root=state)
            result = self.coordinator(
                repo,
                state_root=state,
                registry_path=registry,
                runs_db_path=state / "runs.db",
                provider=provider,
            ).migrate(confirm_source_cleanup=True)
            files = self._artifact_files(repo, result.artifact_commit)
            snapshots.append({path: _sha(content) for path, content in files.items()})
        self.assertEqual(snapshots[0], snapshots[1])

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------

    def _make_legacy_repo(self, repo: Path, *, explicit_activity: bool = False) -> None:
        repo.mkdir(parents=True)
        self.git(repo, "init", "--initial-branch=main", "--quiet")
        (repo / "source.txt").write_text("source\n")
        orchestrator = repo / ".orchestrator"
        (orchestrator / "attachments/RR-1").mkdir(parents=True)
        (orchestrator / "config.toml").write_text('prefix = "RR"\nnext_id = 3\n')
        activity = "activity_at: 2026-07-01T00:00:00Z\n" if explicit_activity else ""
        (orchestrator / "RR-1.md").write_text(
            "---\n"
            "id: RR-1\n"
            f"{activity}"
            "title: Preserve evidence\n"
            "status: done\n"
            "priority: high\n"
            "execution_mode: implementation\n"
            "depends_on: []\n"
            "run_id: 7\n"
            "canceled: false\n"
            "order: 1\n"
            "---\n\n"
            "## Description\n\nLegacy evidence.\n\n"
            "## Attachments\n\n- ![proof.png](attachments/RR-1/proof.png)\n\n"
            "## Run log\n\n- attempt 7 reviewed\n"
        )
        (orchestrator / "RR-2.md").write_text(
            "---\n"
            "id: RR-2\n"
            f"{activity}"
            "title: Preserve dependency\n"
            "status: backlog\n"
            "priority: medium\n"
            "execution_mode: implementation\n"
            "depends_on: [RR-1]\n"
            "run_id: null\n"
            "canceled: false\n"
            "order: 2\n"
            "---\n\n## Description\n\nDepends on exact RR-1 identity.\n"
        )
        (orchestrator / "attachments/RR-1/proof.png").write_bytes(self._png())
        self.git(repo, "add", "source.txt", ".orchestrator")
        self.commit(repo, "legacy source")

    def _write_registry(
        self,
        repo: Path,
        *,
        registry_path: Path | None = None,
        state_root: Path | None = None,
        remote_name: str | None = None,
        remote_mode: str = "local_only",
    ) -> None:
        del state_root
        path = registry_path or self.registry
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "schema_version": 2,
            "active_project_id": self.project_id,
            "projects": [{
                "project_id": self.project_id,
                "display_name": "Migration Fixture",
                "selected_path": str(repo),
                "last_resolved_path": str(repo.resolve()),
                "git_common_directory_fingerprint": "git-common-v1:fixture",
                "availability": "available",
                "updated_at": "2026-08-04T00:00:00Z",
                "remote": {
                    "mode": remote_mode,
                    "remoteName": remote_name,
                    "artifactRef": ARTIFACT_REF,
                },
            }],
        }))

    def _write_runs(self, path: Path, *, state: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(path)
        try:
            connection.execute(
                "CREATE TABLE runs (id INTEGER PRIMARY KEY, ticket_id TEXT, repo_path TEXT, "
                "state TEXT, attempt INTEGER, started_at REAL, ended_at REAL, activity_at REAL, "
                "provider_key TEXT, execution_mode TEXT)"
            )
            connection.execute(
                "INSERT INTO runs VALUES (1, 'RR-1', ?, ?, 1, 1, NULL, 1, 'codex', 'implementation')",
                (str(self.repo.resolve()), state),
            )
            connection.commit()
        finally:
            connection.close()

    def _make_dirty_source_state(self, repo: Path) -> None:
        (repo / "source.txt").write_text("source modified\n")
        (repo / "staged.txt").write_text("staged\n")
        (repo / "untracked.txt").write_text("untracked\n")
        self.git(repo, "add", "staged.txt")

    def _repository_snapshot(self, repo: Path) -> dict:
        index = self.git_bytes(repo, "show", ":source.txt") if self.optional_git(repo, "show", ":source.txt") is not None else b""
        index_path = Path(self.git(repo, "rev-parse", "--git-path", "index"))
        if not index_path.is_absolute():
            index_path = repo / index_path
        return {
            "head": self.git(repo, "rev-parse", "HEAD"),
            "refs": self.git(repo, "for-each-ref", "--format=%(refname) %(objectname)"),
            "status": self.git_bytes(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all"),
            "index": index_path.read_bytes(),
            "source_index": index,
            "tree": self._tree_bytes(repo / ".orchestrator"),
        }

    def _unrelated_state(self, repo: Path) -> dict:
        status = self.git_bytes(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all")
        records = sorted(
            record for record in status.split(b"\0") if record and b".orchestrator" not in record
        )
        index = self.git_bytes(repo, "ls-files", "--stage", "-z")
        index_records = sorted(
            record for record in index.split(b"\0") if record and b"\t.orchestrator/" not in record
        )
        return {"status": records, "index": index_records, "files": {
            name: (repo / name).read_bytes()
            for name in ("source.txt", "staged.txt", "untracked.txt")
            if (repo / name).exists()
        }}

    @staticmethod
    def _tree_bytes(root: Path) -> dict[str, bytes]:
        return {
            path.relative_to(root).as_posix(): path.read_bytes()
            for path in sorted(root.rglob("*"))
            if path.is_file() and not path.is_symlink()
        }

    def _artifact_files(self, repo: Path, commit: str) -> dict[str, bytes]:
        paths = self.git(repo, "ls-tree", "-r", "--name-only", commit).splitlines()
        return {path: self.git_bytes(repo, "show", f"{commit}:{path}") for path in paths}

    @staticmethod
    def _png() -> bytes:
        return b"\x89PNG\r\n\x1a\n" + b"migration-proof"

    def commit(self, repo: Path, message: str) -> None:
        self.git(
            repo,
            "-c", "user.name=Migration Tests",
            "-c", "user.email=migration@example.invalid",
            "commit", "-q", "-m", message,
        )

    @staticmethod
    def git(repo: Path, *args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            text=True,
        ).stdout.strip()

    @staticmethod
    def git_bytes(repo: Path, *args: str) -> bytes:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout

    @staticmethod
    def optional_git(repo: Path, *args: str) -> str | None:
        process = subprocess.run(
            ["git", "-C", str(repo), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        return process.stdout.strip() if process.returncode == 0 else None

    @staticmethod
    def git_dir(git_dir: Path, *args: str) -> str:
        return subprocess.run(
            ["git", f"--git-dir={git_dir}", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        ).stdout.strip()

    @staticmethod
    def optional_git_dir(git_dir: Path, *args: str) -> str | None:
        process = subprocess.run(
            ["git", f"--git-dir={git_dir}", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        return process.stdout.strip() if process.returncode == 0 else None


def _sha(content: bytes) -> str:
    import hashlib

    return hashlib.sha256(content).hexdigest()


if __name__ == "__main__":
    unittest.main()
