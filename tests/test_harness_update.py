import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services"))
import harness_update as updater


class HarnessUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.harnesses = self.root / "harnesses"

    def executable(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return str(path)

    def test_native_claude_is_updated_on_every_start_before_version_validation(self):
        binary = self.executable(self.root / "claude", 'echo "$1" >> "$0.calls"\necho "Claude Code 2.1.239"\n')
        for _ in range(2):
            self.assertEqual(updater.update_harness("claude", binary, root=self.harnesses), binary)
        self.assertEqual(Path(binary + ".calls").read_text().splitlines(),
                         ["update", "--version", "update", "--version"])

    def test_failed_update_stops_without_launching_or_probing_old_harness(self):
        binary = self.executable(self.root / "claude", 'echo "$1" >> "$0.calls"\necho "secret-token"\nexit 7\n')
        with self.assertRaises(updater.HarnessUpdateError) as failure:
            updater.update_harness("claude", binary, root=self.harnesses)
        self.assertNotIn("secret-token", str(failure.exception))
        self.assertEqual(Path(binary + ".calls").read_text(), "update\n")

    def test_claude_update_policy_does_not_report_disabled_update_as_success(self):
        binary = self.executable(self.root / "claude", 'exit 0\n')
        with patch.dict(os.environ, {"DISABLE_UPDATES": "1"}), patch.object(updater, "run") as run:
            with self.assertRaisesRegex(updater.HarnessUpdateError, "disabled"):
                updater.update_harness("claude", binary, root=self.harnesses)
            run.assert_not_called()

    def test_timeout_terminates_updater_process_group(self):
        with self.assertRaisesRegex(updater.HarnessUpdateError, "timed out"):
            updater.run([sys.executable, "-c", "import time; time.sleep(30)"], timeout=0.05)

    def test_concurrent_updates_are_refused(self):
        self.harnesses.mkdir()
        with (self.harnesses / "claude.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(updater, "run") as run:
                with self.assertRaisesRegex(updater.HarnessUpdateError, "already running"):
                    updater.update_harness("claude", "claude", root=self.harnesses)
                run.assert_not_called()

    def test_homebrew_updates_only_selected_provider_and_launches_new_link(self):
        for provider, package in (("codex", "codex"), ("claude", "claude-code"), ("claude", "claude-code@latest")):
            binary = self.executable(self.root / f"brew/Caskroom/{package}/1.0.0/{provider}", "exit 0\n")
            brew = self.root / "brew/bin/brew"
            with patch.object(updater, "run", return_value="provider 9.0.0") as run:
                updated = updater.update_harness(provider, binary, root=self.harnesses)
                self.assertEqual(updated, str(brew.parent / provider))
                self.assertEqual(run.call_args_list[0].args[0], [brew, "update"])
                self.assertEqual(run.call_args_list[1].args[0], [brew, "upgrade", "--cask", package])
                self.assertEqual(run.call_args_list[-1].args[0], [updated, "--version"])

    def test_npm_updates_the_existing_global_prefix(self):
        for provider, package in (("codex", "@openai/codex"), ("claude", "@anthropic-ai/claude-code")):
            prefix = self.root / f"node-{provider}"
            binary = self.executable(prefix / f"lib/node_modules/{package}/bin/{provider}", "exit 0\n")
            npm = self.executable(prefix / "bin/npm", "exit 0\n")
            with patch.object(updater, "run", return_value="provider 9.0.0") as run:
                self.assertEqual(updater.update_harness(provider, binary, root=self.harnesses), binary)
                self.assertEqual(run.call_args_list[0].args[0],
                                 [Path(npm), "install", "--global", "--prefix", str(prefix), f"{package}@latest"])

    def test_codex_bundle_uses_official_installer_and_new_executable(self):
        bundle = self.executable(self.root / "ChatGPT.app/Contents/Resources/codex", "exit 0\n")
        expected = str(self.harnesses / "codex/bin/codex")

        def run(arguments, **kwargs):
            if arguments == [bundle, "--version"]:
                return "codex-cli 0.150.0"
            if arguments == [expected, "--version"]:
                return "codex-cli 0.151.0"
            return ""

        with patch.object(updater, "run", side_effect=run) as runner:
            self.assertEqual(updater.update_harness("codex", bundle, root=self.harnesses), expected)
        calls = runner.call_args_list
        self.assertIn(updater.CODEX_INSTALLER, calls[1].args[0])
        install = calls[2]
        self.assertEqual(install.args[0][0], "/bin/sh")
        self.assertEqual(install.kwargs["environment"]["CODEX_INSTALL_DIR"], str(Path(expected).parent))
        self.assertEqual(install.kwargs["environment"]["CODEX_NON_INTERACTIVE"], "true")
        self.assertEqual(Path(bundle).read_text(), "#!/bin/sh\nexit 0\n")

    def test_newer_bundled_codex_is_not_downgraded(self):
        bundle = self.executable(self.root / "Codex.app/Contents/Resources/codex", "exit 0\n")
        with patch.object(updater, "run", side_effect=lambda args, **kw:
                          "codex-cli 0.152.0" if args == [bundle, "--version"] else "codex-cli 0.151.0"):
            self.assertEqual(updater.update_harness("codex", bundle, root=self.harnesses), bundle)

    def test_codex_download_failure_does_not_fall_back_to_old_bundle(self):
        bundle = self.executable(self.root / "Codex.app/Contents/Resources/codex", "exit 0\n")
        with patch.object(updater, "run", side_effect=["codex-cli 0.150.0", updater.HarnessUpdateError("offline")]):
            with self.assertRaisesRegex(updater.HarnessUpdateError, "offline"):
                updater.update_harness("codex", bundle, root=self.harnesses)

    def test_unknown_custom_codex_requires_supported_update_path(self):
        binary = self.executable(self.root / "custom/codex", "exit 0\n")
        with patch.object(updater, "run") as run:
            with self.assertRaisesRegex(updater.HarnessUpdateError, "custom Codex"):
                updater.update_harness("codex", binary, root=self.harnesses)
            run.assert_not_called()

    def test_cli_returns_updated_binary_as_json(self):
        import json
        binary = self.executable(self.root / "claude", 'echo "Claude Code 2.1.239"\n')
        completed = subprocess.run(
            [sys.executable, updater.__file__, "--provider", "claude", "--command", binary],
            env=dict(os.environ, HOME=str(self.root)), capture_output=True, text=True, check=True,
        )
        self.assertEqual(json.loads(completed.stdout), {"binary": binary})


if __name__ == "__main__":
    unittest.main()
