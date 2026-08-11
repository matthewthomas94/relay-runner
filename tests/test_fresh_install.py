from __future__ import annotations

import json
import os
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

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
        self.home = self.root / "home"
        self.tmp = self.root / "tmp"
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
        options = {
            "active_process_detector": lambda: [],
            **kwargs,
        }
        return FreshInstallCoordinator(
            state_root=self.state,
            trash_root=self.trash,
            home_root=self.home,
            temporary_root=self.tmp,
            **options,
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
            confirm_profile="relay-owned",
        )

        self.assertFalse(self.state.exists())
        self.assertTrue(Path(result.trashed_state).is_dir())
        self.assertTrue(Path(result.recovery_manifest).is_file())
        moved_state = Path(result.trashed_state) / "00-application-support"
        self.assertEqual(self.tree(moved_state), state_before)
        self.assertEqual(self.repo_snapshot(), repo_before)
        recovery = json.loads(Path(result.recovery_manifest).read_text())
        self.assertTrue(recovery["repositories_must_not_be_mutated"])

        restored = FreshInstallCoordinator.restore_reset(
            result.recovery_manifest,
            execute=True,
            confirm_daemon_stopped=True,
            confirm_profile="relay-owned",
            state_root=self.state,
            home_root=self.home,
            temporary_root=self.tmp,
            trash_root=self.trash,
        )

        self.assertTrue(restored.state_preserved)
        self.assertEqual(self.tree(self.state), state_before)
        self.assertEqual(self.repo_snapshot(), repo_before)
        self.assertFalse(moved_state.exists())

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
                confirm_profile="relay-owned",
            )

        self.assertEqual(self.tree(self.state), before)
        self.assertFalse(any(self.trash.glob("relay-runner-state-*")))

    def test_profile_journal_write_failure_leaves_state_in_place(self):
        state_before = self.tree(self.state)

        with mock.patch("fresh_install._write_json_atomic", side_effect=OSError("simulated full disk")):
            with self.assertRaisesRegex(FreshInstallError, "Could not persist reset recovery journal"):
                self.coordinator().reset_profile(
                    "relay-owned",
                    execute=True,
                    confirm_daemon_stopped=True,
                    confirm_profile="relay-owned",
                )

        self.assertEqual(self.tree(self.state), state_before)
        self.assertFalse(any(self.trash.iterdir()))

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
        reset = self.coordinator().reset_state(
            execute=True,
            confirm_daemon_stopped=True,
            confirm_profile="relay-owned",
        )
        self.state.mkdir(parents=True)
        (self.state / "new-state.txt").write_text("new\n")

        with self.assertRaisesRegex(FreshInstallError, "would overwrite state"):
            FreshInstallCoordinator.restore_reset(
                reset.recovery_manifest,
                execute=True,
                confirm_daemon_stopped=True,
                confirm_profile="relay-owned",
                state_root=self.state,
                home_root=self.home,
                temporary_root=self.tmp,
                trash_root=self.trash,
            )

        self.assertEqual((self.state / "new-state.txt").read_text(), "new\n")
        self.assertTrue(Path(reset.trashed_state).exists())

    def test_profile_restore_rejects_a_manifest_outside_its_relay_trash_backup(self):
        model = self.home / ".local/share/kokoro/kokoro-v1.0.onnx"
        model.parent.mkdir(parents=True)
        model.write_bytes(b"model")
        reset = self.coordinator().reset_profile(
            "voice-models",
            execute=True,
            confirm_daemon_stopped=True,
            confirm_profile="voice-models",
        )
        manifest = Path(reset.recovery_manifest)
        crafted_manifest = self.root / "reset-recovery.json"
        manifest.rename(crafted_manifest)

        with self.assertRaisesRegex(FreshInstallError, "expected Relay Trash backup location"):
            FreshInstallCoordinator.restore_profile(
                crafted_manifest,
                execute=True,
                confirm_daemon_stopped=True,
                confirm_profile="voice-models",
                state_root=self.state,
                home_root=self.home,
                temporary_root=self.tmp,
                trash_root=self.trash,
            )

        self.assertTrue(Path(reset.trashed_state).is_dir())

    def test_profile_restore_rejects_a_crafted_destination_outside_its_allowlist(self):
        relay_skill = self.home / ".codex/skills/relay-bridge"
        relay_skill.mkdir(parents=True)
        (relay_skill / "SKILL.md").write_text("Relay\n")
        unrelated = self.root / "unrelated-target"
        unrelated.mkdir()
        reset = self.coordinator().reset_profile(
            "provider-integrations",
            execute=True,
            confirm_daemon_stopped=True,
            confirm_profile="provider-integrations",
        )
        manifest = Path(reset.recovery_manifest)
        document = json.loads(manifest.read_text())
        document["resources"][0]["original_path"] = str(unrelated)
        manifest.write_text(json.dumps(document))

        with self.assertRaisesRegex(FreshInstallError, "do not match the declared profile allowlist"):
            FreshInstallCoordinator.restore_profile(
                manifest,
                execute=True,
                confirm_daemon_stopped=True,
                confirm_profile="provider-integrations",
                state_root=self.state,
                home_root=self.home,
                temporary_root=self.tmp,
                trash_root=self.trash,
            )

        self.assertFalse(relay_skill.exists())
        self.assertTrue(unrelated.is_dir())
        self.assertTrue(Path(document["resources"][0]["trashed_path"]).is_dir())

    def test_profile_restore_rejects_a_symlinked_backup_resource_without_moving_its_target(self):
        relay_skill = self.home / ".codex/skills/relay-bridge"
        relay_skill.mkdir(parents=True)
        (relay_skill / "SKILL.md").write_text("Relay\n")
        external = self.root / "external-target"
        external.mkdir()
        sentinel = external / "must-not-move.txt"
        sentinel.write_text("safe\n")
        reset = self.coordinator().reset_profile(
            "provider-integrations",
            execute=True,
            confirm_daemon_stopped=True,
            confirm_profile="provider-integrations",
        )
        manifest = Path(reset.recovery_manifest)
        backup = Path(json.loads(manifest.read_text())["resources"][0]["trashed_path"])
        shutil.rmtree(backup)
        backup.symlink_to(external, target_is_directory=True)

        with self.assertRaisesRegex(FreshInstallError, "resource must not be a symlink"):
            FreshInstallCoordinator.restore_profile(
                manifest,
                execute=True,
                confirm_daemon_stopped=True,
                confirm_profile="provider-integrations",
                state_root=self.state,
                home_root=self.home,
                temporary_root=self.tmp,
                trash_root=self.trash,
            )

        self.assertTrue(backup.is_symlink())
        self.assertEqual(sentinel.read_text(), "safe\n")
        self.assertFalse(relay_skill.exists())

    def test_profiles_require_exact_confirmation_and_never_include_broad_provider_paths(self):
        codex_auth = self.home / ".codex/auth.json"
        codex_auth.parent.mkdir(parents=True)
        codex_auth.write_text("credential\n")
        relay_skill = self.home / ".codex/skills/relay-bridge"
        relay_skill.mkdir(parents=True)
        (relay_skill / "SKILL.md").write_text("Relay\n")
        claude_settings = self.home / ".claude/settings.json"
        claude_settings.parent.mkdir(parents=True)
        claude_settings.write_text("credential\n")

        preview = self.coordinator().preview_profile("provider-integrations")
        names = {item["name"] for item in preview.reset_resources}
        self.assertIn("codex-relay-bridge-skill", names)
        self.assertNotIn("codex-auth", names)
        self.assertIn("Keychain credentials", preview.machine_state_not_reset)
        with self.assertRaisesRegex(FreshInstallError, "requires --execute"):
            self.coordinator().reset_profile(
                "provider-integrations",
                execute=False,
                confirm_daemon_stopped=True,
                confirm_profile="provider-integrations",
            )
        with self.assertRaisesRegex(FreshInstallError, "confirm-profile provider-integrations"):
            self.coordinator().reset_profile(
                "provider-integrations",
                execute=True,
                confirm_daemon_stopped=True,
                confirm_profile="relay-owned",
            )

        self.coordinator().reset_profile(
            "provider-integrations",
            execute=True,
            confirm_daemon_stopped=True,
            confirm_profile="provider-integrations",
        )
        self.assertFalse(relay_skill.exists())
        self.assertTrue(codex_auth.exists())
        self.assertTrue(claude_settings.exists())

    def test_profile_refuses_active_process_and_recovers_an_interrupted_move(self):
        with self.assertRaisesRegex(FreshInstallError, "active Relay processes"):
            self.coordinator(active_process_detector=lambda: ["123 /relay-runner"]).reset_profile(
                "relay-owned",
                execute=True,
                confirm_daemon_stopped=True,
                confirm_profile="relay-owned",
            )

        preference = self.home / "Library/Preferences/com.relayrunner.app.plist"
        preference.parent.mkdir(parents=True)
        preference.write_text("preferences\n")

        def fail(stage: str) -> None:
            if stage == "after_profile_move:preferences":
                raise RuntimeError("simulated interruption")

        with self.assertRaises(FreshInstallInjectedFailure):
            self.coordinator(failure_injector=fail).reset_profile(
                "relay-owned",
                execute=True,
                confirm_daemon_stopped=True,
                confirm_profile="relay-owned",
            )
        self.assertTrue(self.state.is_dir())
        self.assertEqual(preference.read_text(), "preferences\n")

    def test_profile_refuses_to_move_state_when_process_inspection_fails(self):
        preference = self.home / "Library/Preferences/com.relayrunner.app.plist"
        preference.parent.mkdir(parents=True)
        preference.write_text("preferences\n")
        state_before = self.tree(self.state)

        failed_process = subprocess.CompletedProcess(
            args=["ps", "-axo", "pid=,command="],
            returncode=1,
            stdout="",
        )
        original_run = subprocess.run

        def run(command, **kwargs):
            if command == ["ps", "-axo", "pid=,ppid=,command="]:
                return failed_process
            return original_run(command, **kwargs)

        with mock.patch("fresh_install.subprocess.run", side_effect=run):
            with self.assertRaisesRegex(FreshInstallError, "Cannot inspect Relay processes"):
                self.coordinator(active_process_detector=None).reset_profile(
                    "relay-owned",
                    execute=True,
                    confirm_daemon_stopped=True,
                    confirm_profile="relay-owned",
                )

        self.assertEqual(self.tree(self.state), state_before)
        self.assertEqual(preference.read_text(), "preferences\n")
        self.assertFalse(self.trash.exists())

    def test_cli_reset_uses_default_detector_without_matching_its_own_command_lineage(self):
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fake_ps = fake_bin / "ps"
        fake_ps.write_text(
            "#!/bin/sh\n"
            "printf '%s %s %s\\n' \"$PPID\" 7001 'python /workspace/relay-runner/services/fresh_install_cli.py --reset-profile relay-owned'\n"
            "printf '%s %s %s\\n' 7001 1 '/bin/zsh -lc python /workspace/relay-runner/services/fresh_install_cli.py --reset-profile relay-owned'\n"
        )
        fake_ps.chmod(0o755)
        environment = {
            **os.environ,
            "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        }

        process = subprocess.run(
            [
                sys.executable,
                str(ROOT / "services/fresh_install_cli.py"),
                "--reset-profile", "relay-owned",
                "--execute",
                "--confirm-daemon-stopped",
                "--confirm-profile", "relay-owned",
                "--state-root", str(self.state),
                "--trash-root", str(self.trash),
                "--home-root", str(self.home),
                "--temporary-root", str(self.tmp),
            ],
            cwd=self.root,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue(json.loads(process.stdout)["ok"])
        self.assertFalse(self.state.exists())

    def test_voice_profile_and_evidence_capture_are_explicit_and_source_private(self):
        model = self.home / ".local/share/kokoro/kokoro-v1.0.onnx"
        voices = self.home / ".local/share/kokoro/voices-v1.0.bin"
        model.parent.mkdir(parents=True)
        model.write_bytes(b"model")
        voices.write_bytes(b"voices")
        cache = self.home / ".cache/huggingface/keep"
        cache.parent.mkdir(parents=True)
        cache.write_text("shared\n")

        reset = self.coordinator().reset_profile(
            "voice-models",
            execute=True,
            confirm_daemon_stopped=True,
            confirm_profile="voice-models",
        )
        self.assertFalse(model.exists())
        self.assertFalse(voices.exists())
        self.assertTrue(cache.exists())

        incident = self.root / "support.zip"
        incident.write_bytes(b"support")
        evidence = self.root / "evidence.json"
        result = self.coordinator().capture_evidence(
            evidence,
            installer_context="DMG mounted",
            startup_outcome="onboarding shown",
            source_app=self.source_app,
            incident_bundle=incident,
        )
        document = json.loads(evidence.read_text())
        self.assertEqual(result.evidence_path, str(evidence.resolve()))
        self.assertEqual(document["incident_support_bundle"]["filename"], "support.zip")
        self.assertTrue(document["source_content_captured"] is False)

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
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.relayrunner.app",
            "CFBundleShortVersionString": "0.0-test",
            "CFBundleVersion": "1",
        }))
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
