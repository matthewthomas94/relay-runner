from __future__ import annotations

import array
import ctypes
import math
import os
import sys
import tempfile
import threading
import time
import unittest
import wave
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

import speech_player  # noqa: E402
from speech_player import PcmFormat, SpeechPlaybackError, SpeechPlayer, SpeechStream, SpeechChunk  # noqa: E402

SAMPLE_RATE = 24000
FMT = PcmFormat(SAMPLE_RATE)


class FakeOutput:
    """Stands in for AudioQueueOutput; the test pumps its render callback."""

    def __init__(self, fmt, rate, render, created, *, device_ready=None):
        self.fmt = fmt
        self.rate = rate
        self.render = render
        self.events = []
        self.error = None
        self.emitted = bytearray()
        self.started = threading.Event()
        self.device_ready = device_ready
        created.append(self)

    def start(self):
        # AudioQueueStart blocks while CoreAudio spins the device up.
        if self.device_ready is not None:
            self.device_ready.wait(2)
        self.events.append(("start", time.monotonic()))
        self.started.set()

    def pump(self, buffers=1, size=960):
        for _ in range(buffers):
            self.emitted += self.render(size)

    def fade_out(self, seconds=speech_player.FADE_SECONDS):
        self.events.append(("fade_out", time.monotonic(), seconds))

    def wait_faded(self, timeout):
        # Like the device, keep consuming buffers until the ramp has played out.
        deadline = self.events[-1][1] + self.events[-1][2] + speech_player.FADE_SETTLE_SECONDS
        while time.monotonic() < deadline:
            self.pump()
        return True

    def dispose(self):
        self.events.append(("dispose", time.monotonic()))

    def names(self):
        return [event[0] for event in self.events]


class SpeechStreamTests(unittest.TestCase):
    def test_chunks_render_back_to_back_and_hand_off_in_order(self):
        stream = SpeechStream()
        first, second = SpeechChunk(b"\x01" * 600), SpeechChunk(b"\x02" * 500)
        stream.submit(first)
        stream.submit(second)

        out = stream.render(400)
        self.assertEqual(out, b"\x01" * 400)
        self.assertFalse(first.done.is_set())

        out += stream.render(400)
        # No silence between sentences: the second chunk starts in the same buffer.
        self.assertEqual(out[400:], b"\x01" * 200 + b"\x02" * 200)
        self.assertTrue(first.done.is_set())
        self.assertFalse(second.done.is_set())

        out += stream.render(400)
        self.assertEqual(out[800:], b"\x02" * 300 + b"\x00" * 100)
        self.assertTrue(second.done.is_set())
        self.assertFalse(stream.pending)
        self.assertEqual(stream.render(8), b"\x00" * 8)

    def test_cancel_releases_every_waiting_chunk(self):
        stream = SpeechStream()
        chunks = [SpeechChunk(b"\x01" * 10) for _ in range(3)]
        for chunk in chunks:
            stream.submit(chunk)

        stream.cancel_all("playback_failed")

        for chunk in chunks:
            self.assertTrue(chunk.done.is_set())
            self.assertTrue(chunk.cancelled)
            self.assertEqual(chunk.error, "playback_failed")
        self.assertEqual(stream.render(4), b"\x00" * 4)


class SpeechPlayerTests(unittest.TestCase):
    def make_player(self, **kwargs):
        created = []
        device_ready = kwargs.pop("device_ready", None)
        player = SpeechPlayer(
            output_factory=lambda fmt, rate, render: FakeOutput(fmt, rate, render, created,
                                                                device_ready=device_ready),
            **kwargs)
        self.addCleanup(player.close)
        return player, created

    def output(self, created, index=0, *, started=True):
        deadline = time.monotonic() + 2
        while len(created) <= index and time.monotonic() < deadline:
            time.sleep(0.001)
        self.assertGreater(len(created), index, "output was not created")
        if started:
            self.assertTrue(created[index].started.wait(2), "output did not start")
        return created[index]

    def wait_for_events(self, output, names):
        deadline = time.monotonic() + 2
        while output.names() != names and time.monotonic() < deadline:
            time.sleep(0.001)
        self.assertEqual(output.names(), names)

    def test_one_output_serves_every_sentence_of_a_reply(self):
        player, created = self.make_player()
        chunks = []
        for index in range(30):
            chunks.append(player.submit(bytes([index + 1]) * 480, FMT, 1.3))
            self.output(created).pump(buffers=1, size=480)
            self.assertTrue(player.wait(chunks[-1]))

        self.assertEqual(len(created), 1, "the device must stay up across sentences")
        self.assertEqual(created[0].names(), ["start"])
        self.assertEqual(created[0].rate, 1.3)
        self.assertEqual(bytes(created[0].emitted), b"".join(bytes([i + 1]) * 480 for i in range(30)))

    def test_stop_fades_out_then_stops_within_latency_budget(self):
        player, created = self.make_player()
        chunk = player.submit(b"\x10" * SAMPLE_RATE * 2, FMT, 1.3)
        output = self.output(created)
        output.pump(buffers=3)
        waited = []
        waiter = threading.Thread(target=lambda: waited.append(player.wait(chunk)))
        waiter.start()

        requested = time.monotonic()
        player.stop()
        returned = time.monotonic()
        waiter.join(1)

        self.assertEqual(output.names(), ["start", "fade_out", "dispose"])
        _, fade_at, fade_seconds = output.events[1]
        disposed_at = output.events[2][1]
        self.assertGreaterEqual(fade_seconds, 0.010)
        self.assertGreaterEqual(disposed_at - fade_at, fade_seconds, "the ramp must finish before the stop")
        self.assertLessEqual(returned - requested, 0.100)
        self.assertEqual(waited, [False])
        self.assertFalse(player.active)
        # Once stopped, the fading output renders only silence.
        self.assertEqual(bytes(output.emitted[3 * 960:]), bytes(len(output.emitted) - 3 * 960))

    def test_stop_while_the_device_starts_does_not_wait_for_it(self):
        device_ready = threading.Event()
        player, created = self.make_player(device_ready=device_ready)
        chunk = player.submit(b"\x01" * 960, FMT, 1.3)
        output = self.output(created, started=False)

        requested = time.monotonic()
        player.stop()
        self.assertLessEqual(time.monotonic() - requested, 0.100)
        self.assertFalse(player.wait(chunk))
        self.assertFalse(player.active)

        device_ready.set()
        self.wait_for_events(output, ["start", "fade_out", "dispose"])

    def test_next_reply_after_stop_starts_a_fresh_output(self):
        player, created = self.make_player()
        player.submit(b"\x01" * 960, FMT, 1.3)
        self.output(created)
        player.stop()
        chunk = player.submit(b"\x02" * 960, FMT, 1.3)
        self.output(created, 1).pump()

        self.assertTrue(player.wait(chunk))
        self.assertEqual(len(created), 2)
        self.assertEqual(created[1].emitted, bytearray(b"\x02" * 960))

    def test_rate_change_retires_the_finished_tail_with_a_fade(self):
        player, created = self.make_player()
        first = player.submit(b"\x01" * 960, FMT, 1.3)
        self.output(created).pump()
        self.assertTrue(player.wait(first))

        second = player.submit(b"\x02" * 960, FMT, 1.0)
        self.output(created, 1).pump()

        self.assertTrue(player.wait(second))
        self.wait_for_events(created[0], ["start", "fade_out", "dispose"])
        self.assertEqual(created[1].rate, 1.0)
        self.assertEqual(created[1].emitted, bytearray(b"\x02" * 960))

    def test_output_stops_after_idle_but_holds_inside_a_reply(self):
        for hold in (False, True):
            with self.subTest(hold=hold), \
                    patch.object(speech_player, "MONITOR_SECONDS", 0.01), \
                    patch.object(speech_player, "IDLE_STOP_SECONDS", 0.05), \
                    patch.object(speech_player, "IDLE_HOLD_SECONDS", 5.0):
                player, created = self.make_player(keep_alive=lambda: hold)
                chunk = player.submit(b"\x01" * 960, FMT, 1.3)
                output = self.output(created)
                output.pump()
                self.assertTrue(player.wait(chunk))
                deadline = time.monotonic() + 0.4
                while time.monotonic() < deadline:
                    output.pump()
                    time.sleep(0.01)
                self.assertEqual(player.active, hold)
                # Only silence was queued, so the idle stop needs no fade.
                self.assertNotIn("fade_out", output.names())

    def test_stalled_output_fails_waiting_speech_instead_of_hanging(self):
        with patch.object(speech_player, "MONITOR_SECONDS", 0.01), \
                patch.object(speech_player, "STALL_SECONDS", 0.05):
            player, created = self.make_player()
            chunk = player.submit(b"\x01" * 960, FMT, 1.3)
            with self.assertRaisesRegex(SpeechPlaybackError, "playback_failed"):
                player.wait(chunk)
        self.assertFalse(player.active)
        self.assertEqual(created[0].names(), ["start", "dispose"])

    def test_output_start_failure_fails_the_waiting_chunk(self):
        class BrokenOutput(FakeOutput):
            def start(self):
                raise SpeechPlaybackError("AudioQueueStart failed (-50)")

        created = []
        player = SpeechPlayer(output_factory=lambda fmt, rate, render: BrokenOutput(fmt, rate, render, created))
        self.addCleanup(player.close)
        chunk = player.submit(b"\x01" * 960, FMT, 1.3)
        with self.assertRaisesRegex(SpeechPlaybackError, "playback_failed"):
            player.wait(chunk)
        self.assertEqual(created[0].names(), ["dispose"])
        self.assertFalse(player.active)

    def test_wav_input_and_unsupported_format(self):
        player, created = self.make_player()
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "speech.wav")
            with wave.open(path, "wb") as target:
                target.setnchannels(1)
                target.setsampwidth(2)
                target.setframerate(SAMPLE_RATE)
                target.writeframes(b"\x03\x00" * 480)
            chunk = player.submit_wav(path, 1.3)
            output = self.output(created)
            output.pump()
            self.assertTrue(player.wait(chunk))
            self.assertEqual(output.fmt, FMT)
            self.assertEqual(output.emitted, bytearray(b"\x03\x00" * 480))

            wide = os.path.join(root, "wide.wav")
            with wave.open(wide, "wb") as target:
                target.setnchannels(1)
                target.setsampwidth(4)
                target.setframerate(SAMPLE_RATE)
                target.writeframes(b"\x00" * 16)
            with self.assertRaisesRegex(SpeechPlaybackError, "unsupported_audio"):
                player.submit_wav(wide, 1.3)


def _audio_toolbox_available():
    try:
        speech_player._audio_toolbox()
    except SpeechPlaybackError:
        return False
    return True


class _SMPTETime(ctypes.Structure):
    _fields_ = [("mSubframes", ctypes.c_int16), ("mSubframeDivisor", ctypes.c_int16),
                ("mCounter", ctypes.c_uint32), ("mType", ctypes.c_uint32), ("mFlags", ctypes.c_uint32),
                ("mHours", ctypes.c_int16), ("mMinutes", ctypes.c_int16),
                ("mSeconds", ctypes.c_int16), ("mFrames", ctypes.c_int16)]


class _AudioTimeStamp(ctypes.Structure):
    _fields_ = [("mSampleTime", ctypes.c_double), ("mHostTime", ctypes.c_uint64),
                ("mRateScalar", ctypes.c_double), ("mWordClockTime", ctypes.c_uint64),
                ("mSMPTETime", _SMPTETime), ("mFlags", ctypes.c_uint32), ("mReserved", ctypes.c_uint32)]


def _tone(seconds, frequency=440.0, amplitude=12000):
    count = int(SAMPLE_RATE * seconds)
    return array.array(
        "h", (int(amplitude * math.sin(2 * math.pi * frequency * i / SAMPLE_RATE)) for i in range(count))
    ).tobytes()


@unittest.skipUnless(_audio_toolbox_available(), "AudioToolbox is macOS-only")
class AudioQueueOutputOfflineTests(unittest.TestCase):
    """Renders the production queue configuration offline: real DSP, no speaker."""

    RENDER_FRAMES = 480

    def render(self, rate, pcm, seconds, *, fade_at=None):
        at = speech_player._audio_toolbox()
        at.AudioQueueSetOfflineRenderFormat.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(speech_player._ASBD), ctypes.c_void_p]
        at.AudioQueueOfflineRender.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(_AudioTimeStamp), ctypes.POINTER(speech_player._AQBuffer), ctypes.c_uint32]
        output = speech_player.AudioQueueOutput(FMT, rate, lambda size: bytes(size), buffer_count=0)
        self.addCleanup(output.dispose)
        queue = output.queue
        asbd = speech_player._ASBD(float(SAMPLE_RATE), speech_player._K_LPCM, speech_player._K_SIGNED_PACKED,
                                   2, 1, 2, 1, 16, 0)
        speech_player._check(at.AudioQueueSetOfflineRenderFormat(queue, ctypes.byref(asbd), None), "offline format")
        source = ctypes.POINTER(speech_player._AQBuffer)()
        speech_player._check(at.AudioQueueAllocateBuffer(queue, len(pcm), ctypes.byref(source)), "allocate")
        ctypes.memmove(source.contents.mAudioData, pcm, len(pcm))
        source.contents.mAudioDataByteSize = len(pcm)
        speech_player._check(at.AudioQueueEnqueueBuffer(queue, source, 0, None), "enqueue")
        output.start()
        target = ctypes.POINTER(speech_player._AQBuffer)()
        speech_player._check(at.AudioQueueAllocateBuffer(queue, self.RENDER_FRAMES * 2, ctypes.byref(target)),
                             "allocate")
        stamp = _AudioTimeStamp()
        stamp.mFlags = 1  # kAudioTimeStampSampleTimeValid
        speech_player._check(at.AudioQueueOfflineRender(queue, ctypes.byref(stamp), target, 0), "prime")
        rendered = bytearray()
        fade_index = None
        for _ in range(int(SAMPLE_RATE * seconds / self.RENDER_FRAMES)):
            if fade_at is not None and fade_index is None and stamp.mSampleTime >= fade_at * SAMPLE_RATE:
                fade_index = len(rendered) // 2
                output.fade_out()  # the same call SpeechPlayer.stop() makes
            speech_player._check(
                at.AudioQueueOfflineRender(queue, ctypes.byref(stamp), target, self.RENDER_FRAMES), "render")
            rendered += ctypes.string_at(target.contents.mAudioData, target.contents.mAudioDataByteSize)
            stamp.mSampleTime += self.RENDER_FRAMES
        samples = array.array("h")
        samples.frombytes(bytes(rendered))
        return samples, fade_index

    @staticmethod
    def active_span(samples, threshold=1000):
        loud = [i for i, sample in enumerate(samples) if abs(sample) > threshold]
        return loud[0], loud[-1]

    @staticmethod
    def frequency(samples):
        crossings = sum(1 for i in range(1, len(samples)) if (samples[i - 1] < 0) != (samples[i] < 0))
        return crossings / 2 / (len(samples) / SAMPLE_RATE)

    def test_rate_is_a_tempo_change_without_pitch_shift(self):
        samples, _ = self.render(1.3, _tone(10.0), 12.0)
        first, last = self.active_span(samples)
        self.assertAlmostEqual((last - first) / SAMPLE_RATE, 10.0 / 1.3, delta=0.15)
        steady = samples[first + SAMPLE_RATE // 2:last - SAMPLE_RATE // 2]
        self.assertAlmostEqual(self.frequency(steady), 440.0, delta=4.0)

    def test_unit_rate_bypasses_time_pitch(self):
        tone = _tone(1.0)
        samples, _ = self.render(1.0, tone, 1.5)
        first, _ = self.active_span(samples, threshold=0)
        source = array.array("h")
        source.frombytes(tone)
        self.assertEqual(samples[first - 1:first - 1 + len(source)], source)

    def test_stop_fade_ramps_the_final_10ms_to_silence(self):
        samples, fade_index = self.render(1.3, _tone(1.0), 0.6, fade_at=0.3)
        window = SAMPLE_RATE // 1000  # 1 ms
        envelope = [max(abs(s) for s in samples[i:i + window])
                    for i in range(fade_index, len(samples) - window, window)]
        silent = next(i for i, peak in enumerate(envelope) if all(p <= 30 for p in envelope[i:]))
        ramp = envelope[silent - 10:silent]

        self.assertGreaterEqual(silent, 10, "a hard cut leaves no ramp")
        self.assertLessEqual(silent, 100, "the stop must reach silence within 100 ms")
        self.assertGreater(ramp[0], 2000, "the final 10 ms still carries audio")
        self.assertLess(ramp[-1], 0.05 * 12000, "the final 10 ms ends near zero")
        self.assertTrue(all(b <= a + 300 for a, b in zip(ramp, ramp[1:])), ramp)


@unittest.skipUnless(os.environ.get("RELAY_AUDIO_DEVICE_TESTS") == "1" and _audio_toolbox_available(),
                     "set RELAY_AUDIO_DEVICE_TESTS=1 to run against the default output device")
class SpeechPlayerDeviceTests(unittest.TestCase):
    """Plays silent PCM on the real default output: nothing is audible."""

    def test_thirty_sentence_reply_uses_one_output_and_stops_fast(self):
        created = []

        def factory(fmt, rate, render):
            created.append(speech_player.AudioQueueOutput(fmt, rate, render))
            return created[-1]

        player = SpeechPlayer(output_factory=factory)
        self.addCleanup(player.close)
        sentence = bytes(int(SAMPLE_RATE * 0.4) * 2)
        started = time.monotonic()
        for _ in range(30):
            self.assertTrue(player.wait(player.submit(sentence, FMT, 1.3)))
        handed_off = time.monotonic() - started
        self.assertEqual(len(created), 1, "the device must stay up across sentences")
        self.assertAlmostEqual(handed_off, 30 * 0.4 / 1.3, delta=1.0)

        chunk = player.submit(bytes(SAMPLE_RATE * 10), FMT, 1.3)
        time.sleep(0.3)
        requested = time.monotonic()
        player.stop()
        self.assertLessEqual(time.monotonic() - requested, 0.100)
        self.assertFalse(player.wait(chunk))
        self.assertEqual(len(created), 1)


if __name__ == "__main__":
    unittest.main()
