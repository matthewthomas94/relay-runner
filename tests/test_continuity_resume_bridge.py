from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch


ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))
sys.modules.setdefault(
    "numpy",
    SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import voice_bridge  # noqa: E402
from continuity_incidents import opaque_identifier  # noqa: E402
from intent_inbox import IntentInbox  # noqa: E402


class ContinuityResumeBridgeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.state_path = self.root / "state.json"
        self.state_path.write_text(json.dumps({"recovery_generation": "generation-7"}))
        self.inbox = IntentInbox(self.root / "inbox.sqlite3")
        self.addCleanup(self.inbox.close)
        self.session = {"session_key": "native-session", "provider": "codex"}
        self.applied_keys = set()
        self.payload = {
            "type": "continuity_resume",
            "final_result": "restored",
            "incident_id": "inc-123456789abc",
            "session_id": opaque_identifier("session", "native-session"),
            "command_id": None,
            "component": "speech_capture",
            "phase": "capture",
            "provider": "none",
            "recovery_generation": "generation-7",
            "incident_observed_at": 100,
        }

    def call(self, payload=None):
        return voice_bridge._bridge_continuity_resume_response(
            payload or self.payload,
            inbox=self.inbox,
            tts_worker=SimpleNamespace(input_queue=object()),
            orchestrator_session=self.session,
            applied_keys=self.applied_keys,
            state_path=str(self.state_path),
            turns_path=str(self.root / "turns.json"),
        )

    def test_pretranscript_loss_asks_once_through_canonical_tts_path(self):
        with (
            patch("voice_bridge._queue_tts_text", return_value=True) as queue_text,
            patch("voice_bridge._notify_state") as notify,
        ):
            result = self.call()
            duplicate = self.call()

        self.assertEqual(result["action"], "ask_repeat")
        self.assertEqual(duplicate, {"action": "noop", "reason": "handoff_already_applied"})
        queue_text.assert_called_once()
        notify.assert_called_once_with(
            "continuity_repeat",
            text=voice_bridge.PLEASE_REPEAT_TEXT,
        )

    def test_command_captured_during_recovery_suppresses_stale_repeat(self):
        metadata = {
            "relay_command_seq": 1,
            "relay_command_id": "command-one",
            "intent_id": "intent-1",
            "recovery_generation": "generation-7",
        }
        self.inbox.enqueue("private prompt", metadata, "continue_current")
        payload = {**self.payload, "incident_observed_at": 0}
        with patch("voice_bridge._queue_tts_text") as queue_text:
            result = self.call(payload)

        self.assertEqual(result, {"action": "noop", "reason": "captured_command_now_exists"})
        queue_text.assert_not_called()

    def test_exact_command_resume_is_generation_scoped_and_deduplicated(self):
        metadata = {
            "relay_command_seq": 1,
            "relay_command_id": "command-one",
            "intent_id": "intent-1",
            "recovery_generation": "generation-7",
        }
        self.inbox.enqueue("private prompt", metadata, "continue_current")
        payload = {
            **self.payload,
            "command_id": opaque_identifier("command", "command-one"),
            "component": "command",
            "phase": "command_processing",
        }
        with patch("voice_bridge._notify_state"):
            first = self.call(payload)
            duplicate = self.call(payload)

        self.assertEqual(first["action"], "resume_exact")
        self.assertEqual(duplicate, {"action": "noop", "reason": "handoff_already_applied"})

    def test_stale_generation_and_ambiguous_claim_never_resume(self):
        stale = {**self.payload, "recovery_generation": "generation-6"}
        self.assertEqual(self.call(stale)["reason"], "stale_recovery_generation")

        metadata = {
            "relay_command_seq": 1,
            "relay_command_id": "command-one",
            "intent_id": "intent-1",
            "recovery_generation": "generation-7",
        }
        claimed = self.inbox.enqueue("private prompt", metadata, "continue_current")
        self.inbox.observe_claim(claimed, provider_turn_seen=False)
        payload = {
            **self.payload,
            "command_id": opaque_identifier("command", "command-one"),
        }
        with patch("voice_bridge._notify_state") as notify:
            result = self.call(payload)
        self.assertEqual(result["action"], "foreground_review")
        notify.assert_called_once()


if __name__ == "__main__":
    unittest.main()
