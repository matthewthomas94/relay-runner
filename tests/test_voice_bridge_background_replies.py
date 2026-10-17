"""RR-401: background-session replies are badged, not spoken."""

from __future__ import annotations

import json
import os
import queue
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from test_voice_bridge_focus import FocusTestCase, voice_bridge  # noqa: E402


class FakeTTS:
    def __init__(self, speaking: bool = False):
        self.input_queue = queue.Queue()
        self.speaking = speaking
        self.skip = mock.Mock()
        self.read_out = mock.Mock()


class BackgroundReplyTests(FocusTestCase):
    def setUp(self):
        super().setUp()
        voice_bridge._reset_foreground_reply_delivery_for_tests()
        self.addCleanup(voice_bridge._reset_foreground_reply_delivery_for_tests)
        self.state_path = voice_bridge.VOICE_COMMAND_STATE_FILE
        self.messenger = mock.Mock()
        self.messenger.submit_final.return_value = True
        self.tts = FakeTTS()

    def command(self, seq: int, command_id: str, session_key: str) -> dict:
        command = {
            "relay_command_seq": seq,
            "relay_command_id": command_id,
            "intent_id": f"intent-{command_id}",
            "voice_target_session_key": session_key,
        }
        voice_bridge._write_command_state(self.state_path, command)
        return command

    def reply(self, command: dict, session_key: str, text: str, provider: str) -> bool:
        payload = {
            "text": text,
            "relay_command_seq": command["relay_command_seq"],
            "relay_command_id": command["relay_command_id"],
            "intent_id": command["intent_id"],
            "session_key": session_key,
            "provider_session_id": f"{provider}-{session_key}-native",
        }
        return voice_bridge._handle_orchestrator_reply_control(
            json.dumps(payload),
            tts_worker=self.tts,
            messenger=self.messenger,
            state_path=self.state_path,
        )

    def badge(self, target) -> dict:
        try:
            with open(voice_bridge._reply_badge_path(target)) as f:
                return json.load(f)
        except FileNotFoundError:
            return {}

    def test_background_reply_is_badged_under_its_own_command_not_the_focused_one(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                self.messenger.reset_mock()
                self.tts = FakeTTS()
                a = self.focus(f"a-{provider}", provider)
                a_command = self.command(10, f"cmd-a-{provider}", a.session_key)
                b = self.focus(f"b-{provider}", provider)
                # B's newer command now leads the shared ledger.
                self.command(11, f"cmd-b-{provider}", b.session_key)

                self.assertTrue(self.reply(a_command, a.session_key, "A finished.", provider))

                self.messenger.submit_final.assert_not_called()
                self.assertTrue(self.tts.input_queue.empty())
                badge = self.badge(a)
                self.assertEqual(badge["unread_count"], 1)
                self.assertEqual(badge["replies"][-1]["text"], "A finished.")
                self.assertEqual(self.badge(b), {})

                # Focusing A marks it read and speaks nothing.
                self.focus(a.session_key, provider)
                badge = self.badge(a)
                self.assertEqual(badge["unread_count"], 0)
                self.assertEqual(badge["replies"][-1]["text"], "A finished.")
                self.messenger.submit_final.assert_not_called()
                self.tts.read_out.assert_not_called()

                # The explicit read-out speaks the stored reply.
                self.assertTrue(voice_bridge._handle_session_replay(
                    {"session_key": a.session_key}, self.tts
                ))
                self.tts.read_out.assert_called_with("A finished.")

    def test_reply_without_its_session_ledger_entry_is_still_superseded(self):
        a = self.focus("a", "codex")
        stale = self.command(10, "cmd-a-old", "a")
        self.command(11, "cmd-a-new", "a")
        self.focus("b", "claude")

        self.assertFalse(self.reply(stale, "a", "Old answer.", "codex"))
        self.assertEqual(self.badge(a), {})

    def test_focused_reply_is_spoken(self):
        b = self.focus("b", "claude")
        command = self.command(5, "cmd-b", "b")

        self.assertTrue(self.reply(command, "b", "B finished.", "claude"))

        self.messenger.submit_final.assert_called_once()
        self.assertEqual(self.badge(b), {})

    def test_focus_switch_mid_speech_stops_playback_and_badges_the_reply(self):
        a = self.focus("a", "codex")
        command = self.command(5, "cmd-a", "a")
        self.assertTrue(self.reply(command, "a", "A is talking.", "codex"))
        self.tts.speaking = True

        self.focus("b", "claude")
        voice_bridge._cut_off_unfocused_speech("a", self.tts, self.messenger)

        self.tts.skip.assert_called_once()
        self.messenger.interrupt.assert_called_once()
        badge = self.badge(a)
        self.assertEqual(badge["unread_count"], 1)
        self.assertEqual(badge["replies"][-1]["text"], "A is talking.")

    def test_focus_switch_without_speech_leaves_playback_alone(self):
        self.focus("a", "codex")
        self.focus("b", "claude")
        voice_bridge._cut_off_unfocused_speech("a", self.tts, self.messenger)
        self.tts.skip.assert_not_called()
        self.messenger.interrupt.assert_not_called()

    def test_background_outcomes_are_counted_and_cleared_on_focus(self):
        a = self.focus("a", "codex")
        b = self.focus("b", "claude")
        outcomes = {
            a.cwd: [
                {"id": 1, "payload": {"trace_event": {"ticket_id": "RR-1"}}},
                {"id": 2, "payload": {"trace_event": {"ticket_id": "RR-2"}}},
            ],
            b.cwd: [{"id": 3, "payload": {"trace_event": {"ticket_id": "RR-3"}}}],
        }
        requested = []

        def get_json(path, params):
            requested.append(params["repo_path"])
            return {"outcomes": outcomes.get(params["repo_path"], [])}

        focused = voice_bridge._messenger_outcome_session(b, None)
        voice_bridge._count_background_messenger_outcomes(focused, None, get_json)

        self.assertEqual(self.badge(a)["outcome_count"], 2)
        self.assertEqual(self.badge(b), {})
        self.assertNotIn(b.cwd, requested)

        self.focus("a", "codex")
        self.assertEqual(self.badge(a)["outcome_count"], 0)


if __name__ == "__main__":
    unittest.main()
