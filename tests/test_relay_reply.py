from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

import relay_reply  # noqa: E402


class RelayReplyTests(unittest.TestCase):
    def setUp(self):
        ownership = mock.patch.dict(os.environ, {
            "RELAY_APP_SESSION_ID": "test-app-session",
            "RELAY_RECOVERY_GENERATION": "test-generation",
            "RELAY_ACTOR_ROLE": "foreground_pm",
            "RELAY_FOREGROUND_GATE_HANDLE": "test-gate",
        })
        ownership.start()
        self.addCleanup(ownership.stop)

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
                '__ORCHESTRATOR_REPLY__:{"actor_role": "foreground_pm", '
                '"app_session_id": "test-app-session", '
                '"foreground_gate_handle": "test-gate", '
                '"recovery_generation": "test-generation", '
                '"relay_command_id": "cmd-17", "relay_command_seq": 17, '
                '"text": "Dispatched RR-247."}\n',
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

    def test_newer_continue_current_command_preserves_claimed_reply(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            fifo_path = os.path.join(temp_dir, "voice_in.fifo")
            claim = {
                "relay_command_seq": 17,
                "relay_command_id": "cmd-17",
                "intent_id": "cmd-17:item:1",
            }
            Path(claim_path).write_text(json.dumps(claim))
            Path(state_path).write_text(json.dumps({
                "relay_command_seq": 18,
                "relay_command_id": "cmd-18",
                "intent_id": "cmd-18:item:1",
                "cancelled_intent_ids": [],
                "work_disposition": {
                    "route": "continue_current",
                    "authorization_effect": "preserve",
                    "cancellation_scope": "none",
                },
            }))
            os.mkfifo(fifo_path)
            reader = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
            self.addCleanup(os.close, reader)

            self.assertTrue(relay_reply.publish_current_reply(
                "First reply.",
                claim_path=claim_path,
                state_path=state_path,
                fifo_path=fifo_path,
                stderr=io.StringIO(),
            ))

            payload = os.read(reader, 4096).decode()
            self.assertIn('"relay_command_id": "cmd-17"', payload)
            self.assertIn('"text": "First reply."', payload)

    def test_non_foreground_actor_cannot_publish_authoritative_reply(self):
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {"RELAY_ACTOR_ROLE": "messenger"}):
            self.assertFalse(relay_reply.publish_current_reply(
                "must not escape",
                claim_path="/missing/claim",
                state_path="/missing/state",
                fifo_path="/missing/fifo",
                stderr=stderr,
            ))
        self.assertIn("foreground ownership unavailable", stderr.getvalue())
        self.assertNotIn("must not escape", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
