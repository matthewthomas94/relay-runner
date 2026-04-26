#!/usr/bin/env python3
"""One-shot voice preview — synthesize a single line with a chosen Kokoro voice.

Used by the Settings → TTS preview button. The running tts_worker uses the
saved voice from config, so previewing an *unsaved* selection means we can't
just write to /tmp/tts_in.fifo. Spawn this script per click instead — slow
(~1s for Kokoro init) but isolated and works whether or not a session is live.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np


def _find_kokoro_model() -> tuple[str, str] | None:
    """Find Kokoro model + voices files. Mirrors tts_worker.py search paths."""
    candidates = []
    bundled = os.environ.get("VOICE_MODELS_DIR")
    if bundled:
        candidates.append(os.path.join(bundled, "kokoro"))
    candidates.append(os.path.expanduser("~/.local/share/kokoro"))

    for d in candidates:
        model = os.path.join(d, "kokoro-v1.0.onnx")
        voices = os.path.join(d, "voices-v1.0.bin")
        if os.path.isfile(model) and os.path.isfile(voices):
            return model, voices
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--voice", required=True)
    parser.add_argument("--text", required=True)
    args = parser.parse_args()

    paths = _find_kokoro_model()
    if paths is None:
        print("[preview_voice] Kokoro model not found", file=sys.stderr)
        return 1

    try:
        from kokoro_onnx import Kokoro
    except ImportError as e:
        print(f"[preview_voice] kokoro_onnx not installed: {e}", file=sys.stderr)
        return 1

    kokoro = Kokoro(*paths)
    samples, sample_rate = kokoro.create(
        args.text, voice=args.voice, speed=1.0, lang="en-us"
    )
    if samples is None or len(samples) == 0:
        print("[preview_voice] Synthesis returned no samples", file=sys.stderr)
        return 1

    int16_audio = (np.asarray(samples) * 32767).astype(np.int16)

    fd, wav_path = tempfile.mkstemp(suffix=".wav", prefix="relay-preview-")
    os.close(fd)
    try:
        with wave.open(wav_path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(int16_audio.tobytes())

        subprocess.run(["afplay", wav_path], check=False)
    finally:
        try:
            os.remove(wav_path)
        except OSError:
            pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
