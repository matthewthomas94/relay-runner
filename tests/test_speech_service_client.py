"""RR-480: the voice bridge's speech service client and wiring.

The client runs against the real ``speech_service.py`` in its test mode, so
these cases cover what the black-box contract suite cannot: the bridge's side
of a restart, Relay Remote device calls, and the bridge's own start-up code.
"""

from __future__ import annotations

import json
import os
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

import speech_client  # noqa: E402
import speech_service  # noqa: E402
import voice_bridge  # noqa: E402
from remote_audio import AudioPart  # noqa: E402
from speech_client import SpeechServiceClient, SpeechServiceError  # noqa: E402
from speech_coordinator import CoordinatorInputQueue, SpeechCoordinator  # noqa: E402

SERVICE = [sys.executable, os.path.join(SERVICES, "speech_service.py")]
# A first sentence of 30 s of test-mode audio, three times as long as a case
# waits. A case that stops the reply once that sentence is at the output
# (``wait_at_output``) stops it inside the sentence however slowly the machine
# runs: the worker can end a reply stopped between sentences ``failed`` (see
# "playback" in docs/specs/speech-service-protocol.md).
LONG_FIRST = "This sentence keeps the reply going" + " and going" * 1500 + "."
LONG = f"{LONG_FIRST} It is the second sentence that ends the reply."
# Everything the bridge and Relay Remote call on the speech object.
BRIDGE_SURFACE = (
    "input_queue", "speaking", "playing", "queue_depth", "session_playback_states", "control_session",
    "read_out", "play", "play_or_replay", "replay", "stop_playback", "skip", "new_turn",
    "arm_waiting_playback", "note_play_control", "note_visual_acknowledgement", "played_coverage",
    "record_realization", "record_messenger_stage", "record_missing_outcome", "reload_config",
    "attach_remote_sink", "detach_remote_sink", "attach_remote_mirror", "detach_remote_mirror",
    "remote_ack", "shutdown",
)
INPUT_QUEUE_SURFACE = (
    "put", "submit_text", "arm_waiting_playback", "empty",
    "supports_atomic_waiting_playback", "publishes_waiting_preview",
)


def wait_until(predicate, timeout: float = 10.0, message: str = "condition"):
    deadline = time.monotonic() + timeout
    while True:
        value = predicate()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out waiting for {message}")
        time.sleep(0.01)


class FakeDevice:
    """A Relay Remote ``DeviceSession`` as the coordinator uses it."""

    def __init__(self, device_id: str):
        self.device_id = device_id
        self.seq = 0
        self.speeches: list[dict] = []
        self.controls: list[tuple] = []
        self.audio: list[tuple] = []

    def routable(self) -> bool:
        return True

    def speech(self, **frame) -> int:
        self.seq += 1
        self.speeches.append({**frame, "seq": self.seq})
        return self.seq

    def speech_control(self, action: str, reason: str) -> int:
        self.seq += 1
        self.controls.append((action, reason))
        return self.seq

    def speech_audio(self, seq: int, part) -> None:
        self.audio.append((seq, part))


class ClientCase(unittest.TestCase):
    def setUp(self):
        # Short on purpose: a Unix socket path holds at most 104 bytes on macOS.
        self.root = tempfile.mkdtemp(prefix="rsc-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.state_path = os.path.join(self.root, "voice_command_state.json")
        self.playback_log = os.path.join(self.root, "playback.jsonl")
        self.config_path = os.path.join(self.root, "config.toml")
        with open(self.config_path, "w") as handle:
            handle.write("[tts]\nauto_play = false\nrate = 1.0\n")
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.root,
            "RELAY_SPEECH_TEST_MODE": "1",
            "RELAY_SPEECH_TEST_PLAYBACK_LOG": self.playback_log,
            "RELAY_SPEECH_TEST_MS_PER_CHAR": "2",
            "TTS_CONTROL_SOCK": os.path.join(self.root, "tts_control.sock"),
            "VOICE_STATE_SOCK": os.path.join(self.root, "voice_state.sock"),
            "SPEECH_EVENT_LOG": os.path.join(self.root, "speech_events.jsonl"),
            "VOICE_COMMAND_STATE_FILE": self.state_path,
        }
        self.finished: list[str] = []
        self.restarts: list[float] = []
        self.client = self.make_client()
        self.client.start()

    def make_client(self, command: list[str] | None = None) -> SpeechServiceClient:
        client = SpeechServiceClient(
            command or [*SERVICE, "--config", self.config_path],
            os.path.join(self.root, "speech.sock"),
            env=self.env,
            on_reply_finished=self.finished.append,
            on_restart=lambda: self.restarts.append(time.monotonic()),
            start_timeout=20.0,
            request_timeout=5.0,
        )
        self.addCleanup(client.close)
        return client

    def set_command(self, seq: int, command_id: str) -> None:
        with open(self.state_path + ".tmp", "w") as handle:
            json.dump({"relay_command_seq": seq, "relay_command_id": command_id}, handle)
        os.replace(self.state_path + ".tmp", self.state_path)

    def final(self, text: str, seq: int, command_id: str, **metadata) -> bool:
        self.set_command(seq, command_id)
        return self.client.input_queue.submit_text(
            text, command_seq=seq, command_id=command_id, source="orchestrator", kind="final",
            authoritative=True, **metadata,
        )

    def stored(self, text: str, key: str) -> bool:
        """A reply without command metadata, as the bridge queues a background reply."""
        return self.client.input_queue.put({
            "text": text, "display_text": text, "_speech_intent_spec": {"dedup_key": key},
        })

    @staticmethod
    def records(path: str, event: str) -> list[dict]:
        """The records of one kind in a JSON-lines log."""
        try:
            with open(path) as handle:
                records = [json.loads(line) for line in handle if line.strip()]
        except FileNotFoundError:
            return []
        return [record for record in records if record["event"] == event]

    def spoken(self) -> list[tuple[str, bool]]:
        return [(record["text"], record["completed"])
                for record in self.records(self.playback_log, "chunk_finished")]

    def at_output(self) -> list[str]:
        """The text of every sentence handed to the output, in order."""
        return [record["text"] for record in self.records(self.playback_log, "chunk_started")]

    def waiting(self) -> int:
        """How many times a reply was reported waiting for play (`queued`)."""
        return len(self.records(self.env["SPEECH_EVENT_LOG"], "queued"))

    def wait_at_output(self, before: int = 0) -> str:
        """Wait for a sentence after the first ``before`` to reach the output; return its text."""
        return wait_until(lambda: self.at_output()[before:], message="a sentence to reach the output")[0]

    def kill_service(self) -> str:
        instance_id = self.client.instance_id
        os.kill(self.client._process.pid, signal.SIGKILL)
        return instance_id

    def wait_restarted(self, previous_instance: str) -> None:
        wait_until(
            lambda: self.client._ready.is_set() and self.client.instance_id != previous_instance,
            message="the speech service to restart",
        )


class SurfaceTests(unittest.TestCase):
    def test_client_offers_everything_the_bridge_uses_on_the_coordinator(self):
        for name in BRIDGE_SURFACE:
            with self.subTest(name=name):
                self.assertTrue(hasattr(SpeechCoordinator, name) or name == "input_queue")
                self.assertTrue(hasattr(SpeechServiceClient, name) or name == "input_queue")
        for name in INPUT_QUEUE_SURFACE:
            with self.subTest(name=name):
                self.assertTrue(hasattr(CoordinatorInputQueue, name))
                self.assertTrue(hasattr(speech_client._InputQueue, name))

    def test_every_client_request_is_one_the_service_serves(self):
        with open(os.path.join(SERVICES, "speech_client.py")) as handle:
            client_source = handle.read()
        with open(os.path.join(SERVICES, "speech_service.py")) as handle:
            service_source = handle.read()
        requested = set(re.findall(r'_(?:request|roundtrip)\(\s*"([a-z_]+)"', client_source))
        self.assertGreater(len(requested), 20)
        for op in sorted(requested):
            with self.subTest(op=op):
                self.assertIn(f'op == "{op}"', service_source)


class SpeakingTests(ClientCase):
    def test_reply_is_queued_played_and_reported_finished(self):
        self.assertFalse(self.client.speaking)
        self.assertTrue(self.client.input_queue.empty())

        self.assertTrue(self.final("Hello there.", 1, "one", waiting_playback_kind="final"))

        self.assertTrue(self.client.speaking)
        self.assertTrue(self.client.has_pending_speech)
        self.assertFalse(self.client.input_queue.empty())
        self.assertFalse(self.client.playing)
        self.assertEqual(self.client.queue_depth, 1)
        self.client.play()
        wait_until(lambda: self.finished == ["completed"], message="the reply to finish")
        self.assertFalse(self.client.speaking)
        self.assertEqual(self.client.queue_depth, 0)
        self.assertEqual(self.spoken(), [("Hello there.", True)])
        coverage = self.client.played_coverage(1, "one")
        self.assertEqual([item["spoken_text"] for item in coverage], ["Hello there."])
        self.assertTrue(self.client.replay())
        wait_until(lambda: len(self.spoken()) == 2, message="the replay")

    def test_queue_items_the_bridge_puts_are_accepted(self):
        item = {
            "text": "A stored reply.",
            "display_text": "A stored reply.",
            "_speech_intent_spec": {"dedup_key": "queued-reply:session-a:1", "session_key": "session-a"},
        }
        self.assertTrue(self.client.input_queue.put(item))
        self.assertFalse(self.client.input_queue.put(item), "the same reply was queued twice")
        self.assertTrue(self.client.input_queue.put("Plain text."))
        self.assertEqual(self.client.session_playback_states(), {"session-a": "play"})
        self.assertFalse(self.client.control_session("session-b", "play"))
        self.assertTrue(self.client.control_session("session-a", "play"))
        wait_until(lambda: self.spoken() == [("A stored reply.", True)], message="the session's reply")

    def test_stale_speech_is_refused(self):
        self.set_command(2, "two")
        accepted = self.client.input_queue.submit_text(
            "Too late.", command_seq=1, command_id="one", source="messenger", kind="handoff",
        )
        self.assertFalse(accepted)
        self.assertFalse(self.client.speaking)

    def test_stop_skip_and_new_turn_reach_the_queue(self):
        self.assertTrue(self.final(LONG, 1, "one"))
        self.client.play()
        wait_until(lambda: self.client.playing, message="the reply to play")
        self.wait_at_output()

        self.client.stop_playback(reason="interrupt")
        wait_until(lambda: not self.client.playing, message="the reply to stop")
        self.assertEqual(self.client.queue_depth, 1, "a stopped reply stays queued")

        self.set_command(2, "two")
        self.client.new_turn(2, "two")
        self.client.skip()
        wait_until(lambda: self.client.queue_depth == 0, message="the reply to be skipped")
        self.assertFalse(self.client.speaking)
        self.assertEqual(self.client.session_playback_states(), {})

    def test_read_out_and_play_or_replay(self):
        self.assertFalse(self.client.play_or_replay())
        self.assertFalse(self.client.read_out("  "))
        self.assertTrue(self.client.read_out("A stored reply.", session_key="session-a"))
        wait_until(lambda: self.spoken() == [("A stored reply.", True)], message="the text to play")
        wait_until(lambda: not self.client.speaking, message="the queue to empty")
        self.assertTrue(self.client.play_or_replay())
        wait_until(lambda: len(self.spoken()) == 2, message="the replay")

    def test_diagnostics_reach_the_event_log(self):
        self.client.note_play_control(option_detected_at=10.0, fifo_received_at=10.5)
        self.client.note_visual_acknowledgement(option_detected_at=10.0, acknowledged_at=10.6)
        self.client.record_realization(1, "one", lifecycle_role="progress", decision="suppress", reason="covered")
        self.client.record_messenger_stage("messenger_submitted", 1, "one", provider="claude")
        self.assertTrue(self.client.record_missing_outcome(1, "one", "turn_ended", signals=("idle",)))
        self.assertFalse(self.client.record_missing_outcome(1, "one", "turn_ended"))
        self.client.arm_waiting_playback(1, "one")
        self.client.reload_config()

        with open(self.env["SPEECH_EVENT_LOG"]) as handle:
            events = [json.loads(line)["event"] for line in handle]
        self.assertEqual(
            events,
            ["option_detected", "fifo_play_received", "visual_play_acknowledged", "realization",
             "messenger_submitted", "missing_outcome"],
        )

    def test_shutdown_ends_the_service(self):
        process = self.client._process
        self.client.shutdown()
        self.assertEqual(process.poll(), 0)
        started = time.monotonic()
        self.assertFalse(self.client.speaking)
        self.assertFalse(self.client.input_queue.submit_text("Too late."))
        self.assertLess(time.monotonic() - started, 1.0, "a closed client made its caller wait")


class RestartTests(ClientCase):
    def test_crashed_service_is_restarted_with_its_queue(self):
        texts = [LONG, "Second reply.", "Third reply."]
        for number, text in enumerate(texts):
            self.assertTrue(self.stored(text, f"queued-reply:{number}"))
        self.client.play()
        wait_until(lambda: self.client.playing, message="the first reply to play")

        previous = self.kill_service()
        self.wait_restarted(previous)

        self.assertEqual(len(self.restarts), 1, "the overlay was not cleared once")
        # The replies are queued again in order; none plays by itself.
        self.assertEqual(self.client.queue_depth, 3)
        self.assertFalse(self.client.playing)
        before = len(self.spoken())
        started = len(self.at_output())
        self.client.play()
        wait_until(lambda: self.client.playing, message="the first reply to play again")
        self.assertEqual(self.wait_at_output(started), LONG_FIRST)
        waiting = self.waiting()
        self.client.skip()
        for expected in texts[1:]:
            wait_until(lambda: not self.client.playing and self.client.queue_depth, message="the next reply")
            # Play once the worker has the reply: see "playback" in the protocol document.
            wait_until(lambda: self.waiting() > waiting, message=f"{expected!r} to wait for play")
            waiting = self.waiting()
            self.client.play()
            wait_until(lambda: self.spoken()[-1:] == [(expected, True)], message=f"{expected!r} to play")
        self.assertEqual(self.spoken()[before][0], LONG_FIRST)
        wait_until(lambda: self.client.queue_depth == 0, message="the queue to empty")

    def test_heard_replies_are_not_queued_again(self):
        self.assertTrue(self.stored("First reply.", "queued-reply:0"))
        self.assertTrue(self.stored("Second reply.", "queued-reply:1"))
        self.client.play()
        wait_until(lambda: self.spoken() == [("First reply.", True)], message="the first reply")
        wait_until(lambda: not self.client.playing, message="playback to end")

        previous = self.kill_service()
        self.wait_restarted(previous)

        self.assertEqual(self.client.queue_depth, 1)
        self.client.play()
        wait_until(lambda: self.spoken()[-1] == ("Second reply.", True), message="the second reply")
        self.assertEqual(len(self.spoken()), 2)

    def test_request_made_during_a_restart_waits_for_the_new_service(self):
        previous = self.kill_service()
        wait_until(lambda: not self.client._ready.is_set(), message="the client to notice")

        self.assertTrue(self.stored("Said during the restart.", "queued-reply:0"))

        self.assertNotEqual(self.client.instance_id, previous)
        self.assertEqual(self.client.queue_depth, 1)

    def test_devices_are_attached_again_after_a_restart(self):
        device = FakeDevice("device-1")
        mirror = FakeDevice("device-2")
        self.client.attach_remote_sink(device)
        self.client.attach_remote_mirror(mirror)

        previous = self.kill_service()
        self.wait_restarted(previous)

        self.assertTrue(self.final("For the phone.", 1, "one"))
        self.assertEqual([frame["text"] for frame in device.speeches], ["For the phone."])
        self.assertEqual(self.client.queue_depth, 1)
        self.assertFalse(self.client.speaking, "the reply went to the Mac queue")

    def test_speech_is_given_up_after_repeated_crashes(self):
        for _ in range(speech_client.MAX_RESTARTS):
            previous = self.kill_service()
            self.wait_restarted(previous)
        self.kill_service()
        wait_until(lambda: self.client._failed, message="the client to give up")

        started = time.monotonic()
        self.assertFalse(self.client.speaking)
        self.assertFalse(self.stored("Nobody is listening.", "queued-reply:0"))
        self.client.play()
        self.assertLess(time.monotonic() - started, 1.0, "a failed service made its caller wait")
        self.assertEqual(len(self.restarts), speech_client.MAX_RESTARTS)


class StartTests(ClientCase):
    def test_start_fails_when_the_service_exits(self):
        client = self.make_client([sys.executable, "-c", "import sys; sys.exit(3)"])
        with self.assertRaisesRegex(SpeechServiceError, "status 3"):
            client.start()

    def test_start_fails_when_the_command_does_not_exist(self):
        client = self.make_client([os.path.join(self.root, "no-such-service")])
        with self.assertRaises(SpeechServiceError):
            client.start()

    def test_start_fails_when_the_service_never_listens(self):
        client = SpeechServiceClient(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            os.path.join(self.root, "silent.sock"),
            env=self.env,
            start_timeout=0.3,
        )
        self.addCleanup(client.close)
        with self.assertRaisesRegex(SpeechServiceError, "did not open its socket"):
            client.start()
        self.assertIsNone(client._process, "the silent process was left running")


class RemoteTests(ClientCase):
    def test_sink_calls_reach_the_device_session(self):
        device = FakeDevice("device-1")
        self.client.attach_remote_sink(device)

        self.assertTrue(self.final("One sentence. Then another.", 1, "one"))

        self.assertEqual(len(device.speeches), 1)
        frame = device.speeches[0]
        self.assertEqual(
            {key: frame[key] for key in ("kind", "source", "text", "relay_command_seq", "audio")},
            {"kind": "final", "source": "orchestrator", "text": "One sentence. Then another.",
             "relay_command_seq": 1, "audio": True},
        )
        wait_until(lambda: device.audio and device.audio[-1][1].last, message="the last audio part")
        self.assertEqual({seq for seq, _ in device.audio}, {frame["seq"]})
        parts = [part for _, part in device.audio]
        self.assertTrue(all(isinstance(part, AudioPart) for part in parts))
        self.assertEqual([part.part for part in parts], list(range(len(parts))))
        self.assertEqual(parts[-1].parts, len(parts))
        self.assertTrue(all(part.data and part.format == "aac" and part.sample_rate == 24000 for part in parts))
        self.assertFalse(self.client.speaking, "the reply was queued for the Mac's speaker")
        self.assertEqual(self.client.queue_depth, 1)

        self.assertTrue(self.client.remote_ack("device-1", frame["seq"], True))
        self.assertFalse(self.client.remote_ack("device-1", frame["seq"], True))
        self.assertEqual(self.client.queue_depth, 0)

    def test_skip_reaches_the_device_and_detach_returns_the_reply(self):
        device = FakeDevice("device-1")
        self.client.attach_remote_sink(device)
        self.assertTrue(self.final("First reply.", 1, "one"))
        self.client.skip()
        self.assertEqual(device.controls, [("skip", "user_stop")])

        self.assertTrue(self.final("Second reply.", 2, "two"))
        self.client.detach_remote_sink("device-1", reason="remote_mode_off")

        self.assertTrue(self.client.speaking, "the unacknowledged reply did not return to the Mac")
        self.assertEqual(self.client.queue_depth, 1)
        # A detached device is no longer known to the client either.
        self.assertTrue(self.final("Third reply.", 3, "three"))
        self.assertEqual(len(device.speeches), 2)

    def test_mirror_is_sent_the_text_and_a_sink_replaces_it(self):
        mirror = FakeDevice("device-1")
        self.client.attach_remote_mirror(mirror)
        self.assertTrue(self.final("For the Mac.", 1, "one"))
        wait_until(lambda: mirror.speeches, message="the mirrored text")
        self.assertEqual(mirror.speeches[0]["spoken_by"], "mac")
        self.assertNotIn("audio", mirror.speeches[0])
        self.assertTrue(self.client.speaking)

        sink = FakeDevice("device-1")
        self.client.attach_remote_sink(sink)
        self.assertTrue(self.final("For the phone.", 2, "two"))
        self.assertEqual([frame["text"] for frame in sink.speeches], ["For the phone."])
        self.assertEqual(len(mirror.speeches), 1)

        self.client.attach_remote_mirror(mirror)
        self.client.detach_remote_mirror("device-1")
        self.assertNotIn("device-1", self.client._remote_mirrors)

    def test_device_that_raises_refuses_the_speech(self):
        device = FakeDevice("device-1")
        device.speech = mock.Mock(side_effect=ValueError("unencodable frame"))
        self.client.attach_remote_sink(device)
        self.assertFalse(self.final("Cannot be sent.", 1, "one"))
        self.assertEqual(self.client.queue_depth, 0)


class BridgeControlTests(ClientCase):
    """The bridge's own FIFO control handling, driving the real service."""

    def control(self, line: str) -> None:
        handled = voice_bridge._handle_relay_control_message(
            line,
            self.client,
            command_path=os.path.join(self.root, "voice_cmd_ready"),
            meta_path=os.path.join(self.root, "voice_cmd_ready.meta"),
            state_path=self.state_path,
            event_log_path=None,
        )
        self.assertTrue(handled)

    def reply(self, text: str, seq: int, command_id: str) -> bool:
        self.set_command(seq, command_id)
        return voice_bridge._queue_tts_text(
            json.dumps({"text": text, "relay_command_seq": seq, "relay_command_id": command_id}),
            self.client.input_queue,
            command_path=os.path.join(self.root, "voice_cmd_ready"),
            state_path=self.state_path,
            source="orchestrator",
            kind="final",
            authoritative=True,
        )

    def test_reply_is_spoken_barge_in_stops_it_and_replay_repeats_it(self):
        self.assertTrue(self.reply(LONG, 1, "one"))
        self.assertFalse(self.reply(LONG, 1, "one"), "the same reply was queued twice")
        self.assertFalse(self.client.playing, "the reply played before the play gesture")

        # The play gesture speaks the waiting reply.
        self.control(f"__PLAY__:{time.time()}")
        wait_until(lambda: self.client.playing, message="the reply to be spoken")
        self.wait_at_output()

        # Talking over it stops the speech; the reply counts as heard.
        self.control("__TTS_STOP__")
        wait_until(lambda: not self.client.playing, message="barge-in to stop the speech")
        wait_until(lambda: self.spoken() == [(LONG_FIRST, False)], message="the sentence to be cut off")
        self.assertEqual(self.client.queue_depth, 0)
        heard = len(self.at_output())
        time.sleep(0.3)
        self.assertEqual(len(self.at_output()), heard, "speech went on after the barge-in")

        # Replay speaks it again from the start; cancel dismisses it.
        self.control("__REPLAY__")
        self.assertEqual(self.wait_at_output(heard), LONG_FIRST)
        self.control("__CANCEL__")
        wait_until(lambda: not self.client.playing, message="cancel to stop the replay")
        wait_until(lambda: self.finished == ["user_stop"], message="the dismissal to be reported")

    def test_play_gesture_replays_when_nothing_is_waiting(self):
        self.assertTrue(self.reply("A short reply.", 1, "one"))
        self.control("__PLAY__")
        wait_until(lambda: self.finished == ["completed"], message="the reply to finish")

        self.control("__PLAY__")

        wait_until(lambda: self.spoken() == [("A short reply.", True)] * 2, message="the replay")

    def test_reply_of_a_superseded_command_is_dropped(self):
        self.set_command(2, "two")
        accepted = voice_bridge._queue_tts_text(
            json.dumps({"text": "Too late.", "relay_command_seq": 1, "relay_command_id": "one"}),
            self.client.input_queue,
            command_path=os.path.join(self.root, "voice_cmd_ready"),
            state_path=self.state_path,
            source="messenger",
            kind="handoff",
        )
        self.assertFalse(accepted)
        self.assertFalse(self.client.speaking)

    def test_cancel_with_nothing_playing_still_reports_the_dismissal(self):
        self.assertTrue(self.reply("A short reply.", 1, "one"))
        with mock.patch.object(voice_bridge, "_on_reply_finished") as finished:
            self.control("__CANCEL__")
        finished.assert_called_once_with("dismissed", self.client)
        self.assertFalse(self.client.speaking)


class BridgeWiringTests(unittest.TestCase):
    def test_service_reads_the_bridges_config(self):
        with mock.patch.object(sys, "argv", ["voice_bridge.py", "--config", "/tmp/a config.toml", "--relay"]), \
                mock.patch.dict(os.environ, {"RELAY_SPEECH_SERVICE_CMD": "", "RELAY_SPEECH_RUNTIME": "python"}):
            command = voice_bridge._speech_service_command()
        self.assertEqual(command[0], sys.executable)
        self.assertEqual(command[1], os.path.join(SERVICES, "speech_service.py"))
        self.assertEqual(command[2:], ["--config", "/tmp/a config.toml"])

    def test_the_rust_service_is_the_default_and_python_the_fallback(self):
        root = tempfile.mkdtemp(prefix="rsb-", dir="/tmp")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        binary = os.path.join(root, "relay speech")
        with open(binary, "w") as handle:
            handle.write("#!/bin/sh\n")
        os.chmod(binary, 0o755)
        python = [sys.executable, os.path.join(SERVICES, "speech_service.py")]
        cases = (
            ({"RELAY_SPEECH_BINARY": binary}, [binary, "--config", "/tmp/c.toml"]),
            ({"RELAY_SPEECH_BINARY": binary, "RELAY_SPEECH_RUNTIME": " Python "}, [*python, "--config", "/tmp/c.toml"]),
            # Without the binary, as in a source checkout, the Python service speaks.
            ({"RELAY_SPEECH_BINARY": os.path.join(root, "missing")}, [*python, "--config", "/tmp/c.toml"]),
        )
        for environment, expected in cases:
            with self.subTest(environment=environment), \
                    mock.patch.object(sys, "argv", ["voice_bridge.py", "--config", "/tmp/c.toml", "--relay"]), \
                    mock.patch.dict(os.environ, {"RELAY_SPEECH_SERVICE_CMD": "", "RELAY_SPEECH_RUNTIME": "", **environment}), \
                    mock.patch("sys.stderr"):
                self.assertEqual(voice_bridge._speech_service_command(), expected)

    def test_service_command_can_be_replaced(self):
        with mock.patch.object(sys, "argv", ["voice_bridge.py", "--relay"]), \
                mock.patch.dict(os.environ, {"RELAY_SPEECH_SERVICE_CMD": "'/opt/relay speech/service' --flag"}):
            self.assertEqual(voice_bridge._speech_service_command(), ["/opt/relay speech/service", "--flag"])

    def test_bridge_speaks_in_process_when_the_service_cannot_start(self):
        root = tempfile.mkdtemp(prefix="rsc-", dir="/tmp")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        with mock.patch.object(voice_bridge, "SPEECH_SERVICE_SOCK", os.path.join(root, "speech.sock")), \
                mock.patch.dict(os.environ, {"RELAY_SPEECH_SERVICE_CMD": "/usr/bin/false"}), \
                mock.patch.object(sys, "argv", ["voice_bridge.py", "--relay"]), \
                mock.patch("sys.stderr"):
            self.assertIsNone(voice_bridge._start_speech_service(lambda reason: None))

    def test_service_mode_is_the_default_and_legacy_is_the_rollback(self):
        script = "import voice_bridge; print(voice_bridge.SPEECH_SERVICE_MODE)"
        for value, expected in ((None, "service"), ("legacy", "legacy"), (" Legacy ", "legacy")):
            with self.subTest(value=value):
                env = {key: item for key, item in os.environ.items() if key != "RELAY_SPEECH_SERVICE_MODE"}
                if value is not None:
                    env["RELAY_SPEECH_SERVICE_MODE"] = value
                result = subprocess.run(
                    [sys.executable, "-c", script], cwd=SERVICES, env=env, capture_output=True, text=True,
                )
                self.assertEqual(result.stdout.strip(), expected, result.stderr)

    def test_importing_the_bridge_loads_no_voice_model_libraries(self):
        script = (
            "import sys, voice_bridge\n"
            "heavy = sorted(name for name in sys.modules "
            "if name.split('.')[0] in ('numpy', 'kokoro_onnx', 'onnxruntime'))\n"
            "print(heavy)\n"
        )
        result = subprocess.run([sys.executable, "-c", script], cwd=SERVICES, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "[]")


class ControlSocketTests(unittest.TestCase):
    """A service that is still stopping must not take its successor's control socket."""

    class Worker:
        def __init__(self):
            self.input_queue = queue.Queue()
            self.stopped = False

        def stop_playback(self, *, reason="user_stop"):
            del reason
            self.stopped = True

        def shutdown(self):
            pass

    def coordinator(self, path: str) -> SpeechCoordinator:
        coordinator = SpeechCoordinator(self.Worker(), is_current=lambda seq, command_id: True,
                                        control_socket_path=path)
        self.addCleanup(coordinator.shutdown)
        return coordinator

    def test_old_coordinator_leaves_the_path_its_successor_bound(self):
        root = tempfile.mkdtemp(prefix="rsc-", dir="/tmp")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        path = os.path.join(root, "tts_control.sock")
        old = self.coordinator(path)
        wait_until(lambda: os.path.exists(path), message="the first control socket")
        first = os.stat(path).st_ino
        sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(sender.close)

        def send(command):
            # bind() makes the file a moment before the socket takes datagrams.
            try:
                sender.sendto(command, path)
            except ConnectionRefusedError:
                return False
            return True

        # A command the first coordinator handles shows its control loop is
        # listening, so it has recorded the socket it bound.
        wait_until(lambda: send(b"stop"), message="the first control socket to take a command")
        wait_until(lambda: old.worker.stopped, message="the first coordinator to listen")
        self.coordinator(path)

        def inode():
            # The successor unlinks the old socket before it binds its own.
            try:
                return os.stat(path).st_ino
            except FileNotFoundError:
                return None

        wait_until(lambda: inode() not in (None, first), message="the second control socket")

        old.shutdown()
        old._control_thread.join(timeout=10)
        self.assertFalse(old._control_thread.is_alive(), "the old control loop did not stop")

        self.assertTrue(os.path.exists(path), "the old coordinator removed its successor's socket")
        wait_until(lambda: send(b"play"), message="the second control socket to take a command")

    def test_coordinator_removes_its_own_socket(self):
        root = tempfile.mkdtemp(prefix="rsc-", dir="/tmp")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        path = os.path.join(root, "tts_control.sock")
        coordinator = self.coordinator(path)
        wait_until(lambda: os.path.exists(path), message="the control socket")
        coordinator.shutdown()
        self.assertFalse(os.path.exists(path))


class FreshnessParityTests(unittest.TestCase):
    """The service judges a command from the state file exactly as the bridge does."""

    STATES = (
        {},
        {"relay_command_seq": 2, "relay_command_id": "two"},
        {"relay_command_seq": "2", "relay_command_id": "two"},
        {"relay_command_seq": 2, "relay_command_id": ""},
        {"relay_command_seq": "soon", "relay_command_id": "two"},
        {"relay_command_seq": 3, "relay_command_id": "three", "work_disposition": {
            "route": "continue_current", "authorization_effect": "preserve", "cancellation_scope": "none"}},
        {"relay_command_seq": 3, "relay_command_id": "three", "work_disposition": {
            "route": "continue_current", "authorization_effect": "preserve"}},
        {"relay_command_seq": 3, "relay_command_id": "three", "work_disposition": {
            "route": "continue_current", "authorization_effect": "preserve", "cancellation_scope": "all_work"}},
        {"relay_command_seq": 3, "relay_command_id": "three", "work_disposition": {
            "route": "replace_current", "authorization_effect": "preserve", "cancellation_scope": "none"}},
        {"relay_command_seq": 3, "relay_command_id": "three", "cancelled_intent_ids": ["intent-1"],
         "work_disposition": {"route": "continue_current", "authorization_effect": "preserve"}},
        {"relay_command_seq": 1, "relay_command_id": "one", "work_disposition": {
            "route": "continue_current", "authorization_effect": "preserve"}},
        {"relay_command_seq": 3, "relay_command_id": "three", "work_disposition": "preserve"},
    )
    COMMANDS = ((2, "two", "intent-1"), (2, "two", "intent-2"), (3, "three", ""), (None, "two", ""), (2, None, ""))

    def test_service_agrees_with_the_bridge(self):
        root = tempfile.mkdtemp(prefix="rsc-", dir="/tmp")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        path = os.path.join(root, "state.json")
        for state in self.STATES:
            with open(path, "w") as handle:
                json.dump(state, handle)
            loaded = speech_service.read_command_state(path)
            for seq, command_id, intent_id in self.COMMANDS:
                with self.subTest(state=state, command=(seq, command_id, intent_id)):
                    self.assertEqual(
                        speech_service.command_is_current(loaded, seq, command_id),
                        voice_bridge._relay_command_current(seq, command_id, state_path=path),
                    )
                    self.assertEqual(
                        speech_service.command_is_preserved(loaded, seq, command_id, intent_id),
                        voice_bridge._relay_command_current_or_preserved(
                            {"relay_command_seq": seq, "relay_command_id": command_id, "intent_id": intent_id},
                            state_path=path,
                        ),
                    )

    def test_unreadable_state_names_no_command(self):
        root = tempfile.mkdtemp(prefix="rsc-", dir="/tmp")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        path = os.path.join(root, "state.json")
        self.assertEqual(speech_service.read_command_state(path), {})
        for content in ("{not json", "[1, 2]", ""):
            with open(path, "w") as handle:
                handle.write(content)
            self.assertEqual(speech_service.read_command_state(path), {})


if __name__ == "__main__":
    unittest.main()
