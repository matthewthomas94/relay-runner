"""RR-500: scripts/relay-orchestrator runs the Rust daemon
(`Contents/MacOS/relay-orchestrator`) by default and the Python daemon with
RELAY_ORCHESTRATOR_RUNTIME=python or when the build has no Rust binary.

`cmd_run` runs against a fake app bundle whose daemon binary and venv Python
only report how they were started.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = (ROOT / "scripts" / "relay-orchestrator").read_text()
REPORT = '#!/bin/sh\nprintf \'%s %s\\n\' "$(basename "$0")" "$*"\n'

sys.path.insert(0, str(ROOT / "services"))
from fresh_install import FreshInstallCoordinator  # noqa: E402


def _function(name: str) -> str:
    start = SCRIPT.index(f"{name}() {{")
    return SCRIPT[start:SCRIPT.index("\n}\n", start) + 3]


def _pattern() -> str:
    line = next(line for line in SCRIPT.splitlines() if line.startswith("DAEMON_PROCESS_PATTERN="))
    return shlex.split(line.split("=", 1)[1])[0]


def _executable(path: Path, text: str = REPORT) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)
    return path


class RelayOrchestratorRunTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.macos = self.root / "Relay Runner.app" / "Contents" / "MacOS"
        self.shared = self.macos.parent / "SharedSupport"
        (self.shared / "services").mkdir(parents=True)
        self.python = _executable(self.root / "venv" / "python")
        self.orch_dir = self.root / "orchestrator"

    def run_daemon(self, environment: dict | None = None, venv_ready: bool = True) -> tuple[list[str], str]:
        harness = "\n".join([
            "set -euo pipefail",
            f"PROJECT_ROOT={shlex.quote(str(self.shared))}",
            f"VENV_PYTHON={shlex.quote(str(self.python))}",
            f"ORCH_DIR={shlex.quote(str(self.orch_dir))}",
            "ensure_support_correlation() { :; }",
            "ensure_venv() { echo venv-checked >&2; %s; }" % ("true" if venv_ready else "false"),
            _function("rust_daemon_binary"),
            _function("cmd_run"),
            'cmd_run "$@"',
        ])
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root), **(environment or {})}
        result = subprocess.run(
            ["/bin/bash", "-c", harness, "relay-orchestrator", "--config", "/c.toml"],
            env=env, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines(), result.stderr

    def test_the_bundled_rust_daemon_is_the_default(self):
        rust = _executable(self.macos / "relay-orchestrator")
        lines, stderr = self.run_daemon()
        self.assertEqual(lines, ["relay-orchestrator --config /c.toml"])
        self.assertIn(f"[relay-orchestrator] daemon runtime: rust ({rust})", stderr)
        self.assertNotIn("venv-checked", stderr, "the Rust daemon needs no venv")
        self.assertTrue(self.orch_dir.is_dir())

    def test_the_rollback_switch_runs_the_python_daemon(self):
        _executable(self.macos / "relay-orchestrator")
        for value in ["python", " Python "]:
            lines, stderr = self.run_daemon({"RELAY_ORCHESTRATOR_RUNTIME": value})
            self.assertEqual(lines, [f"python {self.shared}/services/orchestrator.py --config /c.toml"])
            self.assertIn("[relay-orchestrator] daemon runtime: python", stderr)
            self.assertIn("venv-checked", stderr)

    def test_a_build_without_the_rust_daemon_runs_the_python_daemon(self):
        lines, stderr = self.run_daemon({"RELAY_ORCHESTRATOR_RUNTIME": "rust"})
        self.assertEqual(lines, [f"python {self.shared}/services/orchestrator.py --config /c.toml"])
        self.assertIn("[relay-orchestrator] daemon runtime: python", stderr)

    def test_a_failed_venv_stops_only_the_python_daemon(self):
        lines, _ = self.run_daemon({"RELAY_ORCHESTRATOR_RUNTIME": "python"}, venv_ready=False)
        self.assertEqual(lines, [], "launchd sees a clean exit and does not spin")
        _executable(self.macos / "relay-orchestrator")
        lines, _ = self.run_daemon(venv_ready=False)
        self.assertEqual(lines, ["relay-orchestrator --config /c.toml"])


class DaemonProcessTests(unittest.TestCase):
    RUST = "/Applications/Relay Runner.app/Contents/MacOS/relay-orchestrator"
    PYTHON = ("/Users/u/Library/Application Support/relay-runner/services/.venv/bin/python "
              "/Applications/Relay Runner.app/Contents/SharedSupport/services/orchestrator.py")
    MCP = "/Applications/Relay Runner.app/Contents/MacOS/relay-orchestrator-mcp"

    def matches(self, command: str) -> bool:
        result = subprocess.run(["/usr/bin/grep", "-qE", _pattern()], input=command, text=True)
        return result.returncode == 0

    def test_status_matches_either_daemon_but_not_the_mcp_proxy(self):
        self.assertTrue(self.matches(self.RUST))
        self.assertTrue(self.matches(self.RUST + " --config /c.toml"))
        self.assertTrue(self.matches(self.PYTHON))
        self.assertFalse(self.matches(self.MCP))

    def test_fresh_install_counts_either_daemon_but_not_the_mcp_proxy(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "Library" / "Application Support" / "relay-runner"
            state.mkdir(parents=True)
            coordinator = FreshInstallCoordinator(state_root=state, home_root=directory)
            listing = "\n".join([
                f"{os.getpid()} 1 python fresh_install_cli.py",
                f"900001 1 {self.RUST}",
                f"900002 1 {self.PYTHON}",
                f"900003 1 {self.MCP}",
            ])
            done = subprocess.CompletedProcess([], 0, stdout=listing)
            with mock.patch("fresh_install.subprocess.run", return_value=done):
                active = coordinator._active_relay_processes()
        self.assertEqual([line.split()[0] for line in active], ["900001", "900002"])


if __name__ == "__main__":
    unittest.main()
