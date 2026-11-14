"""RR-493: scripts/relay-bridge runs the Rust bridge (`relay-rs bridge`) by
default and the Python bridge with RELAY_BRIDGE_RUNTIME=python.

The launch block of scripts/relay-bridge runs against a fake app bundle whose
relay-rs and Python only report how they were started. The voice_bridge.py
switch (RELAY_BRIDGE_RUNTIME=rust) runs against the same kind of fake.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = (ROOT / "scripts" / "relay-bridge").read_text()
REPORT = '#!/bin/sh\nprintf \'%s %s\\n\' "$(basename "$0")" "$*"\nprintf \'speech=%s\\n\' "${RELAY_SPEECH_SERVICE_CMD-unset}"\n'


def _function(name: str) -> str:
    start = SCRIPT.index(f"{name}() {{")
    return SCRIPT[start:SCRIPT.index("\n}\n", start) + 3]


def _launch_block() -> str:
    return SCRIPT[SCRIPT.index('if RUST_BRIDGE="$(rust_bridge_binary)"; then'):]


def _executable(path: Path, text: str = REPORT) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)
    return path


class RelayBridgeLaunchTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.macos = self.root / "Relay Runner.app" / "Contents" / "MacOS"
        self.shared = self.macos.parent / "SharedSupport"
        (self.shared / "services").mkdir(parents=True)
        self.python = _executable(self.root / "venv" / "python3")

    def launch(self, environment: dict | None = None, speech_runtime: str = "") -> list[str]:
        harness = "\n".join([
            "set -euo pipefail",
            f"PROJECT_ROOT={shlex.quote(str(self.shared))}",
            'SERVICES_BUNDLE="$PROJECT_ROOT/services"',
            f"PYTHON={shlex.quote(str(self.python))}",
            "CONFIG_PATH=/c.toml",
            f"SPEECH_RUNTIME={shlex.quote(speech_runtime)}",
            "record_support_event() { :; }",
            _function("rust_bridge_binary"),
            _launch_block(),
        ])
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root), **(environment or {})}
        result = subprocess.run(
            ["/bin/bash", "-c", harness, "relay-bridge", "--suppress-startup-greeting"],
            env=env, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_the_bundled_rust_bridge_is_the_default(self):
        rust = _executable(self.macos / "relay-rs")
        _executable(self.macos / "relay-speech")
        lines = self.launch()
        self.assertEqual(lines[0], f"[relay-bridge] Voice bridge runtime: rust ({rust})")
        self.assertEqual(lines[1], "relay-rs bridge --config /c.toml --relay --suppress-startup-greeting")
        self.assertEqual(lines[2], "speech=unset", "the Rust bridge finds relay-speech beside itself")

    def test_the_rollback_switch_runs_the_python_bridge(self):
        _executable(self.macos / "relay-rs")
        for value in ["python", " Python "]:
            lines = self.launch({"RELAY_BRIDGE_RUNTIME": value})
            self.assertEqual(lines[0], "[relay-bridge] Voice bridge runtime: python")
            self.assertEqual(
                lines[1],
                f"python3 {self.shared}/services/voice_bridge.py --config /c.toml --relay --suppress-startup-greeting",
            )

    def test_a_build_without_relay_rs_runs_the_python_bridge(self):
        lines = self.launch({"RELAY_BRIDGE_RUNTIME": "rust"})
        self.assertEqual(lines[0], "[relay-bridge] Voice bridge runtime: python")
        self.assertTrue(lines[1].startswith("python3 "), lines)

    def test_python_speech_under_the_rust_bridge_uses_the_venv(self):
        _executable(self.macos / "relay-rs")
        expected = f"speech='{self.python}' '{self.shared}/services/speech_service.py'"
        self.assertEqual(self.launch()[2], expected, "no relay-speech beside relay-rs")
        _executable(self.macos / "relay-speech")
        self.assertEqual(self.launch(speech_runtime="python")[2], expected, "RELAY_SPEECH_RUNTIME=python")
        self.assertEqual(
            self.launch({"RELAY_SPEECH_SERVICE_CMD": "/custom/speech"}, speech_runtime="python")[2],
            "speech=/custom/speech",
        )
        self.assertEqual(
            self.launch({"RELAY_SPEECH_BINARY": str(self.root / "missing")})[2],
            expected,
            "RELAY_SPEECH_BINARY names no relay-speech",
        )


class VoiceBridgeSwitchTests(unittest.TestCase):
    """`RELAY_BRIDGE_RUNTIME=rust services/voice_bridge.py` execs relay-rs bridge."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.rust = _executable(self.root / "relay-rs")

    def run_switch(self, environment: dict | None = None) -> list[str]:
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "RELAY_BRIDGE_RUNTIME": "rust",
            "RELAY_RS_BINARY": str(self.rust),
            **(environment or {}),
        }
        result = subprocess.run(
            [sys.executable, str(ROOT / "services" / "voice_bridge.py"), "--config", "/c.toml", "--relay"],
            env=env, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_the_switch_leaves_relay_speech_to_the_rust_bridge(self):
        _executable(self.root / "relay-speech")
        self.assertEqual(self.run_switch(), ["relay-rs bridge --config /c.toml --relay", "speech=unset"])

    def test_python_speech_runs_under_this_interpreter(self):
        expected = "speech=" + shlex.join([sys.executable, str(ROOT / "services" / "speech_service.py")])
        self.assertEqual(self.run_switch()[1], expected, "no relay-speech beside relay-rs")
        _executable(self.root / "relay-speech")
        self.assertEqual(self.run_switch({"RELAY_SPEECH_RUNTIME": "python"})[1], expected)
        self.assertEqual(self.run_switch({"RELAY_SPEECH_SERVICE_CMD": "/custom/speech"})[1], "speech=/custom/speech")


if __name__ == "__main__":
    unittest.main()
