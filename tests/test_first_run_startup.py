from __future__ import annotations

import importlib
import json
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

    def test_retained_unsupported_venv_is_recreated_before_dependency_short_circuit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scripts = root / "scripts"
            services = root / "services"
            fake_bin = root / "bin"
            home = root / "home"
            scripts.mkdir()
            services.mkdir()
            fake_bin.mkdir()
            home.mkdir()

            source = (ROOT / "scripts" / "relay-bridge").read_text()
            start = source.index("find_codex_bin() {")
            end = source.index("\n}\n", start) + 3
            source = source[:start] + 'find_codex_bin() {\n    echo ""\n}\n' + source[end:]
            source = source.replace(
                "/opt/homebrew/bin/python3.13 /usr/local/bin/python3.13 python3.13",
                "python3.13",
            )
            launcher = scripts / "relay-bridge"
            launcher.write_text(source)
            launcher.chmod(launcher.stat().st_mode | stat.S_IXUSR)
            (services / "requirements.txt").write_text("placeholder\n")

            for relative in (
                ".claude/commands/relay-bridge.md",
                ".claude/commands/relay-stop.md",
                ".claude/commands/relay-dispatch.md",
                ".claude/commands/relay-workflow.md",
                ".codex/skills/relay-bridge/SKILL.md",
                ".codex/skills/relay-stop/SKILL.md",
                ".codex/skills/relay-dispatch/SKILL.md",
                ".codex/skills/relay-workflow/SKILL.md",
                ".local/share/kokoro/kokoro-v1.0.onnx",
                ".local/share/kokoro/voices-v1.0.bin",
                "Library/LaunchAgents/com.relay.orchestrator.plist",
            ):
                path = home / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("ready\n")
            (home / ".local/bin").mkdir(parents=True, exist_ok=True)
            self.write_executable(home / ".local/bin/claude", "#!/bin/bash\nexit 0\n")

            venv_bin = home / "Library/Application Support/relay-runner/services/.venv/bin"
            venv_bin.mkdir(parents=True)
            self.write_executable(
                venv_bin / "python3",
                """#!/bin/bash
case "${2:-}" in
  *'sys.exit(0 if (3,10)'*) exit 1 ;;
  *'print(".".join'*) echo 3.9; exit 0 ;;
  *'import numpy'*) exit 0 ;;
esac
exit 0
""",
            )

            created = root / "venv-created"
            self.write_executable(
                fake_bin / "python3.13",
                """#!/bin/bash
if [ "${1:-}" = "--version" ]; then echo 'Python 3.13.7'; exit 0; fi
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "venv" ]; then
  mkdir -p "$3/bin"
  cp "$0" "$3/bin/python3"
  cp "$0" "$3/bin/python"
  printf '#!/bin/bash\nexit 0\n' > "$3/bin/pip"
  chmod +x "$3/bin/python3" "$3/bin/python" "$3/bin/pip"
  touch "$FAKE_VENV_CREATED"
  exit 0
fi
exit 0
""",
            )
            env = {
                **os.environ,
                "HOME": str(home),
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "FAKE_VENV_CREATED": str(created),
                "RELAY_DIAGNOSTICS_DIR": str(root / "diagnostics"),
            }

            result = subprocess.run(
                [str(launcher), "--venv-only"],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(created.exists(), result.stdout + result.stderr)
            self.assertIn("Existing venv uses Python 3.9", result.stdout)
            self.assertIn("Venv ready (--venv-only)", result.stdout)

    def test_pre_main_import_failure_is_safe_and_stops_launchd_retry_churn(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scripts = root / "scripts"
            services = root / "services"
            home = root / "home"
            diagnostics = root / "diagnostics"
            scripts.mkdir()
            services.mkdir()
            home.mkdir()
            launcher = scripts / "relay-orchestrator"
            shutil.copy2(ROOT / "scripts" / "relay-orchestrator", launcher)
            self.write_executable(
                scripts / "relay-bridge",
                """#!/bin/bash
set -e
venv="$HOME/Library/Application Support/relay-runner/services/.venv/bin"
mkdir -p "$venv"
cat > "$venv/python" <<'PYTHON_EOF'
#!/bin/bash
if [ "${1:-}" = "-c" ]; then echo '3.9.18'; exit 0; fi
if [ "${1:-}" = "-" ]; then cat >/dev/null; echo 'ModuleNotFoundError'; exit 1; fi
touch "$FAKE_DAEMON_EXECUTED"
PYTHON_EOF
chmod +x "$venv/python"
""",
            )
            (services / "orchestrator.py").write_text("")
            daemon_executed = root / "daemon-executed"
            result = subprocess.run(
                [str(launcher), "--run"],
                env={
                    **os.environ,
                    "HOME": str(home),
                    "PATH": "/usr/bin:/bin",
                    "FAKE_DAEMON_EXECUTED": str(daemon_executed),
                    "RELAY_DIAGNOSTICS_DIR": str(diagnostics),
                    "RELAY_CORRELATION_ID": "22222222-2222-4222-8222-222222222222",
                },
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(daemon_executed.exists())
            self.assertIn(
                "orchestrator import preflight failed under Python 3.9.18 (ModuleNotFoundError)",
                result.stderr,
            )
            rows = [
                json.loads(line)
                for path in diagnostics.glob("events-v1-shell-*.jsonl")
                for line in path.read_text().splitlines()
            ]
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["phase"], "orchestrator_preflight")
            self.assertEqual(rows[0]["outcome"], "failed")
            self.assertEqual(rows[0]["attributes"]["version"], "3.9.18")
            self.assertEqual(rows[0]["attributes"]["error_code"], "ModuleNotFoundError")
            self.assertLessEqual(len(rows[0]["summary"]), 80)

    def test_preflight_imports_the_complete_shipped_orchestrator_module(self):
        source = (ROOT / "scripts" / "relay-orchestrator").read_text()
        bridge = (ROOT / "scripts" / "relay-bridge").read_text()
        orchestrator = (SERVICES / "orchestrator.py").read_text()

        self.assertIn('importlib.import_module("services.orchestrator")', source)
        self.assertIn("RELAY_ORCHESTRATOR_PREFLIGHT_REQUIRED=1", source)
        self.assertIn('if [ -z "${RELAY_ORCHESTRATOR_PREFLIGHT_REQUIRED:-}" ]', bridge)
        self.assertLess(
            source.index('importlib.import_module("services.orchestrator")'),
            source.index("record_support_event shell setup ready"),
        )
        self.assertIn("ArtifactLifecycleCoordinator", orchestrator)
        self.assertIn("ArtifactRolloutStore", orchestrator)
        self.assertIn("ArtifactStore", orchestrator)

    def test_stale_unloaded_launch_agent_is_repaired(self):
        result = self.run_launcher(stale_bootstrap=True, healthy=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("repaired stale launchd registration", result.stdout)

    def test_slow_or_crashing_daemon_fails_with_bounded_diagnostics(self):
        result = self.run_launcher(stale_bootstrap=False, healthy=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not become healthy within the bounded startup window", result.stderr)
        self.assertIn("simulated daemon crash", result.stderr)

    def test_orchestrator_run_exports_one_stable_correlation_id(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scripts = root / "scripts"
            services = root / "services"
            home = root / "home"
            scripts.mkdir()
            services.mkdir()
            home.mkdir()
            launcher = scripts / "relay-orchestrator"
            shutil.copy2(ROOT / "scripts" / "relay-orchestrator", launcher)
            self.write_executable(
                scripts / "relay-bridge",
                """#!/bin/bash
set -e
venv="$HOME/Library/Application Support/relay-runner/services/.venv/bin"
mkdir -p "$venv"
cat > "$venv/python" <<'PYTHON_EOF'
#!/bin/bash
printf '%s\n' "$RELAY_CORRELATION_ID"
PYTHON_EOF
chmod +x "$venv/python"
""",
            )
            (services / "orchestrator.py").write_text("")
            env = os.environ.copy()
            env.pop("RELAY_CORRELATION_ID", None)
            env.update({"HOME": str(home), "PATH": "/usr/bin:/bin"})

            result = subprocess.run(
                [str(launcher), "--run"],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            correlation_ids = [line for line in result.stdout.splitlines() if line.startswith("orchestrator-")]
            self.assertEqual(len(correlation_ids), 1)
            self.assertRegex(correlation_ids[0], r"^orchestrator-[0-9]+-[0-9]+$")

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
