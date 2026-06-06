from __future__ import annotations

import os
import queue
import sys
import tempfile
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

sys.modules.setdefault(
    "numpy",
    types.SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import voice_bridge  # noqa: E402


def claim_ready_command(path: str) -> str:
    claim = path + ".claim"
    os.rename(path, claim)
    try:
        with open(claim) as f:
            return f.read()
    finally:
        os.remove(claim)


class VoiceBridgePreemptionTests(unittest.TestCase):
    def test_newer_command_suppresses_stale_tts_after_first_claimed(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            tts_queue: queue.Queue = queue.Queue()

            voice_bridge._write_cmd_file("first request", path=command_path)
            self.assertEqual(claim_ready_command(command_path), "first request")

            voice_bridge._write_cmd_file("second request", path=command_path)

            queued = voice_bridge._queue_tts_text(
                "stale response to first request",
                tts_queue,
                command_path=command_path,
            )

            self.assertFalse(queued)
            self.assertTrue(tts_queue.empty())
            with open(command_path) as f:
                self.assertEqual(f.read(), "second request")

    def test_latest_command_wins_before_agent_claims_input(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")

            voice_bridge._write_cmd_file("first request", path=command_path)
            voice_bridge._write_cmd_file("second request", path=command_path)

            self.assertEqual(claim_ready_command(command_path), "second request")

    def test_single_message_tts_still_queues_without_pending_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            tts_queue: queue.Queue = queue.Queue()

            queued = voice_bridge._queue_tts_text(
                "**fresh** response",
                tts_queue,
                command_path=command_path,
            )

            self.assertTrue(queued)
            self.assertEqual(tts_queue.get_nowait(), "fresh response")

    def test_generated_provider_skills_share_preemption_contract(self):
        script_path = os.path.join(ROOT, "scripts", "relay-bridge")
        with open(script_path) as f:
            script = f.read()

        self.assertEqual(
            script.count("Codex and Claude use the same cooperative preemption contract"),
            2,
        )
        self.assertEqual(
            script.count("Run the preemption checkpoint immediately before"),
            2,
        )
        self.assertGreaterEqual(
            script.count("cmd_tmp=$(mktemp /tmp/voice_cmd_claim.XXXXXX) || exit 1"),
            4,
        )


if __name__ == "__main__":
    unittest.main()
