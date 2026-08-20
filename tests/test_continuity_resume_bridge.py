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

    def test_commandless_transcription_loss_asks_through_canonical_tts_path(self):
        payload = {
            **self.payload,
            "component": "transcription",
            "phase": "transcription",
        }
        with (
            patch("voice_bridge._queue_tts_text", return_value=True) as queue_text,
            patch("voice_bridge._notify_state") as notify,
        ):
            result = self.call(payload)

        self.assertEqual(result["action"], "ask_repeat")
        queue_text.assert_called_once()
        notify.assert_called_once_with(
            "continuity_repeat",
            text=voice_bridge.PLEASE_REPEAT_TEXT,
        )

    def test_commandless_liveness_recovery_never_asks_repeat(self):
        cases = (
            ("bridge", "delivery"),
            ("messenger", "component_liveness"),
            ("daemon", "component_liveness"),
            ("session", "session_liveness"),
        )
        with (
            patch("voice_bridge._queue_tts_text") as queue_text,
            patch("voice_bridge._notify_state") as notify,
        ):
            for index, (component, phase) in enumerate(cases, start=1):
                with self.subTest(component=component):
                    result = self.call({
                        **self.payload,
                        "incident_id": f"inc-liveness-{index}",
                        "component": component,
                        "phase": phase,
                    })
                    self.assertEqual(
                        result,
                        {
                            "phase": "commandless_liveness",
                            "action": "noop",
                            "reason": "no_command_resume_required",
                            "intent_id": None,
                        },
                    )

        queue_text.assert_not_called()
        notify.assert_not_called()

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

    def test_delivered_unclaimed_command_is_released_and_rematerialized_exactly(self):
        command_path = self.root / "ready"
        metadata_path = self.root / "ready.meta"
        metadata = {
            "relay_command_seq": 1,
            "relay_command_id": "command-one",
            "intent_id": "intent-1",
            "within_turn_order": 1,
            "recovery_generation": "generation-7",
        }
        original = self.inbox.enqueue("private prompt", metadata, "continue_current")
        self.inbox.materialize_next(
            command_path=str(command_path),
            metadata_path=str(metadata_path),
            transport="codex",
        )
        command_path.unlink()
        metadata_path.unlink()
        payload = {
            **self.payload,
            "command_id": opaque_identifier("command", "command-one"),
            "component": "command",
            "phase": "command_processing",
        }

        with patch("voice_bridge._notify_state"):
            result = self.call(payload)

        self.assertEqual(result["action"], "resume_exact")
        self.assertEqual(self.inbox.records()[0]["state"], "pending")
        resumed = self.inbox.materialize_next(
            command_path=str(command_path),
            metadata_path=str(metadata_path),
            transport="claude",
        )
        self.assertEqual(resumed["intent_id"], original["intent_id"])
        self.assertEqual(resumed["intent_delivery_id"], original["intent_delivery_id"])

    def test_recovered_siblings_release_in_order_after_each_acknowledgement(self):
        self.inbox.close()
        database = self.root / "siblings.sqlite3"
        inbox = IntentInbox(database)
        for intent_id, order, generation in (
            ("intent-1", 1, "generation-7"),
            ("intent-2", 2, "generation-7"),
            ("intent-wrong-generation", 3, "generation-8"),
        ):
            inbox.enqueue(
                f"private prompt {order}",
                {
                    "relay_command_seq": 1,
                    "relay_command_id": "command-one",
                    "intent_id": intent_id,
                    "within_turn_order": order,
                    "recovery_generation": generation,
                },
                "continue_current",
            )
        inbox.enqueue(
            "unrelated prompt",
            {
                "relay_command_seq": 2,
                "relay_command_id": "command-two",
                "intent_id": "intent-unrelated",
                "within_turn_order": 1,
                "recovery_generation": "generation-7",
            },
            "continue_current",
        )
        inbox.close()
        self.inbox = IntentInbox(database, hold_recovered_delivery=True)
        self.addCleanup(self.inbox.close)
        payload = {
            **self.payload,
            "command_id": opaque_identifier("command", "command-one"),
            "component": "command",
            "phase": "command_processing",
        }

        with patch("voice_bridge._notify_state"):
            result = self.call(payload)

        self.assertEqual(result["intent_id"], "intent-1")
        self.assertEqual(
            [record["state"] for record in self.inbox.records()],
            ["pending", "recovery_pending", "recovery_pending", "recovery_pending"],
        )
        command_path = self.root / "ready"
        metadata_path = self.root / "ready.meta"
        first = self.inbox.materialize_next(
            command_path=str(command_path),
            metadata_path=str(metadata_path),
            transport="codex",
        )
        self.inbox.observe_claim(first, provider_turn_seen=True)
        command_path.unlink()
        metadata_path.unlink()
        self.assertEqual(
            [record["state"] for record in self.inbox.records()],
            ["acked", "pending", "recovery_pending", "recovery_pending"],
        )
        second = self.inbox.materialize_next(
            command_path=str(command_path),
            metadata_path=str(metadata_path),
            transport="claude",
        )
        self.assertEqual(second["intent_id"], "intent-2")
        self.inbox.observe_claim(second, provider_turn_seen=True)
        self.assertEqual(
            [record["state"] for record in self.inbox.records()],
            ["acked", "acked", "recovery_pending", "recovery_pending"],
        )

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
