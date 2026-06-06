from __future__ import annotations

import os
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


class TTSWorkerReplayTests(unittest.TestCase):
    def make_worker(self):
        worker = TTSWorker.__new__(TTSWorker)
        worker._pending_text = ""
        worker._lock = threading.Lock()
        worker._playing = False
        worker._paused = False
        worker._current_proc = None
        worker._last_wav = None
        worker._last_unheard_text = ""
        worker._rate = 1.0
        worker.played_texts = []
        worker.played_wavs = []
        worker._play_text = lambda text: worker.played_texts.append(text)
        worker._play_wav = lambda wav: worker.played_wavs.append(wav)
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

        with patch.object(tts_worker.threading, "Thread", ImmediateThread):
            worker.replay()

        self.assertEqual(worker.played_texts, [])
        self.assertEqual(worker.played_wavs, [worker._last_wav])

    def test_playing_new_pending_text_clears_stale_unheard_text(self):
        worker = self.make_worker()
        worker._last_unheard_text = "older canceled"
        worker._pending_text = "fresh pending"

        worker.play()

        self.assertEqual(worker.played_texts, ["fresh pending"])
        self.assertEqual(worker._last_unheard_text, "")

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


if __name__ == "__main__":
    unittest.main()
