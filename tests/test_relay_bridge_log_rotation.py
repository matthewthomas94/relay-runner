from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


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


if __name__ == "__main__":
    unittest.main()
