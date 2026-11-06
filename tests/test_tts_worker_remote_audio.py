"""RR-457: TTSWorker voices Relay Remote replies without the Mac's speaker."""

from __future__ import annotations

import base64
import json
import math
import os
import queue
import struct
import subprocess
import sys
import tempfile
import threading
import types
import unittest
import wave
from pathlib import Path
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "services"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.modules.setdefault("numpy", types.SimpleNamespace(asarray=lambda s: s, int16=object()))

import relay_remote_protocol as proto  # noqa: E402
import remote_audio  # noqa: E402
import tts_worker  # noqa: E402
from speech_coordinator import SpeechCoordinator  # noqa: E402
from speech_player import SpeechPlayer  # noqa: E402
from tts_worker import RemoteSpeechJob, TTSWorker  # noqa: E402
import test_relay_remote as remote_tests  # noqa: E402
import test_speech_coordinator as coordinator_tests  # noqa: E402

wait_until = remote_tests.wait_until
RAW_PART = proto.MAX_AUDIO_DATA_BYTES // 4 * 3


def write_tone(path: str, seconds: float, rate: int = remote_audio.SAMPLE_RATE) -> None:
    frames = b"".join(
        struct.pack("<h", int(12000 * math.sin(2 * math.pi * 220 * i / rate)))
        for i in range(int(seconds * rate))
    )
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(frames)


class RemoteWorkerTestCase(unittest.TestCase):
    """A real TTSWorker whose synthesiser and encoder are fakes."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir="/tmp", prefix="rr457-")
        self.addCleanup(temp.cleanup)
        self.root = temp.name
        self.timeline: list[tuple] = []
        self.texts: dict[str, str] = {}
        self.opened: list[str] = []
        self.encoded_size = lambda text: 1000
        self.during_synthesis = lambda text: None
        self.synthesizing = 0
        self.synthesizing_lock = threading.Lock()
        # Runs before the temporary folder is removed (cleanups are LIFO).
        self.addCleanup(self.wait_for_abandoned_synthesis)
        lease = mock.patch.object(tts_worker, "VoiceAudioLease", side_effect=lambda *a, **k: self.opened.append("lease"))
        lease.start()
        self.addCleanup(lease.stop)
        self.worker = self.make_worker()

    def make_worker(self) -> TTSWorker:
        worker = TTSWorker.__new__(TTSWorker)
        worker._shutdown = False
        worker._kokoro = object()
        worker._voice = "am_puck"
        worker._rate = 1.0
        worker._selection_epoch = 0
        worker._synth_lock = threading.Lock()
        worker._render_local = threading.local()
        worker._remote_jobs = queue.Queue()
        worker._remote_encoding_failed = False
        worker._remote_encode = self.encode
        worker._synthesize_to_wav = lambda text: self.synthesize(worker, text)
        # A real player whose audio device would fail the test if it opened.
        worker._speech_player = SpeechPlayer(output_factory=lambda *a, **k: self.opened.append("device"))
        self.addCleanup(setattr, worker, "_shutdown", True)
        return worker

    def synthesize(self, worker, text: str) -> str:
        with self.synthesizing_lock:
            self.synthesizing += 1
        try:
            selection = worker._render_local.selection
            self.timeline.append(("synthesize", text, selection.voice))
            self.during_synthesis(text)
            fd, path = tempfile.mkstemp(suffix=".wav", dir=self.root)
            os.close(fd)
            write_tone(path, 0.05)
            self.texts[path] = text
            return path
        finally:
            with self.synthesizing_lock:
                self.synthesizing -= 1

    def wait_for_abandoned_synthesis(self) -> None:
        """A cancelled sentence's synthesis thread may still write, then remove, its WAV."""
        wait_until(lambda: not self.synthesizing and not list(Path(self.root).glob("*.wav")))

    def encode(self, wav_path: str) -> bytes:
        text = self.texts[wav_path]
        self.timeline.append(("encode", text))
        return text.encode().ljust(self.encoded_size(text), b"\0")

    def job(self, text: str) -> tuple[RemoteSpeechJob, list, list]:
        parts, failures = [], []
        cancelled = threading.Event()
        self.cancel_job = cancelled.set

        def emit(part):
            self.timeline.append(("emit", part.part))
            parts.append(part)

        job = RemoteSpeechJob(
            text=text,
            utterance_id="utterance-1",
            cancelled=cancelled.is_set,
            emit=emit,
            failed=failures.append,
        )
        return job, parts, failures


class RemoteSynthesisTests(RemoteWorkerTestCase):
    def test_each_sentence_is_emitted_before_the_next_is_synthesised(self):
        job, parts, failures = self.job("First one. Second one. Third one.")

        self.worker._voice_remote(job)

        self.assertEqual(self.timeline, [
            ("synthesize", "First one.", "am_puck"), ("encode", "First one."), ("emit", 0),
            ("synthesize", "Second one.", "am_puck"), ("encode", "Second one."), ("emit", 1),
            ("synthesize", "Third one.", "am_puck"), ("encode", "Third one."), ("emit", 2),
        ])
        self.assertEqual([(p.part, p.parts, p.last) for p in parts], [(0, 0, False), (1, 0, False), (2, 3, True)])
        self.assertEqual([base64.b64decode(p.data).rstrip(b"\0") for p in parts],
                         [b"First one.", b"Second one.", b"Third one."])
        self.assertEqual({(p.format, p.sample_rate) for p in parts}, {("aac", 24000)})
        self.assertEqual(failures, [])
        self.assertEqual(self.opened, [])

    def test_a_sentence_is_split_into_parts_at_the_size_cap(self):
        self.encoded_size = lambda text: 2 * RAW_PART + 100 if text.startswith("Long") else 10
        job, parts, _ = self.job("Long sentence first. Then short.")

        self.worker._voice_remote(job)

        self.assertEqual([(p.part, p.parts, p.last) for p in parts],
                         [(0, 0, False), (1, 0, False), (2, 0, False), (3, 4, True)])
        self.assertEqual([len(p.data) for p in parts[:2]], [proto.MAX_AUDIO_DATA_BYTES] * 2)
        self.assertTrue(all(len(p.data) <= proto.MAX_AUDIO_DATA_BYTES for p in parts))
        long_audio = b"".join(base64.b64decode(p.data) for p in parts[:3])
        self.assertEqual(long_audio, b"Long sentence first.".ljust(2 * RAW_PART + 100, b"\0"))
        for part in parts:
            proto.encode(proto.SpeechAudio(7, part.part, part.parts, part.format, part.sample_rate, part.data))

    def test_cancellation_stops_before_the_next_sentence_without_ending_the_stream(self):
        job, parts, failures = self.job("One. Two. Three.")
        self.during_synthesis = lambda text: self.cancel_job() if text == "Two." else None

        self.worker._voice_remote(job)

        self.assertEqual([p.part for p in parts], [0])
        self.assertNotIn(("synthesize", "Three.", "am_puck"), self.timeline)
        self.assertNotIn(("encode", "Two."), self.timeline)
        self.assertEqual(failures, [])

    def test_encoding_failure_ends_the_stream_and_turns_remote_audio_off(self):
        def broken(path):
            raise remote_audio.EncodingError("encoding_failed")

        self.worker._remote_encode = broken
        self.assertTrue(self.worker.remote_audio_available())
        job, parts, failures = self.job("Only one. Never reached.")

        self.worker._voice_remote(job)

        self.assertEqual([(p.part, p.parts, p.last, p.data) for p in parts], [(0, 1, True, "")])
        self.assertEqual(failures, ["encoding_failed"])
        self.assertFalse(self.worker.remote_audio_available())
        self.assertNotIn(("synthesize", "Never reached.", "am_puck"), self.timeline)

    def test_an_unexpected_error_still_ends_the_stream_with_a_fixed_reason(self):
        split = remote_audio.split

        def broken(data):
            if data.rstrip(b"\0") == b"Second.":
                raise OSError("/private/path/that/must/not/leak")
            return split(data)

        job, parts, failures = self.job("First. Second. Third.")

        with mock.patch.object(remote_audio, "split", side_effect=broken):
            self.worker._voice_remote(job)

        self.assertEqual([(p.part, p.parts, p.last, bool(p.data)) for p in parts],
                         [(0, 0, False, True), (1, 2, True, False)])
        self.assertEqual(failures, ["synthesis_failed"])
        self.assertTrue(self.worker.remote_audio_available())

    def test_a_missing_voice_means_no_remote_audio(self):
        self.worker._kokoro = None
        self.assertFalse(self.worker.remote_audio_available())


@unittest.skipUnless(remote_audio.encoder_available(), "afconvert not available")
class RealEncoderTests(unittest.TestCase):
    def test_emitted_parts_decode_to_audio_of_the_expected_duration(self):
        temp = tempfile.TemporaryDirectory(prefix="rr457-")
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        worker = TTSWorker.__new__(TTSWorker)
        worker._kokoro = object()
        worker._voice, worker._rate, worker._selection_epoch = "am_puck", 1.0, 0
        worker._synth_lock = threading.Lock()
        worker._render_local = threading.local()
        worker._remote_encoding_failed = False
        worker._remote_encode = remote_audio.encode
        seconds = 0.6

        def synthesize(text):
            fd, path = tempfile.mkstemp(suffix=".wav", dir=root)
            os.close(fd)
            write_tone(path, seconds)
            return path

        worker._synthesize_to_wav = synthesize
        parts = []
        worker._voice_remote(RemoteSpeechJob("First sentence. Second sentence.", "u", lambda: False,
                                             parts.append, self.fail))

        self.assertEqual([p.last for p in parts], [False, True])

        def decoded_seconds(data: bytes, name: str) -> float:
            (root / f"{name}.aac").write_bytes(data)
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16", str(root / f"{name}.aac"),
                            str(root / f"{name}.wav")], check=True)
            with wave.open(str(root / f"{name}.wav")) as handle:
                self.assertEqual((handle.getnchannels(), handle.getframerate()), (1, 24000))
                return handle.getnframes() / handle.getframerate()

        # Encoder priming and frame padding add under 150 ms per sentence.
        first = decoded_seconds(base64.b64decode(parts[0].data), "first")
        self.assertGreaterEqual(first, seconds)
        self.assertLess(first, seconds + 0.15)
        stream = decoded_seconds(b"".join(base64.b64decode(p.data) for p in parts), "stream")
        self.assertGreaterEqual(stream, 2 * seconds)
        self.assertLess(stream, 2 * seconds + 0.3)


class RemoteVoiceEndToEndTests(RemoteWorkerTestCase, remote_tests.ServerTestCase):
    """The worker, the coordinator and a scripted phone on the bridge socket."""

    def setUp(self):
        remote_tests.ServerTestCase.setUp(self)
        RemoteWorkerTestCase.setUp(self)
        self.now = 1000.0
        self.log = Path(self.root) / "speech-events.jsonl"
        self.worker.input_queue = queue.Queue()
        self.worker._speech_eligibility = self.worker._speech_observer = None
        self.worker.skip = self.worker.stop_playback = lambda **kwargs: None
        self.coordinator = SpeechCoordinator(self.worker, is_current=lambda seq, cid: True, event_log_path=self.log)
        voice = self.worker._voice_remote
        self.worker._voice_remote = lambda job: (voice(job), self.timeline.append(("done",)))
        threading.Thread(target=self.worker._remote_loop, daemon=True).start()
        self.server = self.start_server(speech=self.coordinator, clock=lambda: self.now)

    def connect(self, resume_after_seq=None):
        device = self.device()
        welcome = device.hello("phone-1", resume_after_seq)
        self.assertTrue(wait_until(lambda: "phone-1" in self.coordinator._remote_sinks))
        return device, welcome

    def events(self, name: str) -> list[dict]:
        if not self.log.exists():
            return []
        return [r for r in map(json.loads, self.log.read_text().splitlines()) if r["event"] == name]

    def reply(self, text: str):
        self.coordinator.submit(coordinator_tests.intent(kind="final", authoritative=True, text=text))

    def assert_nothing_else_sent(self, device) -> None:
        device.send(proto.Ping(9))
        self.assertEqual(device.recv(), proto.Pong(9))

    def test_reply_is_text_first_then_parts_per_sentence_with_no_mac_audio(self):
        device, _ = self.connect()

        self.reply("Hello there. How are you?")

        speech, first, second = device.recv(), device.recv(), device.recv()
        self.assertEqual((speech.text, speech.audio, speech.spoken_by), ("Hello there. How are you?", True, "phone"))
        self.assertEqual([(a.seq, a.part, a.parts, a.last) for a in (first, second)],
                         [(speech.seq, 0, 0, None), (speech.seq, 1, 2, True)])
        self.assertEqual(base64.b64decode(second.data).rstrip(b"\0"), b"How are you?")
        self.assert_nothing_else_sent(device)
        self.assertEqual(self.opened, [])
        self.assertTrue(self.worker.input_queue.empty())
        latency = self.events("remote_first_audio")
        self.assertEqual([record["remote_seq"] for record in latency], [speech.seq])
        self.assertGreaterEqual(latency[0]["submit_to_first_audio_ms"], 0)
        self.assertNotIn("Hello there", self.log.read_text())

    def test_stop_cancels_remaining_sentences_and_sends_speech_control(self):
        device, _ = self.connect()
        reached, release = threading.Event(), threading.Event()

        def hold(text):
            if text == "Two.":
                reached.set()
                release.wait(3)

        self.during_synthesis = hold
        self.reply("One. Two. Three.")
        speech, first = device.recv(), device.recv()
        self.assertEqual((first.seq, first.part), (speech.seq, 0))
        self.assertTrue(reached.wait(3))

        self.coordinator.stop()
        release.set()

        control = device.recv()
        self.assertEqual((control.seq, control.action), (speech.seq + 1, "stop"))
        self.assertTrue(wait_until(lambda: ("done",) in self.timeline))
        self.assert_nothing_else_sent(device)
        self.assertNotIn(("synthesize", "Three.", "am_puck"), self.timeline)

    def test_reconnect_replays_the_text_frame_with_its_audio_parts(self):
        device, _ = self.connect()
        device.close()
        self.assertTrue(wait_until(lambda: self.server.session("phone-1").conn is None))

        self.reply("Said while away. Still away.")
        self.assertTrue(wait_until(lambda: ("done",) in self.timeline))

        again, welcome = self.connect(resume_after_seq=0)
        self.assertEqual((welcome.server_seq, welcome.dropped), (1, False))
        replayed = [again.recv(), again.recv(), again.recv()]
        self.assertEqual([type(f).__name__ for f in replayed], ["Speech", "SpeechAudio", "SpeechAudio"])
        self.assertEqual([getattr(f, "part", None) for f in replayed], [None, 0, 1])
        self.assertTrue(replayed[0].audio)
        self.assertTrue(replayed[2].last)
        self.assert_nothing_else_sent(again)

    def test_encoding_failure_falls_back_to_text_frames_without_audio(self):
        def broken(path):
            raise remote_audio.EncodingError("encoding_failed")

        self.worker._remote_encode = broken
        device, _ = self.connect()

        self.reply("First reply.")
        speech, ended = device.recv(), device.recv()
        self.assertTrue(speech.audio)
        self.assertEqual((ended.seq, ended.part, ended.parts, ended.last, ended.data), (speech.seq, 0, 1, True, ""))
        self.assertTrue(wait_until(lambda: self.events("remote_audio_failed")))
        self.assertEqual(self.events("remote_audio_failed")[0]["reason"], "encoding_failed")

        self.coordinator.submit(coordinator_tests.intent(kind="progress", text="Second reply."))
        later = device.recv()
        self.assertEqual((later.text, later.audio), ("Second reply.", False))
        self.assert_nothing_else_sent(device)
        self.assertTrue(self.worker._remote_jobs.empty())


if __name__ == "__main__":
    unittest.main()
