from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))

import orchestrator  # noqa: E402


@unittest.skipUnless(sys.platform == "darwin", "macOS read-only Git preflight")
class SpikeGitToolchainTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-spike-git-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        developer = subprocess.check_output(["/usr/bin/xcode-select", "-p"], text=True).strip()
        self.git = Path(developer) / "usr/bin/git"
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.run_git("init", "--quiet")
        self.run_git("config", "user.name", "Spike Test")
        self.run_git("config", "user.email", "spike@example.invalid")
        (self.repo / ".orchestrator").mkdir()
        (self.repo / ".orchestrator/RR-1.md").write_text("immutable ticket\n")
        (self.repo / "source.txt").write_text("evidence\n")
        self.run_git("add", "source.txt", ".orchestrator/RR-1.md")
        self.run_git("commit", "--quiet", "-m", "fixture")

    def run_git(self, *args):
        return subprocess.check_output([str(self.git), "-C", str(self.repo), *args], text=True)

    def prepare(self, candidates):
        with patch.object(orchestrator, "_spike_git_candidates", return_value=candidates):
            return orchestrator.prepare_spike_git_environment(str(self.repo))

    def test_cache_writing_launcher_is_rejected_even_when_it_exits_zero(self):
        launcher_dir = self.root / "launcher"
        launcher_dir.mkdir()
        launcher = launcher_dir / "git"
        cache = self.root / "xcrun_db-fixture"
        launcher.write_text(
            '#!/bin/sh\n'
            f'(: > "{cache}") 2>/dev/null || echo "xcrun: cache creation: Operation not permitted" >&2\n'
            f'exec "{self.git}" "$@"\n'
        )
        launcher.chmod(0o755)
        result = subprocess.run(
            ["/usr/bin/sandbox-exec", "-p", orchestrator.SPIKE_GIT_PROBE_POLICY,
             str(launcher), "rev-parse", "HEAD"],
            cwd=self.repo, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("cache creation", result.stderr)
        self.assertFalse(cache.exists())

        env = self.prepare([launcher, self.git])
        self.assertEqual(env["RELAY_SPIKE_GIT"], str(self.git.resolve()))
        self.assertFalse(cache.exists())

    def test_developer_git_without_homebrew_survives_nonlogin_child_shells(self):
        before = self.run_git("rev-parse", "HEAD")
        ticket = (self.repo / ".orchestrator/RR-1.md").read_bytes()
        with patch.dict(os.environ, {"PATH": "/usr/bin:/bin"}):
            env = self.prepare([self.git])
        command = (
            'test "$(command -v git)" = "$RELAY_SPIKE_GIT" && '
            'test "$GIT_OPTIONAL_LOCKS" = 0 && test "$GIT_NO_LAZY_FETCH" = 1 && '
            'git rev-parse HEAD && git ls-files && '
            '/bin/zsh -c \'test "$(command -v git)" = "$RELAY_SPIKE_GIT" && git status --porcelain\''
        )
        for shell in ("/bin/sh", "/bin/bash", "/bin/zsh"):
            with self.subTest(shell=shell):
                result = subprocess.run(
                    ["/usr/bin/sandbox-exec", "-p", orchestrator.SPIKE_GIT_PROBE_POLICY,
                     shell, "-c", command],
                    cwd=self.repo, env={**os.environ, **env}, capture_output=True, text=True, timeout=15,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertEqual(result.stdout, before + ".orchestrator/RR-1.md\nsource.txt\n")
        self.assertEqual(self.run_git("rev-parse", "HEAD"), before)
        self.assertEqual(self.run_git("status", "--porcelain"), "")
        self.assertEqual((self.repo / ".orchestrator/RR-1.md").read_bytes(), ticket)

    def test_shell_startup_path_override_blocks_preflight(self):
        startup = self.root / "startup"
        startup.mkdir()
        (startup / ".zshenv").write_text('export PATH=/usr/bin:/bin\n')
        with patch.dict(os.environ, {"ZDOTDIR": str(startup)}):
            with self.assertRaisesRegex(RuntimeError, "non-login shell"):
                self.prepare([self.git])

    def test_missing_direct_git_has_actionable_blocker(self):
        with self.assertRaisesRegex(RuntimeError, "Xcode.*Command Line Tools.*Git"):
            self.prepare([self.root / "missing/git"])

    def test_system_path_discovers_selected_developer_git_before_homebrew(self):
        with patch.dict(os.environ, {"PATH": "/usr/bin:/bin"}):
            candidates = orchestrator._spike_git_candidates()
            env = orchestrator.prepare_spike_git_environment(str(self.repo))
        self.assertNotIn(Path("/usr/bin/git"), candidates)
        self.assertEqual(candidates[0], self.git.resolve())
        self.assertEqual(env["RELAY_SPIKE_GIT"], str(self.git.resolve()))

    @unittest.skipUnless(os.environ.get("RELAY_SPIKE_CODEX_SANDBOX_SMOKE") == "1",
                         "opt-in smoke requires the installed Codex sandbox CLI")
    def test_installed_codex_read_only_sandbox_smoke(self):
        codex = shutil.which("codex")
        self.assertIsNotNone(codex, "install Codex before running the opt-in sandbox smoke")
        env = self.prepare([self.git])
        command = orchestrator._agent_command(
            agent_kind="codex", agent_bin=codex,
            run={"execution_mode": "spike", "result_schema_path": "unused.schema.json",
                 "spike_git_environment": env},
        )
        settings = ["--config", 'sandbox_mode="read-only"']
        for index, argument in enumerate(command):
            if argument == "--config":
                settings.extend([argument, command[index + 1]])
        before = self.run_git("rev-parse", "HEAD")
        ticket = (self.repo / ".orchestrator/RR-1.md").read_bytes()
        for shell in ("/bin/bash", "/bin/zsh"):
            with self.subTest(shell=shell):
                result = subprocess.run(
                    [codex, "sandbox", *settings, "--", shell, "-c",
                     'test "$(command -v git)" = "$RELAY_SPIKE_GIT" && '
                     'git rev-parse HEAD && git ls-files && git diff --exit-code && git status --porcelain'],
                    cwd=self.repo, env={**os.environ, **env}, capture_output=True, text=True, timeout=15,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertEqual(result.stdout, before + ".orchestrator/RR-1.md\nsource.txt\n")
        for target in ("source.txt", ".orchestrator/RR-1.md", str(self.root / "forbidden")):
            with self.subTest(target=target):
                result = subprocess.run(
                    [codex, "sandbox", *settings, "--", "/bin/sh", "-c", 'echo changed > "$1"', "probe", target],
                    cwd=self.repo, env={**os.environ, **env}, capture_output=True, text=True, timeout=15,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Operation not permitted", result.stderr)
        # Verify the OS boundary itself: arbitrary interpreters and shell
        # wrappers cannot send data, independently of command-text diagnostics.
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            probe = [sys.executable, "-I", "-c",
                     f"import socket; socket.create_connection(('127.0.0.1', {port}), timeout=2).close()"]
            control = subprocess.run(probe, capture_output=True, text=True, timeout=10)
            self.assertEqual(control.returncode, 0, control.stderr)
            connection, _ = listener.accept()
            connection.close()
            for wrapped in (probe, ["/bin/sh", "-c", 'exec "$@"', "probe", *probe]):
                with self.subTest(network_command=wrapped):
                    result = subprocess.run(
                        [codex, "sandbox", *settings, "--", *wrapped],
                        cwd=self.repo, env={**os.environ, **env},
                        capture_output=True, text=True, timeout=15,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Operation not permitted", result.stderr)
            listener.settimeout(0.1)
            with self.assertRaises(TimeoutError):
                listener.accept()
        self.assertEqual(self.run_git("rev-parse", "HEAD"), before)
        self.assertEqual(self.run_git("status", "--porcelain"), "")
        self.assertEqual((self.repo / ".orchestrator/RR-1.md").read_bytes(), ticket)
        self.assertFalse((self.root / "forbidden").exists())

    def test_repository_ticket_and_external_writes_remain_denied(self):
        env = self.prepare([self.git])
        before = self.run_git("rev-parse", "HEAD")
        ticket = (self.repo / ".orchestrator/RR-1.md").read_bytes()
        commands = (
            "echo changed > source.txt",
            "echo changed > .orchestrator/RR-1.md",
            f"echo changed > '{self.root / 'forbidden'}'",
            '"$RELAY_SPIKE_GIT" update-ref refs/heads/forbidden HEAD',
        )
        for command in commands:
            with self.subTest(command=command):
                result = subprocess.run(
                    ["/usr/bin/sandbox-exec", "-p", orchestrator.SPIKE_GIT_PROBE_POLICY,
                     "/bin/sh", "-c", command],
                    cwd=self.repo, env={**os.environ, **env}, capture_output=True, text=True, timeout=15,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Operation not permitted", result.stderr)
        self.assertEqual(self.run_git("rev-parse", "HEAD"), before)
        self.assertEqual(self.run_git("status", "--porcelain"), "")
        self.assertEqual((self.repo / ".orchestrator/RR-1.md").read_bytes(), ticket)
        self.assertFalse((self.root / "forbidden").exists())
        self.assertEqual(self.run_git("for-each-ref", "refs/heads/forbidden"), "")


if __name__ == "__main__":
    unittest.main()
