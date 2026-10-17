"""RR-403: focus switches lose and misroute nothing, for Codex and Claude alike."""

from __future__ import annotations

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from test_voice_bridge_background_replies import FakeTTS  # noqa: E402
from test_voice_bridge_focus import FocusTestCase, voice_bridge  # noqa: E402
from intent_inbox import IntentInbox  # noqa: E402
from unittest import mock  # noqa: E402

# Both provider orderings: the session losing focus (A) and the one gaining it (B).
ORDERINGS = (("codex", "claude"), ("claude", "codex"))


class FocusSwitchMatrixTests(FocusTestCase):
    def setUp(self):
        super().setUp()
        voice_bridge._reset_foreground_reply_delivery_for_tests()
        self.addCleanup(voice_bridge._reset_foreground_reply_delivery_for_tests)
        self.state_path = voice_bridge.VOICE_COMMAND_STATE_FILE
        self.messenger = mock.Mock()
        self.messenger.submit_final.return_value = True
        self.tts = FakeTTS()

    def pair(self, a_provider: str, b_provider: str):
        a = self.focus(f"a-{a_provider}", a_provider)
        b = self.focus(f"b-{b_provider}", b_provider)
        return a, b

    def publish(self, inbox, target, seq: int, text: str) -> None:
        voice_bridge._publish_command(
            text,
            {
                "relay_command_seq": seq,
                "relay_command_id": f"cmd-{seq}",
                "intent_id": f"intent-{seq}",
                "voice_target_session_key": target.session_key,
            },
            command_path=target.command_path,
            meta_path=target.meta_path,
            state_path=self.state_path,
            inbox=inbox,
        )

    def badge(self, target) -> dict:
        try:
            with open(voice_bridge._reply_badge_path(target)) as f:
                return json.load(f)
        except FileNotFoundError:
            return {}

    def test_idle_session_keeps_an_empty_spool_while_the_focused_one_gets_the_command(self):
        for a_provider, b_provider in ORDERINGS:
            with self.subTest(a=a_provider, b=b_provider):
                inbox = IntentInbox(os.path.join(self.root, f"idle-{a_provider}.sqlite3"))
                self.addCleanup(inbox.close)
                a, b = self.pair(a_provider, b_provider)

                self.publish(inbox, b, 1, "hello b")

                with open(b.command_path) as f:
                    self.assertEqual(f.read(), "hello b")
                self.assertFalse(os.path.exists(a.command_path))
                self.assertFalse(os.path.exists(a.claim_path))
                os.unlink(b.command_path)
                os.unlink(b.meta_path)

    def test_claimed_in_flight_command_stays_in_its_session_across_a_focus_switch(self):
        for a_provider, b_provider in ORDERINGS:
            with self.subTest(a=a_provider, b=b_provider):
                self.tts = FakeTTS()
                self.messenger.reset_mock()
                a = self.focus(f"a-{a_provider}", a_provider)
                command = {
                    "relay_command_seq": 20,
                    "relay_command_id": f"cmd-a-{a_provider}",
                    "intent_id": f"intent-a-{a_provider}",
                    "voice_target_session_key": a.session_key,
                }
                voice_bridge._write_command_state(self.state_path, command)
                claim = json.dumps(command)
                with open(a.claim_path, "w") as f:
                    f.write(claim)

                b = self.focus(f"b-{b_provider}", b_provider)

                # The claim is A's: the switch neither moves nor clears it.
                with open(a.claim_path) as f:
                    self.assertEqual(f.read(), claim)
                self.assertFalse(os.path.exists(b.claim_path))

                # A's reply, arriving after the switch, is badged on A, not spoken for B.
                payload = {
                    "text": "A done.",
                    "relay_command_seq": 20,
                    "relay_command_id": command["relay_command_id"],
                    "intent_id": command["intent_id"],
                    "session_key": a.session_key,
                    "provider_session_id": f"{a_provider}-{a.session_key}-native",
                }
                self.assertTrue(voice_bridge._handle_orchestrator_reply_control(
                    json.dumps(payload),
                    tts_worker=self.tts,
                    messenger=self.messenger,
                    state_path=self.state_path,
                ))
                self.messenger.submit_final.assert_not_called()
                self.assertEqual(self.badge(a)["unread_count"], 1)
                self.assertEqual(self.badge(b), {})

    def test_tts_playing_when_focus_moves_is_stopped_and_badged_to_the_speaking_session(self):
        for a_provider, b_provider in ORDERINGS:
            with self.subTest(a=a_provider, b=b_provider):
                self.tts = FakeTTS()
                self.messenger.reset_mock()
                a = self.focus(f"a-{a_provider}", a_provider)
                command = {
                    "relay_command_seq": 30,
                    "relay_command_id": f"cmd-s-{a_provider}",
                    "intent_id": f"intent-s-{a_provider}",
                    "voice_target_session_key": a.session_key,
                }
                voice_bridge._write_command_state(self.state_path, command)
                payload = {
                    "text": "A is talking.",
                    "relay_command_seq": 30,
                    "relay_command_id": command["relay_command_id"],
                    "intent_id": command["intent_id"],
                    "session_key": a.session_key,
                    "provider_session_id": f"{a_provider}-{a.session_key}-native",
                }
                self.assertTrue(voice_bridge._handle_orchestrator_reply_control(
                    json.dumps(payload),
                    tts_worker=self.tts,
                    messenger=self.messenger,
                    state_path=self.state_path,
                ))
                self.tts.speaking = True

                b = self.focus(f"b-{b_provider}", b_provider)
                voice_bridge._cut_off_unfocused_speech(a.session_key, self.tts, self.messenger)

                self.tts.skip.assert_called_once()
                self.messenger.interrupt.assert_called_once()
                self.assertEqual(self.badge(a)["replies"][-1]["text"], "A is talking.")
                self.assertEqual(self.badge(b), {})


if __name__ == "__main__":
    unittest.main()
