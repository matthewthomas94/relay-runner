#!/usr/bin/env python3
"""Render an isolated Settings preview WAV; the app owns cancellable playback."""

from __future__ import annotations

import argparse
import os
import sys
import wave
from pathlib import Path
import signal
import threading
import time

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
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    # Own a process group so Settings can cancel this process without touching a session.
    try:
        os.setsid()
    except OSError:
        pass

    def terminate(*_):
        raise SystemExit(130)

    signal.signal(signal.SIGTERM, terminate)
    parent_pid = os.getppid()

    def parent_watchdog():
        while True:
            time.sleep(0.25)
            if os.getppid() != parent_pid:
                os._exit(130)

    threading.Thread(target=parent_watchdog, daemon=True).start()

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

    samples = np.asarray(samples)
    if not np.isfinite(samples).all():
        return 1
    int16_audio = (np.clip(samples, -1, 1) * 32767).astype(np.int16)

    try:
        with wave.open(str(args.output), "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(int16_audio.tobytes())
        args.output.chmod(0o600)
    except Exception:
        print("[preview_voice] Preview failed; check local speech setup.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        print("[preview_voice] Preview unavailable. Check local speech setup.", file=sys.stderr)
        sys.exit(1)
