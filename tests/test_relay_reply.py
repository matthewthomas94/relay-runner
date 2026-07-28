from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

import relay_reply  # noqa: E402


class RelayReplyTests(unittest.TestCase):
    def test_current_claim_is_encoded_and_written_as_canonical_control_line(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            fifo_path = os.path.join(temp_dir, "voice_in.fifo")
            command = {
                "relay_command_seq": 17,
                "relay_command_id": "cmd-17",
                "source_text": "dispatch RR-247",
            }
            Path(claim_path).write_text(json.dumps(command))
            Path(state_path).write_text(json.dumps(command))
            os.mkfifo(fifo_path)
            reader = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
            self.addCleanup(os.close, reader)

            self.assertTrue(relay_reply.publish_current_reply(
                "Dispatched RR-247.",
                claim_path=claim_path,
                state_path=state_path,
                fifo_path=fifo_path,
                stderr=io.StringIO(),
            ))

            line = os.read(reader, 4096).decode()
            self.assertEqual(
                line,
                '__ORCHESTRATOR_REPLY__:{"relay_command_id": "cmd-17", '
                '"relay_command_seq": 17, "text": "Dispatched RR-247."}\n',
            )
            self.assertNotIn("source_text", line)

    def test_stale_claim_is_not_written_or_logged_with_command_content(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            fifo_path = os.path.join(temp_dir, "voice_in.fifo")
            Path(claim_path).write_text(json.dumps({
                "relay_command_seq": 17,
                "relay_command_id": "secret-command-id",
                "source_text": "private prompt",
            }))
            Path(state_path).write_text(json.dumps({
                "relay_command_seq": 18,
                "relay_command_id": "cmd-18",
            }))
            os.mkfifo(fifo_path)
            reader = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
            self.addCleanup(os.close, reader)
            stderr = io.StringIO()

            self.assertFalse(relay_reply.publish_current_reply(
                "private final",
                claim_path=claim_path,
                state_path=state_path,
                fifo_path=fifo_path,
                stderr=stderr,
            ))

            self.assertEqual(os.read(reader, 4096), b"")
            diagnostic = stderr.getvalue()
            self.assertIn("claimed command is not current", diagnostic)
            for private_value in ("secret-command-id", "private prompt", "private final"):
                self.assertNotIn(private_value, diagnostic)


if __name__ == "__main__":
    unittest.main()
