"""RR-401: background-session replies are badged, not spoken."""

from __future__ import annotations

import json
import os
import queue
import socket
import sys
import threading
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from test_voice_bridge_focus import FocusTestCase, voice_bridge, wait_until  # noqa: E402


class FakeTTS:
    def __init__(self, speaking: bool = False):
        self.input_queue = queue.Queue()
        self.speaking = speaking
        self.playing = False
        self.skip = mock.Mock()
        self.read_out = mock.Mock()


class BackgroundReplyTests(FocusTestCase):
    def test_wheel_controls_route_through_the_bridge_socket_without_changing_focus(self):
        self.focus("a", "codex")
        self.focus("b", "claude")
        self.tts.control_session = mock.Mock(return_value=True)
        self.tts.session_playback_states = mock.Mock(return_value={"a": "play"})
        shutdown = threading.Event()
        path = os.path.join(self.root, "wheel.sock")
        with mock.patch.object(voice_bridge, "BRIDGE_CONTROL_SOCK", path), \
                mock.patch.object(voice_bridge, "_notify_state") as notify:
            thread = threading.Thread(target=voice_bridge._start_control_socket, args=(self.tts, shutdown), daemon=True)
            thread.start()
            try:
                self.assertTrue(wait_until(lambda: os.path.exists(path)))
                with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
                    message = voice_bridge.VOICE_SESSION_PLAYBACK_PREFIX + json.dumps({"session_key": "a", "action": "play"})
                    client.sendto(message.encode(), path)
                    self.assertTrue(wait_until(lambda: self.tts.control_session.called))
                self.tts.control_session.assert_called_with("a", "play", waiting_session_key="")
                self.assertEqual(voice_bridge._current_voice_target().session_key, "b")
                self.assertTrue(notify.called)
            finally:
                shutdown.set()
                thread.join(2)
            self.assertFalse(thread.is_alive())

    def test_wheel_plays_unread_messages_in_order_then_replays_for_both_providers(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                target = self.focus(provider, provider)
                self.tts.control_session = mock.Mock(return_value=False)
                self.tts.read_out = mock.Mock(return_value=True)
                voice_bridge._record_background_reply(target, "First", {})
                voice_bridge._record_background_reply(target, "Second", {})
                payload = {"session_key": target.session_key, "action": "play"}
                for expected, unread in (("First", 1), ("Second", 0), ("Second", 0)):
                    self.assertTrue(voice_bridge._handle_session_playback(payload, self.tts))
                    self.tts.read_out.assert_called_with(expected, session_key=target.session_key)
                    self.assertEqual(self.badge(target)["unread_count"], unread)

    def test_wheel_play_and_stop_do_not_require_a_stored_background_reply(self):
        self.focus("a")
        self.tts.control_session = mock.Mock(return_value=True)
        for action in ("play", "stop"):
            self.assertTrue(voice_bridge._handle_session_playback({"session_key": "a", "action": action}, self.tts))
            self.tts.control_session.assert_called_with("a", action, waiting_session_key="")
        self.tts.read_out.assert_not_called()
        self.tts.control_session.return_value = False
        self.assertFalse(voice_bridge._handle_session_playback({"session_key": "a", "action": "stop"}, self.tts))
        self.tts.read_out.assert_not_called()

    def test_wheel_cannot_control_a_stopped_or_unknown_session(self):
        self.tts.control_session = mock.Mock()
        self.assertFalse(voice_bridge._handle_session_playback({"session_key": "missing", "action": "play"}, self.tts))
        self.tts.control_session.assert_not_called()

    def test_playback_snapshot_contains_state_and_session_keys_only(self):
        self.tts.session_playback_states = mock.Mock(return_value={"a": "play", "b": "stop"})
        with mock.patch.object(voice_bridge, "_notify_state") as notify:
            voice_bridge._publish_session_playback(self.tts)
        self.assertEqual(notify.call_args.args, ("session_playback",))
        self.assertEqual(json.loads(notify.call_args.kwargs["text"]), {"a": "play", "b": "stop"})

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

    def test_stop_hook_completion_resolves_its_session_from_the_provider_id(self):
        a = self.focus("a", "claude")
        self.focus("b", "codex")
        os.makedirs(a.spool_dir, exist_ok=True)
        with open(os.path.join(a.spool_dir, "voice_provider_session_id"), "w") as f:
            f.write("claude-resumed-id\n")

        self.assertEqual(voice_bridge._reply_origin_target({"session_id": "claude-a-native"}), a)
        self.assertEqual(voice_bridge._reply_origin_target({"session_id": "claude-resumed-id"}), a)
        self.assertIsNone(voice_bridge._reply_origin_target({"session_id": "unknown"}))

    def unheard(self, key: str, provider: str, seq: int, text: str):
        target = self.focus(key, provider)
        command = self.command(seq, f"cmd-{key}", key)
        self.focus("focused", "codex")
        voice_bridge._record_background_reply(target, text, command)
        return target

    def test_dismissing_a_reply_brings_the_oldest_unheard_reply_forward(self):
        a = self.unheard("a", "codex", 1, "A finished.")
        b = self.unheard("b", "claude", 2, "B finished.")

        voice_bridge._cancel_speech(self.tts)

        item = self.tts.input_queue.get_nowait()
        self.assertEqual(item["text"], "A finished.")
        self.assertEqual(self.badge(a)["unread_count"], 0)
        self.assertEqual(self.badge(b)["unread_count"], 1)

        # Listening to A to the end offers B next.
        voice_bridge._on_reply_finished("completed", self.tts)
        self.assertEqual(self.tts.input_queue.get_nowait()["text"], "B finished.")
        self.assertEqual(self.badge(b)["unread_count"], 0)

        voice_bridge._on_reply_finished("completed", self.tts)
        self.assertTrue(self.tts.input_queue.empty())

    def test_cancelling_playback_leaves_the_advance_to_the_stop_event(self):
        self.unheard("a", "codex", 1, "A finished.")
        self.tts.playing = True

        voice_bridge._cancel_speech(self.tts)

        self.tts.skip.assert_called_once()
        self.assertTrue(self.tts.input_queue.empty())

    def test_no_reply_is_brought_forward_while_speech_is_pending(self):
        self.unheard("a", "codex", 1, "A finished.")
        self.tts.speaking = True

        self.assertFalse(voice_bridge._advance_reply_queue(self.tts))
        self.assertTrue(self.tts.input_queue.empty())

    def test_a_brought_forward_reply_is_rebadged_when_focus_moves_away(self):
        a = self.unheard("a", "codex", 1, "A finished.")
        self.assertTrue(voice_bridge._advance_reply_queue(self.tts))
        self.tts.speaking = True

        self.focus("c", "claude")
        voice_bridge._cut_off_unfocused_speech("focused", self.tts, self.messenger)

        self.tts.skip.assert_called_once_with(reason="focus_switch")
        self.assertEqual(self.badge(a)["unread_count"], 1)

    def test_opening_the_session_of_the_waiting_reply_keeps_it(self):
        a = self.unheard("a", "codex", 1, "A finished.")
        self.assertTrue(voice_bridge._advance_reply_queue(self.tts))
        self.tts.speaking = True

        self.focus("a", "codex")
        voice_bridge._cut_off_unfocused_speech("focused", self.tts, self.messenger)

        self.tts.skip.assert_not_called()
        self.assertEqual(self.badge(a)["unread_count"], 0)

    def coordinated_tts(self) -> FakeTTS:
        tts = FakeTTS()
        tts.input_queue = mock.Mock()
        tts.input_queue.submit_text.return_value = True
        tts.input_queue.supports_atomic_waiting_playback = False
        tts.input_queue.publishes_waiting_preview = True
        return tts

    def test_direct_reply_speech_carries_its_session_key(self):
        self.focus("b", "claude")
        command = self.command(5, "cmd-b", "b")
        self.messenger.submit_final.return_value = False
        self.tts = self.coordinated_tts()

        self.assertTrue(self.reply(command, "b", "B finished.", "claude"))

        self.assertEqual(self.tts.input_queue.submit_text.call_args.kwargs["session_key"], "b")

    def test_stop_hook_completion_speech_carries_its_session_key(self):
        b = self.focus("b", "claude")
        command = self.command(6, "cmd-b2", "b")
        self.tts = self.coordinated_tts()

        self.assertTrue(voice_bridge._handle_provider_completion_control(
            json.dumps({**command, "session_id": "claude-b-native", "text": "Done."}),
            tts_worker=self.tts,
            messenger=None,
            state_path=self.state_path,
        ))

        self.assertEqual(
            self.tts.input_queue.submit_text.call_args.kwargs["session_key"], b.session_key
        )

    def test_messenger_speech_resolves_its_session_from_the_command_ledger(self):
        self.focus("a", "codex")
        self.command(7, "cmd-a", "a")
        tts = self.coordinated_tts()

        voice_bridge._queue_tts_text(
            json.dumps({"text": "On it.", "relay_command_seq": 7, "relay_command_id": "cmd-a"}),
            tts.input_queue,
            state_path=self.state_path,
            allow_pending_command=True,
        )

        self.assertEqual(tts.input_queue.submit_text.call_args.kwargs["session_key"], "a")

    def test_brought_forward_reply_speech_carries_its_session_key(self):
        a = self.unheard("a", "codex", 1, "A finished.")
        self.assertTrue(voice_bridge._advance_reply_queue(self.tts))

        item = self.tts.input_queue.get_nowait()
        self.assertEqual(item["_speech_intent_spec"]["session_key"], a.session_key)


if __name__ == "__main__":
    unittest.main()
