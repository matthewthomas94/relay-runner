"""RR-424: SpeechCoordinator routes speech to an attached Relay Remote device."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import unittest
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "services"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import relay_remote_protocol as proto  # noqa: E402
from speech_coordinator import SpeechCoordinator  # noqa: E402
import test_relay_remote as remote_tests  # noqa: E402
import test_speech_coordinator as coordinator_tests  # noqa: E402

intent = coordinator_tests.intent
wait_until = remote_tests.wait_until


class RemoteSinkTests(remote_tests.ServerTestCase):
    def setUp(self):
        super().setUp()
        self.now = 1000.0
        self.current = {(1, "one"), (2, "two")}
        self.log = Path(self.root) / "speech-events.jsonl"
        self.worker = coordinator_tests.FakeWorker()
        self.coordinator = SpeechCoordinator(
            self.worker,
            is_current=lambda seq, command_id: (seq, command_id) in self.current,
            event_log_path=self.log,
        )
        self.posted: list[dict] = []
        self.server = self.start_server(
            speech=self.coordinator,
            clock=lambda: self.now,
            notify=self.posted.append,
        )

    def connect(self, resume_after_seq=None):
        device = self.device()
        welcome = device.hello("phone-1", resume_after_seq)
        self.assertTrue(wait_until(lambda: "phone-1" in self.coordinator._remote_sinks))
        return device, welcome

    def events(self, name: str | None = None) -> list[dict]:
        if not self.log.exists():
            return []
        records = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [record for record in records if name is None or record["event"] == name]

    def assert_nothing_else_sent(self, device) -> None:
        device.send(proto.Ping(7))
        self.assertEqual(device.recv(), proto.Pong(7))

    def test_read_out_becomes_one_speech_frame_without_local_synthesis(self):
        device, _ = self.connect()

        self.assertTrue(self.coordinator.read_out("A stored reply"))

        frame = device.recv()
        self.assertIsInstance(frame, proto.Speech)
        self.assertEqual((frame.text, frame.kind, frame.source), ("A stored reply", "fallback", "fallback"))
        self.assertIsNone(frame.relay_command_seq)
        self.assert_nothing_else_sent(device)
        self.assertTrue(self.worker.input_queue.empty())
        self.assertNotIn("play", self.worker.calls)
        self.assertEqual(self.events("tts_enqueued"), [])

    def test_frames_carry_intent_kind_source_and_command_seq_in_order(self):
        device, _ = self.connect()

        self.coordinator.submit(intent(seq=1, kind="handoff", text="Looking now"))
        self.coordinator.submit(intent(seq=1, kind="final", authoritative=True, text="Done"))

        handoff, final = device.recv(), device.recv()
        self.assertEqual((handoff.kind, handoff.source, handoff.relay_command_seq), ("handoff", "messenger", 1))
        self.assertEqual((final.kind, final.source, final.relay_command_seq), ("final", "orchestrator", 1))
        self.assertLess(handoff.seq, final.seq)
        self.assertTrue(self.worker.input_queue.empty())

    def test_newer_command_stops_older_frames_and_stale_speech_never_follows(self):
        device, _ = self.connect()
        self.coordinator.submit(intent(seq=1, kind="handoff", text="Old handoff"))
        old = device.recv()

        self.current = {(2, "two")}
        self.coordinator.new_turn(2, "two")

        control = device.recv()
        self.assertEqual(control, proto.SpeechControl(old.seq + 1, "stop", "superseded"))
        self.assertFalse(self.coordinator.submit(
            intent(seq=1, kind="final", authoritative=True, text="Stale final")
        ))
        self.coordinator.submit(intent(seq=2, command_id="two", kind="final", authoritative=True, text="New"))
        fresh = device.recv()
        self.assertEqual((fresh.text, fresh.relay_command_seq), ("New", 2))
        self.assert_nothing_else_sent(device)
        self.assertNotIn("skip", self.worker.calls)

    def test_newer_command_speech_supersedes_unacked_frames_before_it_is_sent(self):
        device, _ = self.connect()
        self.coordinator.submit(intent(seq=1, kind="handoff", text="Old"))
        device.recv()

        self.coordinator.submit(intent(seq=2, command_id="two", kind="handoff", text="New"))

        control, fresh = device.recv(), device.recv()
        self.assertEqual((control.action, control.reason), ("stop", "superseded"))
        self.assertEqual((fresh.text, fresh.relay_command_seq), ("New", 2))

    # RR-460: the phone gets the same fallback replacement as Kokoro.

    def remote_fallback(self):
        return intent(seq=1, kind="final", source="fallback", authoritative=True, text="Fallback")

    def remote_final(self, text="Real final"):
        return intent(seq=1, kind="final", source="completion", authoritative=True, text=text)

    def test_late_final_stops_an_unacked_fallback_frame_and_is_sent(self):
        device, _ = self.connect()
        self.assertTrue(self.coordinator.submit(self.remote_fallback()))
        fallback = device.recv()

        self.assertTrue(self.coordinator.submit(self.remote_final()))

        control, final = device.recv(), device.recv()
        self.assertEqual(control, proto.SpeechControl(fallback.seq + 1, "stop", "superseded"))
        self.assertEqual((final.text, final.source, final.kind), ("Real final", "completion", "final"))
        self.assert_nothing_else_sent(device)

    def test_late_final_follows_a_played_fallback_frame(self):
        device, _ = self.connect()
        self.coordinator.submit(self.remote_fallback())
        fallback = device.recv()
        device.send(proto.Ack(fallback.seq, True))
        self.assertTrue(wait_until(lambda: self.events("played")))

        self.assertTrue(self.coordinator.submit(self.remote_final()))

        final = device.recv()
        self.assertEqual((final.seq, final.text), (fallback.seq + 1, "Real final"))
        self.assert_nothing_else_sent(device)

    def test_fallback_after_real_final_and_second_final_are_not_sent(self):
        device, _ = self.connect()
        self.assertTrue(self.coordinator.submit(self.remote_final()))
        device.recv()

        self.assertFalse(self.coordinator.submit(self.remote_fallback()))
        self.assertFalse(self.coordinator.submit(self.remote_final("Second final")))

        self.assert_nothing_else_sent(device)

    def test_stop_and_skip_become_speech_control_frames_once(self):
        device, _ = self.connect()
        self.coordinator.submit(intent(seq=1, kind="handoff", text="First"))
        device.recv()

        self.coordinator.stop()
        self.coordinator.stop()
        control = device.recv()
        self.assertEqual((control.action, control.reason), ("stop", "speech_only_barge_in"))
        self.assert_nothing_else_sent(device)

        self.coordinator.submit(intent(seq=1, kind="final", authoritative=True, text="Second"))
        device.recv()
        self.coordinator.skip()
        control = device.recv()
        self.assertEqual((control.action, control.reason), ("skip", "user_stop"))

    def test_played_ack_records_realization_and_unplayed_ack_records_receipt_only(self):
        device, _ = self.connect()
        self.coordinator.submit(intent(seq=1, kind="handoff", text="Heard"))
        self.coordinator.submit(intent(seq=1, kind="final", authoritative=True, text="Not heard"))
        heard, unheard = device.recv(), device.recv()

        device.send(proto.Ack(heard.seq, True))
        self.assertTrue(wait_until(lambda: self.events("realization")))
        device.send(proto.Ack(unheard.seq, False))
        self.assertTrue(wait_until(lambda: self.events("remote_received")))

        realizations = self.events("realization")
        self.assertEqual(len(realizations), 1)
        self.assertEqual(
            (realizations[0]["relay_command_seq"], realizations[0]["lifecycle_role"]),
            (1, "acknowledgement"),
        )
        coverage = self.coordinator.played_coverage(1, "one")
        self.assertEqual([item["spoken_text"] for item in coverage], ["Heard"])
        self.assertEqual(self.events("played")[0]["remote_seq"], heard.seq)

    def test_frames_produced_while_disconnected_replay_in_seq_order(self):
        device, _ = self.connect()
        self.coordinator.submit(intent(seq=1, kind="handoff", text="Before"))
        before = device.recv()
        device.send(proto.Ack(before.seq, True))
        self.assertTrue(wait_until(lambda: self.events("played")))
        device.close()
        self.assertTrue(wait_until(lambda: self.server.session("phone-1").conn is None))

        self.coordinator.submit(intent(seq=1, kind="progress", text="While away"))
        self.coordinator.submit(intent(seq=1, kind="final", authoritative=True, text="Result"))
        self.assertTrue(self.worker.input_queue.empty())

        again, welcome = self.connect(resume_after_seq=before.seq)
        self.assertEqual((welcome.server_seq, welcome.dropped), (before.seq + 2, False))
        missed = [again.recv(), again.recv()]
        self.assertEqual([frame.seq for frame in missed], [before.seq + 1, before.seq + 2])
        self.assertEqual([frame.text for frame in missed], ["While away", "Result"])
        self.coordinator.read_out("After")
        self.assertEqual(again.recv().seq, before.seq + 3)

    def test_expired_disconnected_device_returns_speech_to_kokoro(self):
        device, _ = self.connect()
        device.close()
        self.assertTrue(wait_until(lambda: self.server.session("phone-1").conn is None))
        self.now += proto.REPLAY_MAX_AGE + 1

        self.coordinator.submit(intent(seq=1, kind="handoff", text="Local"))

        self.assertEqual(self.worker.input_queue.get_nowait()["text"], "Local")
        detached = self.events("remote_sink_detached")
        self.assertEqual(detached[0]["reason"], "replay_window_expired")

    def test_event_log_names_the_sink_per_intent_without_text(self):
        device, _ = self.connect()
        remote = intent(seq=1, kind="handoff", text="Remote words")
        self.coordinator.submit(remote)
        device.recv()
        self.server.close()
        local = intent(seq=1, kind="final", authoritative=True, text="Local words")
        self.coordinator.submit(local)

        by_intent = {
            record["utterance_id"]: record["sink"]
            for record in self.events()
            if record["event"] in {"remote_speech_sent", "tts_enqueued"}
        }
        self.assertEqual(by_intent, {remote.utterance_id: "relay-remote", local.utterance_id: "kokoro"})
        sent = self.events("remote_speech_sent")[0]
        self.assertEqual(sent["device_id"], "phone-1")
        content = self.log.read_text()
        self.assertNotIn("Remote words", content)
        self.assertNotIn("Local words", content)


    # RR-454: the phone's Remote mode switch.

    def states(self) -> list[str]:
        return [event["state"] for event in self.posted]

    def set_mode(self, device, enabled: bool) -> None:
        device.send(proto.RemoteMode(str(uuid.uuid4()), enabled))
        device.send(proto.Ping(11))
        self.assertEqual(device.recv(), proto.Pong(11))

    def test_hello_in_remote_mode_posts_active_and_the_phone_speaks(self):
        device, _ = self.connect()
        self.assertTrue(wait_until(lambda: self.states() == ["active"]))

        self.coordinator.submit(intent(seq=1, kind="handoff", text="On the phone"))

        frame = device.recv()
        self.assertEqual((frame.text, frame.spoken_by), ("On the phone", "phone"))
        self.assertTrue(self.worker.input_queue.empty())

    def test_mode_off_returns_speech_to_kokoro_and_the_phone_gets_text_only(self):
        device, _ = self.connect()

        self.set_mode(device, False)

        self.assertNotIn("phone-1", self.coordinator._remote_sinks)
        self.assertEqual(self.states(), ["active", "inactive"])
        self.assertEqual(self.events("remote_sink_detached")[0]["reason"], "remote_mode_off")
        self.coordinator.submit(intent(seq=1, kind="handoff", text="On the Mac"))
        self.assertEqual(self.worker.input_queue.get_nowait()["text"], "On the Mac")
        shown = device.recv()
        self.assertIsInstance(shown, proto.Speech)
        self.assertEqual((shown.text, shown.spoken_by, shown.relay_command_seq), ("On the Mac", "mac", 1))
        # The phone acks a display-only frame as played; the Mac's own
        # playback, not the ack, is what realizes it.
        device.send(proto.Ack(shown.seq, True))
        self.assert_nothing_else_sent(device)
        self.assertEqual(self.events("played"), [])
        self.assertEqual(self.events("realization"), [])

    def test_mode_back_on_reattaches_without_a_reconnect(self):
        device, _ = self.connect()
        self.set_mode(device, False)
        self.set_mode(device, True)

        self.assertIn("phone-1", self.coordinator._remote_sinks)
        self.assertNotIn("phone-1", self.coordinator._remote_mirrors)
        self.assertEqual(self.states(), ["active", "inactive", "active"])
        self.coordinator.submit(intent(seq=1, kind="handoff", text="Phone again"))
        frame = device.recv()
        self.assertEqual((frame.text, frame.spoken_by), ("Phone again", "phone"))
        self.assertTrue(self.worker.input_queue.empty())

    def test_hello_with_mode_off_never_attaches_the_sink(self):
        device = self.device()
        device.hello("phone-1", remote_mode=False)
        self.assertTrue(wait_until(lambda: "phone-1" in self.coordinator._remote_mirrors))

        self.assertNotIn("phone-1", self.coordinator._remote_sinks)
        self.assertEqual(self.states(), ["inactive"])
        self.coordinator.read_out("Mac reply")
        self.assertEqual(self.worker.input_queue.get_nowait()["text"], "Mac reply")
        self.assertEqual(device.recv().spoken_by, "mac")

    def test_disconnect_in_remote_mode_keeps_the_replay_window(self):
        device, _ = self.connect()
        device.close()
        self.assertTrue(wait_until(lambda: self.states() == ["active", "disconnected"]))
        self.now += proto.REPLAY_MAX_AGE - 1

        self.coordinator.submit(intent(seq=1, kind="handoff", text="Held for the phone"))

        self.assertTrue(self.worker.input_queue.empty())
        self.assertIn("phone-1", self.coordinator._remote_sinks)

    def test_disconnect_with_mode_off_expires_at_once(self):
        device, _ = self.connect()
        self.set_mode(device, False)
        device.close()
        self.assertTrue(wait_until(lambda: self.states() == ["active", "inactive", "disconnected"]))

        self.coordinator.submit(intent(seq=1, kind="handoff", text="Mac only"))

        self.assertEqual(self.worker.input_queue.get_nowait()["text"], "Mac only")
        self.assertEqual(self.coordinator._remote_sinks, {})
        self.assertEqual(self.coordinator._remote_mirrors, {})
        self.assertFalse(self.server.session("phone-1").routable())


if __name__ == "__main__":
    unittest.main()
