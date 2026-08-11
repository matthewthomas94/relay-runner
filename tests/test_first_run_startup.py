from __future__ import annotations

import importlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SERVICES = ROOT / "services"


class FirstRunStartupTests(unittest.TestCase):
    def test_toml_compat_parses_with_current_supported_runtime(self):
        sys.path.insert(0, str(SERVICES))
        try:
            module = importlib.import_module("toml_compat")
            self.assertEqual(module.tomllib.loads("value = 3")["value"], 3)
        finally:
            sys.path.remove(str(SERVICES))
            sys.modules.pop("toml_compat", None)

        requirements = (SERVICES / "requirements.txt").read_text()
        self.assertIn('tomli>=2,<3; python_version < "3.11"', requirements)

    def test_onboarding_runs_health_checked_orchestrator_install(self):
        source = (
            ROOT / "Sources" / "relay-runner" / "Onboarding" / "VenvInstaller.swift"
        ).read_text()
        self.assertIn('proc.arguments = ["--install"]', source)
        self.assertIn("relayOrchestratorScriptPath", source)
        self.assertIn("orchestratorReady", source)

    def test_stale_unloaded_launch_agent_is_repaired(self):
        result = self.run_launcher(stale_bootstrap=True, healthy=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("repaired stale launchd registration", result.stdout)

    def test_slow_or_crashing_daemon_fails_with_bounded_diagnostics(self):
        result = self.run_launcher(stale_bootstrap=False, healthy=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not become healthy within the bounded startup window", result.stderr)
        self.assertIn("simulated daemon crash", result.stderr)

    def run_launcher(self, *, stale_bootstrap: bool, healthy: bool) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scripts = root / "scripts"
            fake_bin = root / "bin"
            home = root / "home"
            scripts.mkdir()
            fake_bin.mkdir()
            home.mkdir()
            launcher = scripts / "relay-orchestrator"
            shutil.copy2(ROOT / "scripts" / "relay-orchestrator", launcher)
            self.write_executable(
                scripts / "relay-bridge",
                """#!/bin/bash
set -e
venv="$HOME/Library/Application Support/relay-runner/services/.venv/bin"
mkdir -p "$venv"
printf '#!/bin/bash\\nexit 0\\n' > "$venv/python"
chmod +x "$venv/python"
""",
            )
            state = root / "launchd-state"
            bootstrap_count = root / "bootstrap-count"
            self.write_executable(
                fake_bin / "launchctl",
                """#!/bin/bash
set -e
case "$1" in
  print) [ -f "$FAKE_LAUNCH_STATE" ] ;;
  bootstrap)
    count=0
    [ ! -f "$FAKE_BOOTSTRAP_COUNT" ] || count=$(cat "$FAKE_BOOTSTRAP_COUNT")
    count=$((count + 1))
    echo "$count" > "$FAKE_BOOTSTRAP_COUNT"
    if [ "${FAKE_STALE_BOOTSTRAP:-0}" = 1 ] && [ "$count" -eq 1 ]; then exit 1; fi
    touch "$FAKE_LAUNCH_STATE"
    ;;
  bootout) rm -f "$FAKE_LAUNCH_STATE" ;;
  kickstart) [ -f "$FAKE_LAUNCH_STATE" ] ;;
esac
""",
            )
            self.write_executable(
                fake_bin / "curl",
                """#!/bin/bash
[ "${FAKE_HEALTHY:-0}" = 1 ]
""",
            )
            port_file = root / "orchestrator.port"
            port_file.write_text("7634\n")
            error_file = root / "orchestrator.err"
            error_file.write_text("simulated daemon crash\n")
            env = os.environ.copy()
            env.update({
                "HOME": str(home),
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "FAKE_LAUNCH_STATE": str(state),
                "FAKE_BOOTSTRAP_COUNT": str(bootstrap_count),
                "FAKE_STALE_BOOTSTRAP": "1" if stale_bootstrap else "0",
                "FAKE_HEALTHY": "1" if healthy else "0",
                "RELAY_ORCHESTRATOR_HEALTH_WAIT_ATTEMPTS": "2",
                "RELAY_ORCHESTRATOR_PORT_FILE": str(port_file),
                "RELAY_ORCHESTRATOR_ERR_FILE": str(error_file),
                "RELAY_ORCHESTRATOR_LOG_FILE": str(root / "orchestrator.log"),
            })
            return subprocess.run(
                [str(launcher), "--restart-if-idle"],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

    @staticmethod
    def write_executable(path: Path, content: str) -> None:
        path.write_text(content)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)


if __name__ == "__main__":
    unittest.main()
