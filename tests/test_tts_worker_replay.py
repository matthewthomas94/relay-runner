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


if __name__ == "__main__":
    unittest.main()
