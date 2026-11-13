"""RR-401/RR-488: replies from every session are spoken in turn, never badged."""

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
from speech_coordinator import SpeechCoordinator  # noqa: E402
from test_speech_coordinator import FakeWorker  # noqa: E402


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

    def test_wheel_and_replay_fall_back_to_the_speech_queue_history_for_both_providers(self):
        # RR-488: with nothing queued for the session, play and the explicit
        # replay control replay its last reply from the speech queue.
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                target = self.focus(provider, provider)
                key = target.session_key
                for handle, payload in (
                    (voice_bridge._handle_session_playback, {"session_key": key, "action": "play"}),
                    (voice_bridge._handle_session_replay, {"session_key": key}),
                ):
                    self.tts.control_session = mock.Mock(side_effect=[False, True])
                    self.assertTrue(handle(payload, self.tts))
                    self.assertEqual(
                        [c.args for c in self.tts.control_session.call_args_list],
                        [(key, "play"), (key, "replay")],
                    )
                    self.tts.read_out.assert_not_called()
                self.tts.control_session = mock.Mock(return_value=False)
                self.assertFalse(voice_bridge._handle_session_replay({"session_key": key}, self.tts))

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

    def test_speech_queue_depth_is_published_when_it_changes(self):
        # RR-464: the notch stack follows the coordinator's queue.
        self.tts.session_playback_states = mock.Mock(return_value={})
        published = []
        with mock.patch.object(
            voice_bridge,
            "_notify_state",
            side_effect=lambda state, **fields: published.append((state, fields.get("text"))),
        ):
            for depth in (5, 5, 2):
                self.tts.queue_depth = depth
                voice_bridge._publish_session_playback(self.tts)
        self.assertEqual(
            [event for event in published if event[0] == "speech_queue"],
            [("speech_queue", "5"), ("speech_queue", "2")],
        )

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

    def speech(self):
        """A real speech queue playing into a fake player, as the bridge wires it."""
        worker = FakeWorker()
        coordinator = SpeechCoordinator(
            worker,
            is_current=lambda seq, command_id: voice_bridge._relay_command_current(
                seq, command_id, state_path=self.state_path
            ),
            is_preserved=lambda seq, command_id, disposition: (
                voice_bridge._relay_command_current_or_preserved(
                    {
                        "relay_command_seq": seq,
                        "relay_command_id": command_id,
                        "intent_id": disposition.get("intent_id"),
                    },
                    state_path=self.state_path,
                )
            ),
        )
        self.tts = coordinator
        return worker, coordinator

    @staticmethod
    def sent(worker) -> list[dict]:
        """Items the queue handed to the player since the last call."""
        items = []
        while not worker.input_queue.empty():
            items.append(worker.input_queue.get_nowait()["_speech_intent"])
        return items

    @staticmethod
    def play_through(worker, item) -> None:
        worker.observer("started", item)
        worker.observer("completed", item)

    def assert_no_badge(self, *targets) -> None:
        for target in targets:
            self.assertFalse(
                os.path.exists(os.path.join(target.spool_dir, "voice_reply_badge.json"))
            )

    def test_unfocused_reply_is_spoken_once_after_the_current_speech(self):
        # The focused reply reaches the queue directly, as without a messenger.
        self.messenger.submit_final.return_value = False
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                worker, _ = self.speech()
                a = self.focus(f"a-{provider}", provider)
                a_command = self.command(10, f"cmd-a-{provider}", a.session_key)
                b = self.focus(f"b-{provider}", provider)
                # B's newer command now leads the shared ledger.
                b_command = self.command(11, f"cmd-b-{provider}", b.session_key)
                self.assertTrue(self.reply(b_command, b.session_key, "B finished.", provider))
                [playing] = self.sent(worker)
                worker.observer("started", playing)

                self.assertTrue(self.reply(a_command, a.session_key, "A finished.", provider))

                # A waits its turn: B keeps playing and nothing is cut.
                self.assertEqual(self.sent(worker), [])
                self.assertEqual(worker.calls, [])
                worker.observer("completed", playing)
                [queued] = self.sent(worker)
                self.assertEqual(queued["spoken_text"], "A finished.")
                self.assertEqual(queued["session_key"], a.session_key)
                self.assertEqual(queued["kind"], "final")
                self.play_through(worker, queued)

                # A repeat of the same reply is not spoken twice.
                self.assertTrue(self.reply(a_command, a.session_key, "A finished.", provider))
                self.assertEqual(self.sent(worker), [])
                self.assertEqual(self.tts.queue_depth, 0)
                self.assert_no_badge(a, b)

    def test_unfocused_reply_skips_the_focused_sessions_messenger(self):
        a = self.focus("a", "codex")
        a_command = self.command(10, "cmd-a", "a")
        self.focus("b", "claude")
        self.command(11, "cmd-b", "b")
        worker, _ = self.speech()

        self.assertTrue(self.reply(a_command, "a", "A finished.", "codex"))

        self.messenger.submit_final.assert_not_called()
        [item] = self.sent(worker)
        self.assertEqual(item["spoken_text"], "A finished.")
        self.assertIsNone(item["command_seq"])
        self.assert_no_badge(a)

    def test_replies_from_two_unfocused_sessions_play_in_arrival_order(self):
        for first, second in (("codex", "claude"), ("claude", "codex")):
            with self.subTest(first=first, second=second):
                worker, _ = self.speech()
                a = self.focus(f"a-{first}", first)
                a_command = self.command(20, f"cmd-a-{first}", a.session_key)
                b = self.focus(f"b-{second}", second)
                b_command = self.command(21, f"cmd-b-{second}", b.session_key)
                self.focus(f"c-{first}", first)
                self.command(22, f"cmd-c-{first}", f"c-{first}")

                self.assertTrue(self.reply(a_command, a.session_key, "A finished.", first))
                self.assertTrue(self.reply(b_command, b.session_key, "B finished.", second))

                [head] = self.sent(worker)
                self.assertEqual(head["spoken_text"], "A finished.")
                self.assertEqual(self.tts.queue_depth, 2)
                self.play_through(worker, head)
                [following] = self.sent(worker)
                self.assertEqual(following["spoken_text"], "B finished.")
                self.play_through(worker, following)
                self.assertEqual(worker.calls, [])
                self.assertEqual(self.tts.queue_depth, 0)

    def test_reply_without_its_session_ledger_entry_is_still_superseded(self):
        a = self.focus("a", "codex")
        stale = self.command(10, "cmd-a-old", "a")
        self.command(11, "cmd-a-new", "a")
        self.focus("b", "claude")
        worker, _ = self.speech()

        self.assertFalse(self.reply(stale, "a", "Old answer.", "codex"))
        self.assertEqual(self.sent(worker), [])
        self.assert_no_badge(a)

    def test_focused_reply_is_spoken(self):
        b = self.focus("b", "claude")
        command = self.command(5, "cmd-b", "b")

        self.assertTrue(self.reply(command, "b", "B finished.", "claude"))

        self.messenger.submit_final.assert_called_once()
        self.assert_no_badge(b)

    def test_wheel_stop_and_barge_in_still_stop_an_unfocused_reply(self):
        a = self.focus("a", "codex")
        a_command = self.command(10, "cmd-a", "a")
        self.focus("b", "claude")
        self.command(11, "cmd-b", "b")
        worker, coordinator = self.speech()
        self.assertTrue(self.reply(a_command, "a", "A finished.", "codex"))
        [item] = self.sent(worker)
        worker.observer("started", item)

        self.assertTrue(voice_bridge._handle_session_playback(
            {"session_key": "a", "action": "stop"}, coordinator
        ))
        self.assertEqual(worker.calls, ["stop"])
        worker.observer("cancelled", item)

        # The stopped reply stays queued and Play brings it back.
        self.assertTrue(voice_bridge._handle_session_playback(
            {"session_key": "a", "action": "play"}, coordinator
        ))
        [resumed] = self.sent(worker)
        self.assertEqual(resumed["spoken_text"], "A finished.")
        worker.observer("started", resumed)
        coordinator.stop()
        self.assertEqual(worker.calls[-1], "stop")

    def send_focus(self, coordinator, key: str, provider: str) -> None:
        """Move focus through the bridge's control socket, as the app does."""
        shutdown = threading.Event()
        path = os.path.join(self.root, "focus.sock")
        with mock.patch.object(voice_bridge, "BRIDGE_CONTROL_SOCK", path), \
                mock.patch.object(voice_bridge, "_notify_state"):
            thread = threading.Thread(
                target=voice_bridge._start_control_socket,
                args=(coordinator, shutdown),
                kwargs={"recovery_context": {"messenger": self.messenger}},
                daemon=True,
            )
            thread.start()
            try:
                self.assertTrue(wait_until(lambda: os.path.exists(path)))
                message = voice_bridge.VOICE_FOCUS_PREFIX + json.dumps(
                    self.focus_payload(key, provider)
                )

                def send() -> bool:
                    # The socket file appears a moment before it takes datagrams.
                    try:
                        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
                            client.sendto(message.encode(), path)
                        return True
                    except ConnectionRefusedError:
                        return False

                self.assertTrue(wait_until(send))
                self.assertTrue(wait_until(
                    lambda: voice_bridge._current_voice_target().session_key == key
                ))
            finally:
                shutdown.set()
                thread.join(2)
            self.assertFalse(thread.is_alive())

    def test_focus_switch_keeps_the_playing_and_queued_replies(self):
        for a_provider, b_provider in (("codex", "claude"), ("claude", "codex")):
            with self.subTest(a=a_provider, b=b_provider):
                worker, coordinator = self.speech()
                self.messenger.reset_mock()
                a = self.focus(f"a-{a_provider}", a_provider)
                a_command = self.command(30, f"cmd-a-{a_provider}", a.session_key)
                b = self.focus(f"b-{b_provider}", b_provider)
                b_command = self.command(31, f"cmd-b-{b_provider}", b.session_key)
                self.messenger.submit_final.return_value = False
                self.assertTrue(self.reply(b_command, b.session_key, "B is talking.", b_provider))
                [playing] = self.sent(worker)
                worker.observer("started", playing)
                self.assertTrue(self.reply(a_command, a.session_key, "A waits.", a_provider))

                self.send_focus(coordinator, a.session_key, a_provider)
                self.send_focus(coordinator, b.session_key, b_provider)

                # Neither reply is stopped, skipped or moved into a badge.
                self.assertEqual(worker.calls, [])
                self.assertEqual(coordinator.queue_depth, 2)
                worker.observer("completed", playing)
                [queued] = self.sent(worker)
                self.assertEqual(queued["spoken_text"], "A waits.")
                self.play_through(worker, queued)
                self.assert_no_badge(a, b)
                self.messenger.submit_final.return_value = True

    def test_pm_tabs_sharing_a_project_each_hear_only_the_runs_they_dispatched(self):
        """RR-469: tabs share general-tasks, so outcomes route by session key."""
        def tab(key: str, provider: str):
            payload = self.focus_payload(key, provider)
            payload["cwd"] = os.path.join(self.root, "general-tasks")
            return voice_bridge._apply_voice_focus(payload)

        a = tab("tab-a", "codex")
        b = tab("tab-b", "claude")
        outcomes = {
            "tab-a": [{"id": 1, "payload": {"trace_event": {"ticket_id": "RR-1"}}}],
            "tab-b": [{"id": 2, "payload": {"trace_event": {"ticket_id": "RR-2"}}},
                      {"id": 3, "payload": {"trace_event": {"ticket_id": "RR-3"}}}],
        }
        requested = []

        def get_json(path, params):
            requested.append(params)
            return {"outcomes": outcomes.get(params.get("session_key"), [])}

        focused = voice_bridge._messenger_outcome_session(b, None)
        self.assertEqual(focused["session_key"], "tab-b")
        params = voice_bridge._pending_messenger_outcome_params(focused)
        self.assertEqual(params["session_key"], "tab-b")
        self.assertIn("tab-a", params["live_session_keys"].split(","))

        voice_bridge._deliver_pending_messenger_outcomes_once(
            orchestrator_session=focused,
            messenger=self.messenger,
            request_get_json=get_json,
            request_json=lambda path, payload: {},
        )
        # Only tab B's own outcomes reach it; tab A's wait for its focus.
        self.assertEqual([p.get("session_key") for p in requested], ["tab-b"])
        self.assert_no_badge(a, b)

    def test_stop_hook_completion_resolves_its_session_from_the_provider_id(self):
        a = self.focus("a", "claude")
        self.focus("b", "codex")
        os.makedirs(a.spool_dir, exist_ok=True)
        with open(os.path.join(a.spool_dir, "voice_provider_session_id"), "w") as f:
            f.write("claude-resumed-id\n")

        self.assertEqual(voice_bridge._reply_origin_target({"session_id": "claude-a-native"}), a)
        self.assertEqual(voice_bridge._reply_origin_target({"session_id": "claude-resumed-id"}), a)
        self.assertIsNone(voice_bridge._reply_origin_target({"session_id": "unknown"}))

    def test_dismissing_a_reply_leaves_the_queue_to_the_speech_service(self):
        self.tts.playing = False
        voice_bridge._cancel_speech(self.tts)
        self.tts.skip.assert_called_once_with()
        self.assertTrue(self.tts.input_queue.empty())

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



if __name__ == "__main__":
    unittest.main()
