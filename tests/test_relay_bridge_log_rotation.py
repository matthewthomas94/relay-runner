from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def shell_function(source: str, name: str) -> str:
    start = source.index(f"{name}() {{")
    end = source.index("\n}\n", start) + 3
    return source[start:end]


class RelayBridgeLogRotationTests(unittest.TestCase):
    def test_launchctl_logging_distinguishes_submission_from_provider_outcome(self):
        script = (ROOT / "scripts" / "relay-bridge").read_text()

        self.assertIn("launchctl job submission accepted exit_status=0", script)
        self.assertIn("submission only; bridge/provider outcome pending", script)
        self.assertIn("record_embedded_session_event launchd_bridge_submission", script)
        self.assertIn("record_embedded_session_event bridge_socket_readiness", script)
        self.assertNotIn("launchctl submit exit_status=0", script)

    def test_rotate_log_preserves_existing_log_and_records_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            log_path = root / "voice_bridge.log"
            log_path.write_text("old crash evidence\n")

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(root / "home"),
                    "VOICE_BRIDGE_LOG_PATH": str(log_path),
                    "VOICE_BRIDGE_LOG_TIMESTAMP": "20260627-010203",
                    "VOICE_BRIDGE_LOG_REASON": "unit-test",
                    "VOICE_BRIDGE_LOG_PROVIDER": "codex",
                    "VOICE_BRIDGE_LOG_CWD": "/tmp/relay runner",
                }
            )

            result = subprocess.run(
                [str(ROOT / "scripts" / "relay-bridge"), "--rotate-log"],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            rotated_path = root / "voice_bridge.20260627-010203.log"
            self.assertEqual(rotated_path.read_text(), "old crash evidence\n")
            new_log = log_path.read_text()
            self.assertIn(f"previous_log={rotated_path}", new_log)
            self.assertIn("reason=unit-test", new_log)
            self.assertIn("provider=codex", new_log)
            self.assertIn("cwd=/tmp/relay runner", new_log)

    def test_launchctl_handoff_forwards_lifecycle_context_for_both_providers(self):
        source = (ROOT / "scripts" / "relay-bridge").read_text()
        functions = "\n".join(
            shell_function(source, name)
            for name in ("voice_bridge_log_path", "start_voice_bridge_daemon")
        )
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                bridge = root / "relay-bridge"
                socket_path = root / "voice.sock"
                handoff = root / "handoff.txt"
                log = root / "voice.log"
                bridge.write_text(
                    "#!/bin/bash\n"
                    "[ \"${1:-}\" = --rotate-log ] && exit 0\n"
                    "printf '%s\\n' \"$RELAY_RUNNER_PROVIDER\" \"$RELAY_APP_SESSION_ID\" \"$RELAY_INCIDENT_ID\" \"$RELAY_RETRY_ATTEMPT\" \"$RELAY_CORRELATION_ID\" > \"$HANDOFF_FILE\"\n"
                    "python3 - \"$BRIDGE_TEST_SOCK\" <<'PY'\n"
                    "import socket, sys\n"
                    "sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)\n"
                    "sock.bind(sys.argv[1])\n"
                    "sock.close()\n"
                    "PY\n"
                )
                bridge.chmod(0o700)
                harness = functions + """
record_embedded_session_event() { :; }
launchctl() {
    case "$1" in
        remove|print) return 0 ;;
        submit)
            while [ "$1" != "--" ]; do shift; done
            shift
            "$@"
            ;;
    esac
}
SUPPRESS_STARTUP_GREETING=false
start_voice_bridge_daemon
"""
                result = subprocess.run(
                    ["/bin/bash", "-c", harness],
                    cwd=root,
                    env={
                        **os.environ,
                        "SCRIPT_DIR": str(root),
                        "BRIDGE_SOCK": str(socket_path),
                        "BRIDGE_TEST_SOCK": str(socket_path),
                        "HANDOFF_FILE": str(handoff),
                        "VOICE_BRIDGE_LOG_PATH": str(log),
                        "RELAY_RUNNER_PROVIDER": provider,
                        "RELAY_APP_SESSION_ID": "11111111-1111-4111-8111-111111111111",
                        "RELAY_INCIDENT_ID": "inc-aaaaaaaaaaaa",
                        "RELAY_RETRY_ATTEMPT": "3",
                        "RELAY_CORRELATION_ID": "22222222-2222-4222-8222-222222222222",
                    },
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(handoff.read_text().splitlines(), [
                    provider,
                    "11111111-1111-4111-8111-111111111111",
                    "inc-aaaaaaaaaaaa",
                    "3",
                    "22222222-2222-4222-8222-222222222222",
                ])
                self.assertIn("submission only; bridge/provider outcome pending", log.read_text())

    def test_launchctl_and_direct_failures_are_reported_as_failure(self):
        source = (ROOT / "scripts" / "relay-bridge").read_text()
        functions = "\n".join(
            shell_function(source, name)
            for name in ("voice_bridge_log_path", "start_voice_bridge_daemon")
        )
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bridge = root / "relay-bridge"
            log = root / "voice.log"
            bridge.write_text("#!/bin/bash\n[ \"${1:-}\" = --rotate-log ] && exit 0\nexit 9\n")
            bridge.chmod(0o700)
            harness = functions + """
record_embedded_session_event() { :; }
sleep() { :; }
launchctl() {
    case "$1" in
        remove) return 0 ;;
        submit) return 23 ;;
        print) return 1 ;;
    esac
}
SUPPRESS_STARTUP_GREETING=false
if start_voice_bridge_daemon; then exit 0; else exit $?; fi
"""
            result = subprocess.run(
                ["/bin/bash", "-c", harness],
                cwd=root,
                env={
                    **os.environ,
                    "SCRIPT_DIR": str(root),
                    "BRIDGE_SOCK": str(root / "missing.sock"),
                    "VOICE_BRIDGE_LOG_PATH": str(log),
                    "RELAY_RUNNER_PROVIDER": "codex",
                },
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            contents = log.read_text()
            self.assertIn("submission failed exit_status=23", contents)
            self.assertIn("direct fallback did not produce a socket", contents)
            self.assertNotIn("submission accepted", contents)


if __name__ == "__main__":
    unittest.main()
