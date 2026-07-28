from __future__ import annotations

import os
import queue
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

sys.modules.setdefault(
    "numpy",
    types.SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import tts_worker  # noqa: E402
from tts_worker import TTSWorker  # noqa: E402


class ImmediateThread:
    def __init__(self, target, args=(), kwargs=None, daemon=None):
        self.target = target
        self.args = args
        self.kwargs = kwargs or {}

    def start(self):
        self.target(*self.args, **self.kwargs)


class IdleThread:
    def __init__(self, target, args=(), kwargs=None, daemon=None):
        self.target = target
        self.args = args
        self.kwargs = kwargs or {}

    def start(self):
        return None


class TTSWorkerReplayTests(unittest.TestCase):
    def make_worker(self):
        worker = TTSWorker.__new__(TTSWorker)
        worker._pending_text = ""
        worker._pending_display_text = ""
        worker._lock = threading.Lock()
        worker._play_request_lock = threading.RLock()
        worker._playing = False
        worker._paused = False
        worker._current_proc = None
        worker._last_wav = None
        worker._last_unheard_text = ""
        worker._last_unheard_display_text = ""
        worker._last_response_text = ""
        worker._last_response_display_text = ""
        worker._rate = 1.0
        worker.played_texts = []
        worker.played_displays = []
        worker.played_wavs = []
        def play_text(text, *, display_text=None):
            worker.played_texts.append(text)
            worker.played_displays.append(display_text)
        worker._play_text = play_text
        worker._play_wav = lambda wav: worker.played_wavs.append(wav)
        worker._play_chime = lambda: None
        worker._cancel_speculation = lambda: None
        return worker

    def make_chunk_worker(self):
        worker = self.make_worker()
        worker._kokoro = object()
        worker._spec_lock = threading.Lock()
        worker._spec_cond = threading.Condition(worker._spec_lock)
        worker._spec_text = ""
        worker._spec_wav = None
        worker._spec_done = False
        worker._playback_generation = 1
        worker._playing = True
        return worker

    def temp_wav(self):
        fd, path = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return path

    def test_replay_uses_pending_text_before_last_wav(self):
        worker = self.make_worker()
        worker._pending_text = "latest unheard"
        worker._last_wav = self.temp_wav()

        worker.replay()

        self.assertEqual(worker.played_texts, ["latest unheard"])
        self.assertEqual(worker.played_wavs, [])
        self.assertEqual(worker._pending_text, "")

    def test_skip_preserves_pending_text_for_replay(self):
        worker = self.make_worker()
        worker._pending_text = "canceled latest"
        worker._last_wav = self.temp_wav()

        worker.skip()
        worker.replay()

        self.assertEqual(worker.played_texts, ["canceled latest"])
        self.assertEqual(worker.played_wavs, [])
        self.assertEqual(worker._last_unheard_text, "")

    def test_replay_falls_back_to_last_wav_without_unheard_text(self):
        worker = self.make_worker()
        worker._last_wav = self.temp_wav()
        worker._last_response_text = "Previously spoken reply"

        with (
            patch.object(tts_worker.threading, "Thread", ImmediateThread),
            patch.object(tts_worker, "_notify_state") as notify_state,
        ):
            worker.replay()

        self.assertEqual(worker.played_texts, [])
        self.assertEqual(worker.played_wavs, [worker._last_wav])
        notify_state.assert_any_call("preparing", text="Previously spoken reply")

    def test_replay_without_transcript_uses_last_wav_only(self):
        worker = self.make_worker()
        worker._last_wav = self.temp_wav()

        with (
            patch.object(tts_worker.threading, "Thread", ImmediateThread),
            patch.object(tts_worker, "_notify_state") as notify_state,
        ):
            worker.replay()

        self.assertEqual(worker.played_texts, [])
        self.assertEqual(worker.played_wavs, [worker._last_wav])
        notify_state.assert_not_called()

    def test_playing_new_pending_text_clears_stale_unheard_text(self):
        worker = self.make_worker()
        worker._last_unheard_text = "older canceled"
        worker._pending_text = "fresh pending"

        worker.play()

        self.assertEqual(worker.played_texts, ["fresh pending"])
        self.assertEqual(worker._last_unheard_text, "")

    def test_play_and_replay_do_not_start_while_a_plan_is_active(self):
        worker = self.make_worker()
        worker._playing = True
        worker._pending_text = "next result"
        worker._last_wav = self.temp_wav()

        worker.play()
        worker.replay()

        self.assertEqual(worker.played_texts, [])
        self.assertEqual(worker.played_wavs, [])
        self.assertEqual(worker._pending_text, "next result")

    def test_playback_waits_for_chime_cancellation(self):
        worker = self.make_worker()
        order = []

        class FakeChime:
            def poll(self):
                return None

            def terminate(self):
                order.append("chime-terminate")

            def wait(self, timeout=None):
                order.append("chime-wait")

        worker._chime_proc = FakeChime()

        worker._begin_playback()
        order.append("playback-started" if worker._playing else "not-started")

        self.assertEqual(order, ["chime-terminate", "chime-wait", "playback-started"])

    def test_stop_observes_process_exit_before_cancellation(self):
        worker = self.make_worker()
        order = []
        intent = {"utterance_id": "speech-1"}

        class FakePlayer:
            def poll(self):
                return None

            def terminate(self):
                order.append("player-terminate")

            def wait(self, timeout=None):
                order.append("player-wait")

        worker._playing = True
        worker._current_proc = FakePlayer()
        worker._current_speech_intent = intent
        worker._speech_observer = lambda state, payload: order.append(state)
        worker._speech_eligibility = None
        worker._chime_proc = None

        worker.stop_playback()

        self.assertEqual(order, ["player-terminate", "player-wait", "cancelled"])

    def test_collected_chunks_refresh_waiting_preview_before_playback(self):
        worker = self.make_worker()
        speculations = []
        chimes = []
        worker._start_speculation = lambda text: speculations.append(text)
        worker._play_chime = lambda: chimes.append(True)

        with patch.object(tts_worker, "_notify_state") as notify_state:
            worker._handle_collected_chunk("First part.")
            worker._handle_collected_chunk("Second part.")

        self.assertEqual(
            [(call.args[0], call.kwargs["text"]) for call in notify_state.call_args_list],
            [
                ("message_waiting", "First part."),
                ("message_waiting", "First part. Second part."),
            ],
        )
        self.assertEqual(speculations, ["First part.", "First part. Second part."])
        self.assertEqual(chimes, [True])
        self.assertEqual(worker._last_response_text, "First part. Second part.")

    def test_display_text_is_retained_separately_from_spoken_queue_text(self):
        worker = self.make_worker()
        worker._start_speculation = lambda text: None

        with patch.object(tts_worker, "_notify_state") as notify_state:
            worker._handle_collected_chunk({
                "text": "Short spoken result.",
                "display_text": "Authoritative **provider** result.",
            })

        notify_state.assert_called_once_with(
            "message_waiting",
            text="Authoritative **provider** result.",
        )
        self.assertEqual(worker._pending_text, "Short spoken result.")
        self.assertEqual(worker._pending_display_text, "Authoritative **provider** result.")

        worker.play()

        self.assertEqual(worker.played_texts, ["Short spoken result."])
        self.assertEqual(worker.played_displays, ["Authoritative **provider** result."])

    def test_sentence_chunks_preserve_sentence_boundaries_and_tail(self):
        chunks = tts_worker._sentence_chunks(" First sentence. Second? Tail without punctuation ")

        self.assertEqual(chunks, ["First sentence.", "Second?", "Tail without punctuation"])

    def test_start_speculation_targets_first_sentence_chunk(self):
        worker = self.make_chunk_worker()
        synthesized = []
        worker._synthesize_to_wav = lambda text: synthesized.append(text) or self.temp_wav()

        with patch.object(tts_worker.threading, "Thread", ImmediateThread):
            worker._start_speculation("First sentence. Second sentence.")

        self.assertEqual(synthesized, ["First sentence."])
        self.assertEqual(worker._spec_text, "First sentence.")
        self.assertTrue(worker._spec_done)

    def test_chunked_playback_synthesizes_next_chunk_while_current_plays(self):
        worker = self.make_chunk_worker()
        synthesized = []
        played = []
        wav_text = {}
        second_synthesis_started = threading.Event()
        ahead_ready_during_first_play = []
        combined_wav = self.temp_wav()

        def synthesize(text):
            synthesized.append(text)
            if text == "Second sentence.":
                second_synthesis_started.set()
            wav = self.temp_wav()
            wav_text[wav] = text
            return wav

        def play(wav):
            text = wav_text[wav]
            played.append(text)
            if text == "First sentence.":
                ahead_ready_during_first_play.append(second_synthesis_started.wait(1.0))

        worker._synthesize_to_wav = synthesize
        worker._play_wav_blocking = play
        worker._combine_wavs = lambda wavs: combined_wav

        with patch.object(tts_worker, "_notify_state", lambda *args, **kwargs: None):
            worker._speak_chunks(["First sentence.", "Second sentence."], 1)

        self.assertEqual(synthesized, ["First sentence.", "Second sentence."])
        self.assertEqual(played, ["First sentence.", "Second sentence."])
        self.assertEqual(ahead_ready_during_first_play, [True])
        self.assertEqual(worker._last_wav, combined_wav)
        self.assertFalse(worker._playing)

    def test_stop_during_chunk_prevents_later_chunks_from_playing(self):
        worker = self.make_chunk_worker()
        played = []
        wav_text = {}

        def synthesize(text):
            wav = self.temp_wav()
            wav_text[wav] = text
            return wav

        def play(wav):
            text = wav_text[wav]
            played.append(text)
            if text == "First sentence.":
                worker.stop_playback()

        worker._synthesize_to_wav = synthesize
        worker._play_wav_blocking = play

        with patch.object(tts_worker, "_notify_state", lambda *args, **kwargs: None):
            worker._speak_chunks(["First sentence.", "Second sentence."], 1)

        self.assertEqual(played, ["First sentence."])
        self.assertFalse(worker._playing)

    def test_play_wav_blocking_uses_default_rate_multiplier_for_afplay(self):
        worker = self.make_worker()
        worker._rate = 1.3

        class FakeProc:
            def wait(self):
                return 0

        with (
            patch.object(tts_worker, "_notify_state"),
            patch.object(tts_worker.subprocess, "Popen", return_value=FakeProc()) as popen,
        ):
            worker._play_wav_blocking("/tmp/test.wav")

        popen.assert_called_once()
        self.assertEqual(
            popen.call_args.args[0],
            ["afplay", "/tmp/test.wav", "-r", "1.3"],
        )

    def test_worker_init_defaults_rate_to_one_point_three_when_missing(self):
        with (
            patch.object(tts_worker, "load_config", return_value={"tts": {"voice": "bf_emma"}}),
            patch.object(TTSWorker, "_load_voice", lambda self: None),
            patch.object(tts_worker.threading, "Thread", IdleThread),
        ):
            worker = TTSWorker(queue.Queue())

        self.assertEqual(worker._voice, "bf_emma")
        self.assertEqual(worker._rate, 1.3)


if __name__ == "__main__":
    unittest.main()
