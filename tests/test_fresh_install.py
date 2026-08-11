from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))

from fresh_install import (  # noqa: E402
    FreshInstallCoordinator,
    FreshInstallError,
    FreshInstallInjectedFailure,
)


class FreshInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-fresh-install-tests-")
        self.root = Path(self.temporary.name)
        self.state = self.root / "Application Support/relay-runner"
        self.trash = self.root / "Trash"
        self.repo = self.root / "registered-project"
        self.source_app = self.root / "build/Relay Runner.app"
        self.destination_app = self.root / "Applications/Relay Runner.app"
        self._make_repo()
        self._make_state()
        self._make_app(self.source_app, marker=b"new-app")
        self._make_app(self.destination_app, marker=b"old-app")

    def tearDown(self):
        self.temporary.cleanup()

    def coordinator(self, **kwargs) -> FreshInstallCoordinator:
        return FreshInstallCoordinator(
            state_root=self.state,
            trash_root=self.trash,
            **kwargs,
        )

    def test_normal_reinstall_requires_execute_and_preserves_all_state_and_registered_repositories(self):
        state_before = self.tree(self.state)
        repo_before = self.repo_snapshot()
        preview = self.coordinator().preview_reinstall(
            source_app=self.source_app,
            destination_app=self.destination_app,
        )
        self.assertGreater(preview.state_files, 0)
        self.assertEqual(len(preview.registered_repositories), 1)
        with self.assertRaises(FreshInstallError):
            self.coordinator().reinstall(
                source_app=self.source_app,
                destination_app=self.destination_app,
                execute=False,
            )

        result = self.coordinator().reinstall(
            source_app=self.source_app,
            destination_app=self.destination_app,
            execute=True,
        )

        self.assertTrue(result.state_preserved)
        self.assertTrue(result.repositories_preserved)
        self.assertEqual(self.tree(self.state), state_before)
        self.assertEqual(self.repo_snapshot(), repo_before)
        self.assertEqual(
            (self.destination_app / "Contents/MacOS/relay-runner").read_bytes(),
            b"new-app",
        )
        self.assertIsNotNone(result.replaced_app_backup)
        self.assertEqual(
            (Path(result.replaced_app_backup) / "Contents/MacOS/relay-runner").read_bytes(),
            b"old-app",
        )

    def test_deliberate_reset_moves_only_owned_state_to_trash_and_restore_is_exact(self):
        state_before = self.tree(self.state)
        repo_before = self.repo_snapshot()
        with self.assertRaises(FreshInstallError):
            self.coordinator().reset_state(execute=True, confirm_daemon_stopped=False)

        result = self.coordinator().reset_state(
            execute=True,
            confirm_daemon_stopped=True,
        )

        self.assertFalse(self.state.exists())
        self.assertTrue(Path(result.trashed_state).is_dir())
        self.assertTrue(Path(result.recovery_manifest).is_file())
        self.assertEqual(self.tree(Path(result.trashed_state)), state_before)
        self.assertEqual(self.repo_snapshot(), repo_before)
        recovery = json.loads(Path(result.recovery_manifest).read_text())
        self.assertTrue(recovery["repositories_must_not_be_mutated"])

        restored = FreshInstallCoordinator.restore_reset(
            result.recovery_manifest,
            execute=True,
            confirm_daemon_stopped=True,
        )

        self.assertTrue(restored.state_preserved)
        self.assertEqual(self.tree(self.state), state_before)
        self.assertEqual(self.repo_snapshot(), repo_before)
        self.assertFalse(Path(result.trashed_state).exists())

    def test_reset_refuses_active_or_review_blocking_runs(self):
        runs = self.state / "orchestrator/runs.db"
        runs.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(runs)
        try:
            connection.execute("CREATE TABLE runs (id INTEGER PRIMARY KEY, state TEXT)")
            connection.execute("INSERT INTO runs VALUES (41, 'Reviewing')")
            connection.commit()
        finally:
            connection.close()
        before = self.tree(self.state)

        with self.assertRaisesRegex(FreshInstallError, "41"):
            self.coordinator().reset_state(
                execute=True,
                confirm_daemon_stopped=True,
            )

        self.assertEqual(self.tree(self.state), before)
        self.assertFalse(any(self.trash.glob("relay-runner-state-*")))

    def test_reset_journal_write_failure_leaves_state_in_place(self):
        state_before = self.tree(self.state)

        with patch("fresh_install._write_json_atomic", side_effect=OSError("simulated full disk")):
            with self.assertRaisesRegex(FreshInstallError, "Could not persist reset recovery journal"):
                self.coordinator().reset_state(
                    execute=True,
                    confirm_daemon_stopped=True,
                )

        self.assertEqual(self.tree(self.state), state_before)
        self.assertFalse(any(self.trash.glob("relay-runner-state-*")))

    def test_interrupted_app_replacement_restores_prior_app_and_never_changes_state_or_repo(self):
        state_before = self.tree(self.state)
        repo_before = self.repo_snapshot()

        def fail(stage: str) -> None:
            if stage == "after_app_replacement":
                raise RuntimeError("simulated crash")

        with self.assertRaises(FreshInstallInjectedFailure):
            self.coordinator(failure_injector=fail).reinstall(
                source_app=self.source_app,
                destination_app=self.destination_app,
                execute=True,
            )

        self.assertEqual(
            (self.destination_app / "Contents/MacOS/relay-runner").read_bytes(),
            b"old-app",
        )
        self.assertEqual(self.tree(self.state), state_before)
        self.assertEqual(self.repo_snapshot(), repo_before)

    def test_restore_refuses_new_state_instead_of_overwriting_it(self):
        reset = self.coordinator().reset_state(execute=True, confirm_daemon_stopped=True)
        self.state.mkdir(parents=True)
        (self.state / "new-state.txt").write_text("new\n")

        with self.assertRaisesRegex(FreshInstallError, "non-empty state"):
            FreshInstallCoordinator.restore_reset(
                reset.recovery_manifest,
                execute=True,
                confirm_daemon_stopped=True,
            )

        self.assertEqual((self.state / "new-state.txt").read_text(), "new\n")
        self.assertTrue(Path(reset.trashed_state).exists())

    def _make_repo(self) -> None:
        self.repo.mkdir()
        self.git("init", "--initial-branch=main", "--quiet")
        (self.repo / "source.txt").write_text("source\n")
        (self.repo / ".orchestrator").mkdir()
        (self.repo / ".orchestrator/config.toml").write_text('prefix = "FX"\nnext_id = 1\n')
        self.git("add", ".")
        self.git(
            "-c", "user.name=Fresh Install Tests",
            "-c", "user.email=fresh@example.invalid",
            "commit", "-q", "-m", "fixture",
        )
        (self.repo / "source.txt").write_text("dirty source\n")
        (self.repo / "untracked.txt").write_text("untracked\n")

    def _make_state(self) -> None:
        registry = self.state / "projects/registry-v2.json"
        registry.parent.mkdir(parents=True)
        registry.write_text(json.dumps({
            "schema_version": 2,
            "active_project_id": "fixture-project",
            "projects": [{
                "project_id": "fixture-project",
                "last_resolved_path": str(self.repo.resolve()),
                "availability": "available",
            }],
        }))
        (self.state / "config.toml").write_text("provider = 'codex'\n")
        (self.state / "artifacts/fixture-project").mkdir(parents=True)
        (self.state / "artifacts/fixture-project/materialization.json").write_text("{}\n")

    @staticmethod
    def _make_app(path: Path, *, marker: bytes) -> None:
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(b"plist")
        (path / "Contents/MacOS/relay-runner").write_bytes(marker)

    def repo_snapshot(self) -> dict:
        return {
            "head": self.git("rev-parse", "HEAD"),
            "refs": self.git("for-each-ref", "--format=%(refname) %(objectname)"),
            "status": self.git_bytes("status", "--porcelain=v1", "-z", "--untracked-files=all"),
            "tree": self.tree(self.repo / ".orchestrator"),
        }

    @staticmethod
    def tree(root: Path) -> dict[str, bytes]:
        return {
            path.relative_to(root).as_posix(): path.read_bytes()
            for path in sorted(root.rglob("*"))
            if path.is_file() and not path.is_symlink()
        }

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.repo), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        ).stdout.strip()

    def git_bytes(self, *arguments: str) -> bytes:
        return subprocess.run(
            ["git", "-C", str(self.repo), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout


if __name__ == "__main__":
    unittest.main()
