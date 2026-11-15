from __future__ import annotations

import json
import os
import shlex
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
    def test_app_bundle_ships_no_python(self):
        """RR-487: the bundle copies only the worker prompt templates from
        services/, and the build fails if any Python file reaches it."""
        build_script = (ROOT / "scripts" / "build-dmg.sh").read_text()
        copy_block = build_script.split("# Worker prompt templates", 1)[1].split("; do", 1)[0]
        names = shlex.split(copy_block.split("for f in", 1)[1].replace("\\\n", " "))
        self.assertEqual(names, ["orchestrator_workflow.md", "orchestrator_artifact_workflow.md"])
        for name in names:
            self.assertTrue((SERVICES / name).is_file(), name)
        self.assertIn("the app bundle must not contain Python files", build_script)
        self.assertNotIn("setup-venv.sh", build_script)

    def test_onboarding_runs_health_checked_orchestrator_install(self):
        source = "\n".join(
            path.read_text() for path in (ROOT / "Sources" / "relay-runner" / "Onboarding").glob("*.swift")
        )
        self.assertIn('proc.arguments = ["--install"]', source)
        self.assertIn("relayOrchestratorScriptPath", source)
        self.assertIn("orchestratorReady", source)

    def test_fresh_setup_downloads_the_speech_model_without_python(self):
        """RR-487: first-run setup needs no Python: it downloads the Kokoro
        model with curl and creates no venv."""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scripts, fake_bin, home = (root / name for name in ("scripts", "bin", "home"))
            for directory in (scripts, fake_bin, home):
                directory.mkdir()
            launcher = self.bridge_launcher(scripts)
            self.mark_ready(home, include_models=False)
            self.write_executable(
                fake_bin / "curl",
                """#!/bin/bash
output=""
while [ $# -gt 0 ]; do
  case "$1" in --output) output="$2"; shift ;; https://*) echo "$1" >> "$FAKE_CURL_LOG" ;; esac
  shift
done
echo model > "$output"
""",
            )
            curl_log = root / "curl.log"
            env = {
                **os.environ,
                "HOME": str(home),
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "FAKE_CURL_LOG": str(curl_log),
                "RELAY_DIAGNOSTICS_DIR": str(root / "diagnostics"),
            }
            result = subprocess.run(
                [str(launcher), "--setup-only"], env=env, text=True, capture_output=True, check=False
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Setup ready (--setup-only)", result.stdout)
            self.assertEqual(
                curl_log.read_text().splitlines(),
                [
                    "https://huggingface.co/fastrtc/kokoro-onnx/resolve/main/kokoro-v1.0.onnx",
                    "https://huggingface.co/fastrtc/kokoro-onnx/resolve/main/voices-v1.0.bin",
                ],
            )
            kokoro = home / ".local/share/kokoro"
            self.assertEqual(
                sorted(path.name for path in kokoro.iterdir()), ["kokoro-v1.0.onnx", "voices-v1.0.bin"]
            )
            self.assertFalse((home / "Library/Application Support/relay-runner/services").exists())
            self.assertNotIn("pip", result.stdout + result.stderr)

    def test_upgrade_removes_only_the_retired_python_runtime(self):
        """RR-487: an install upgraded from a Python release loses its venv
        and downloaded interpreter, and keeps every other Relay file, under
        the old flag name as well as the new one."""
        for flag in ("--setup-only", "--venv-only"):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                scripts, home = root / "scripts", root / "home"
                scripts.mkdir()
                home.mkdir()
                launcher = self.bridge_launcher(scripts)
                self.mark_ready(home)
                data = home / "Library/Application Support/relay-runner"
                retired = [
                    data / "services/.venv/bin/python3",
                    data / "python/bin/python3",
                    data / ".python-stage.abc123/python.tar.gz",
                ]
                kept = [
                    data / "config.toml",
                    data / "projects/registry-v2.json",
                    data / "orchestrator/runs.db",
                    data / "notes/index.json",
                    data / "relay-remote/devices.json",
                    home / ".local/share/kokoro/kokoro-v1.0.onnx",
                ]
                for path in retired + kept:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("data\n")
                result = subprocess.run(
                    [str(launcher), flag],
                    env={**os.environ, "HOME": str(home), "RELAY_DIAGNOSTICS_DIR": str(root / "diagnostics")},
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Setup ready (--setup-only)", result.stdout)
                self.assertIn("Removed the Python runtime from an earlier release.", result.stderr)
                for name in ("services", "python", ".python-stage.abc123"):
                    self.assertFalse((data / name).exists(), name)
                for path in kept:
                    self.assertEqual(path.read_text(), "data\n", path)

    def test_claude_setup_installs_claude_even_when_codex_is_present(self):
        for provider, expect_install in (("claude", True), ("codex", False), ("", False)):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                scripts = root / "scripts"
                fake_bin = root / "bin"
                home = root / "home"
                for directory in (scripts, fake_bin, home):
                    directory.mkdir()

                source = (ROOT / "scripts" / "relay-bridge").read_text()
                start = source.index("find_codex_bin() {")
                end = source.index("\n}\n", start) + 3
                source = source[:start] + 'find_codex_bin() {\n    echo "$FAKE_CODEX"\n}\n' + source[end:]
                # Keep a Homebrew Claude on the test machine out of the result.
                source = source.replace(" /opt/homebrew/bin/claude /usr/local/bin/claude", "")
                launcher = scripts / "relay-bridge"
                launcher.write_text(source)
                launcher.chmod(launcher.stat().st_mode | stat.S_IXUSR)

                for relative in (
                    ".claude/skills/relay-bridge/SKILL.md",
                    ".claude/skills/relay-stop/SKILL.md",
                    ".claude/skills/relay-dispatch/SKILL.md",
                    ".claude/skills/relay-workflow/SKILL.md",
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
                codex = fake_bin / "codex"
                self.write_executable(codex, "#!/bin/bash\nexit 0\n")
                installed = root / "curl-called"
                self.write_executable(
                    fake_bin / "curl",
                    """#!/bin/bash
touch "$FAKE_CURL_CALLED"
cat <<'SH'
mkdir -p "$HOME/.local/bin"
printf '#!/bin/bash\\nexit 0\\n' > "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
SH
""",
                )
                env = {
                    **os.environ,
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "FAKE_CODEX": str(codex),
                    "FAKE_CURL_CALLED": str(installed),
                    "RELAY_DIAGNOSTICS_DIR": str(root / "diagnostics"),
                }
                env.pop("RELAY_RUNNER_PROVIDER", None)
                if provider:
                    env["RELAY_RUNNER_PROVIDER"] = provider

                result = subprocess.run(
                    [str(launcher), "--setup-only"],
                    env=env,
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(installed.exists(), expect_install, result.stdout)
                self.assertEqual((home / ".local/bin/claude").exists(), expect_install)
                if expect_install:
                    self.assertIn("Claude Code CLI not found", result.stdout)

    def test_missing_daemon_binary_is_safe_and_stops_launchd_retry_churn(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scripts = root / "scripts"
            home = root / "home"
            diagnostics = root / "diagnostics"
            scripts.mkdir()
            home.mkdir()
            launcher = scripts / "relay-orchestrator"
            shutil.copy2(ROOT / "scripts" / "relay-orchestrator", launcher)
            self.write_executable(scripts / "relay-bridge", "#!/bin/bash\nexit 0\n")
            result = subprocess.run(
                [str(launcher), "--run"],
                env={
                    **os.environ,
                    "HOME": str(home),
                    "PATH": "/usr/bin:/bin",
                    "RELAY_DIAGNOSTICS_DIR": str(diagnostics),
                    "RELAY_CORRELATION_ID": "22222222-2222-4222-8222-222222222222",
                },
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("daemon binary is missing from Relay Runner.app", result.stderr)
            rows = [
                json.loads(line)
                for path in diagnostics.glob("events-v1-shell-*.jsonl")
                for line in path.read_text().splitlines()
            ]
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["phase"], "orchestrator_preflight")
            self.assertEqual(rows[0]["outcome"], "failed")
            self.assertEqual(rows[0]["attributes"], {"error_code": "daemon_binary_missing"})
            self.assertLessEqual(len(rows[0]["summary"]), 80)

    def test_install_checks_the_daemon_before_reporting_setup_ready(self):
        source = (ROOT / "scripts" / "relay-orchestrator").read_text()
        bridge = (ROOT / "scripts" / "relay-bridge").read_text()

        self.assertIn("RELAY_ORCHESTRATOR_PREFLIGHT_REQUIRED=1", source)
        self.assertIn('if [ -z "${RELAY_ORCHESTRATOR_PREFLIGHT_REQUIRED:-}" ]', bridge)
        self.assertLess(source.index("    daemon_preflight\n}"), source.index("record_support_event shell setup ready"))
        for text in (source, bridge):
            self.assertNotRegex(text, r"/usr/bin/python3|python3? -[cm]\b|\bpip3? install|-m venv|python-build-standalone")

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
            home = root / "home"
            scripts.mkdir()
            home.mkdir()
            launcher = scripts / "relay-orchestrator"
            shutil.copy2(ROOT / "scripts" / "relay-orchestrator", launcher)
            self.write_executable(scripts / "relay-bridge", "#!/bin/bash\nexit 0\n")
            self.fake_daemon(root, "#!/bin/bash\nprintf '%s\\n' \"$RELAY_CORRELATION_ID\"\n")
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

    def test_bridge_progress_cap_maps_nested_completion_into_parent_band(self):
        source = (ROOT / "scripts" / "relay-bridge").read_text()
        start = source.index("emit_progress() {")
        end = source.index("\n}\n", start) + 3
        probe = source[start:end] + '\nemit_progress 100 "Nested complete."\n'

        result = subprocess.run(
            ["/bin/bash", "-c", probe],
            env={**os.environ, "RELAY_PROGRESS_MAX_PERCENT": "80"},
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.strip(), "RELAY_PROGRESS:80:Nested complete.")

    def test_outer_install_owns_ordered_progress_and_never_emits_full_marker(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scripts = root / "scripts"
            fake_bin = root / "bin"
            home = root / "home"
            scripts.mkdir()
            fake_bin.mkdir()
            home.mkdir()

            launcher_source = (ROOT / "scripts" / "relay-orchestrator").read_text()
            launcher_source = launcher_source.replace(
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                str(root / "missing-chatgpt-codex"),
            ).replace(
                "/Applications/Codex.app/Contents/Resources/codex",
                str(root / "missing-codex"),
            )
            launcher = scripts / "relay-orchestrator"
            self.write_executable(launcher, launcher_source)
            self.write_executable(
                scripts / "relay-bridge",
                """#!/bin/bash
set -e
# Skill refresh and MCP registration are delegated here too; only the
# nested setup reports progress.
[ "${1:-}" = "--setup-only" ] || exit 0
max_percent="${RELAY_PROGRESS_MAX_PERCENT:-100}"
echo "RELAY_PROGRESS:$((100 * max_percent / 100)):Nested runtime ready." >&2
""",
            )
            self.fake_daemon(root)

            launch_state = root / "launchd-state"
            self.write_executable(
                fake_bin / "launchctl",
                """#!/bin/bash
case "$1" in
  print) [ -f "$FAKE_LAUNCH_STATE" ] ;;
  bootstrap) touch "$FAKE_LAUNCH_STATE" ;;
  bootout) rm -f "$FAKE_LAUNCH_STATE" ;;
  kickstart) [ -f "$FAKE_LAUNCH_STATE" ] ;;
esac
""",
            )
            self.write_executable(fake_bin / "curl", "#!/bin/bash\nexit 0\n")
            port_file = root / "orchestrator.port"
            port_file.write_text("7634\n")

            result = subprocess.run(
                [str(launcher), "--install"],
                env={
                    **os.environ,
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "FAKE_LAUNCH_STATE": str(launch_state),
                    "RELAY_ORCHESTRATOR_PORT_FILE": str(port_file),
                    "RELAY_ORCHESTRATOR_ERR_FILE": str(root / "orchestrator.err"),
                    "RELAY_ORCHESTRATOR_LOG_FILE": str(root / "orchestrator.log"),
                    "RELAY_DIAGNOSTICS_DIR": str(root / "diagnostics"),
                },
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            markers = [
                line for line in result.stderr.splitlines()
                if line.startswith("RELAY_PROGRESS:")
            ]
            percentages = [int(line.split(":", 2)[1]) for line in markers]
            self.assertEqual(percentages, [80, 82, 85, 88, 92, 95, 98])
            self.assertNotIn(100, percentages)

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
            self.write_executable(scripts / "relay-bridge", "#!/bin/bash\nexit 0\n")
            self.fake_daemon(root)
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

    def bridge_launcher(self, scripts: Path) -> Path:
        """scripts/relay-bridge with no Codex, so setup checks only Claude."""
        source = (ROOT / "scripts" / "relay-bridge").read_text()
        start = source.index("find_codex_bin() {")
        end = source.index("\n}\n", start) + 3
        source = source[:start] + 'find_codex_bin() {\n    echo ""\n}\n' + source[end:]
        launcher = scripts / "relay-bridge"
        self.write_executable(launcher, source)
        return launcher

    def mark_ready(self, home: Path, *, include_models: bool = True) -> None:
        """Skills, launch agent, Claude and (optionally) the speech model."""
        relatives = [
            ".claude/skills/relay-bridge/SKILL.md",
            ".claude/skills/relay-stop/SKILL.md",
            ".claude/skills/relay-dispatch/SKILL.md",
            ".claude/skills/relay-workflow/SKILL.md",
            ".codex/skills/relay-bridge/SKILL.md",
            ".codex/skills/relay-stop/SKILL.md",
            ".codex/skills/relay-dispatch/SKILL.md",
            ".codex/skills/relay-workflow/SKILL.md",
            "Library/LaunchAgents/com.relay.orchestrator.plist",
        ]
        if include_models:
            relatives += [".local/share/kokoro/kokoro-v1.0.onnx", ".local/share/kokoro/voices-v1.0.bin"]
        for relative in relatives:
            path = home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("ready\n")
        (home / ".local/bin").mkdir(parents=True, exist_ok=True)
        self.write_executable(home / ".local/bin/claude", "#!/bin/bash\nexit 0\n")

    def fake_daemon(self, root: Path, content: str = "#!/bin/bash\nexit 0\n") -> Path:
        """A daemon binary where scripts/relay-orchestrator finds a cargo build."""
        daemon = root / "rust/target/debug/relay-orchestrator"
        daemon.parent.mkdir(parents=True)
        self.write_executable(daemon, content)
        return daemon

    @staticmethod
    def write_executable(path: Path, content: str) -> None:
        path.write_text(content)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)


if __name__ == "__main__":
    unittest.main()
