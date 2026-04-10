#!/usr/bin/env python3
"""Voice listener — captures mic audio via whisper.cpp stream, writes to FIFO."""

from __future__ import annotations

import ctypes
import ctypes.util
import errno
import os
import re
import shutil
import subprocess
import sys

from config import load_config

FIFO_PATH = os.environ.get("VOICE_FIFO", "/tmp/voice_in.fifo")

# Search paths for whisper.cpp stream binary
STREAM_CANDIDATES = [
    "whisper-stream",
    "stream",
    "/usr/local/bin/whisper-stream",
    "/opt/homebrew/bin/whisper-stream",
    os.path.expanduser("~/.local/bin/whisper-stream"),
]

# Search paths for whisper models
MODEL_DIRS = [
    os.path.expanduser("~/.local/share/whisper.cpp/models"),
    "/usr/local/share/whisper.cpp/models",
    "/opt/homebrew/share/whisper.cpp/models",
    os.path.expanduser("~/whisper.cpp/models"),
]

# VAD thresholds by sensitivity level
VAD_THRESHOLDS = {"low": 0.8, "medium": 0.6, "high": 0.4}

# Strip ANSI escape sequences from whisper-stream output
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x1b\].*?\x07")

# ── Caps Lock detection (macOS) ──────────────────────────────────────────────

_cg_lib = None
_CAPS_LOCK_MASK = 0x00010000  # kCGEventFlagMaskAlphaShift


def _load_cg():
    global _cg_lib
    if _cg_lib is not None:
        return
    path = ctypes.util.find_library("CoreGraphics")
    if path:
        _cg_lib = ctypes.CDLL(path)
        _cg_lib.CGEventSourceFlagsState.argtypes = [ctypes.c_int]
        _cg_lib.CGEventSourceFlagsState.restype = ctypes.c_uint64


def is_caps_lock_on() -> bool:
    """Return True when Caps Lock LED is active (macOS only, stdlib-only)."""
    _load_cg()
    if _cg_lib is None:
        return True  # Fallback: always pass through if detection unavailable
    flags = _cg_lib.CGEventSourceFlagsState(0)  # kCGEventSourceStateCombinedSessionState
    return bool(flags & _CAPS_LOCK_MASK)


# ── Helpers ──────────────────────────────────────────────────────────────────

def find_stream_binary() -> str | None:
    for candidate in STREAM_CANDIDATES:
        if shutil.which(candidate):
            return candidate
    return None


def find_model(model_name: str) -> str | None:
    filename = f"ggml-{model_name}.bin"
    for d in MODEL_DIRS:
        path = os.path.join(d, filename)
        if os.path.isfile(path):
            return path
    return None


def ensure_fifo(path: str):
    if os.path.exists(path) and not os.path.isfile(path):
        import stat
        if stat.S_ISFIFO(os.stat(path).st_mode):
            return
        os.remove(path)
    elif os.path.exists(path):
        os.remove(path)
    os.mkfifo(path)


def write_to_fifo(path: str, text: str) -> bool:
    """Non-blocking FIFO write. Returns True on success, False if no reader."""
    try:
        fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as e:
        if e.errno == errno.ENXIO:
            # No reader connected — skip silently
            return False
        raise
    try:
        os.write(fd, (text + "\n").encode())
    except BrokenPipeError:
        os.close(fd)
        return False
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    return True


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    cfg = load_config()
    stt = cfg["stt"]

    model_name = stt["model"]
    input_mode = stt.get("input_mode", "caps_lock_toggle")
    vad_sensitivity = stt.get("vad_sensitivity", "medium")
    vad_thold = VAD_THRESHOLDS.get(vad_sensitivity, 0.6)

    # Find stream binary
    stream_bin = find_stream_binary()
    if not stream_bin:
        print("[voice_listen] Error: whisper.cpp stream binary not found.", file=sys.stderr)
        print("[voice_listen] Install via: brew install whisper-cpp", file=sys.stderr)
        sys.exit(1)

    # Find model
    model_path = find_model(model_name)
    if not model_path:
        print(f"[voice_listen] Error: Whisper model '{model_name}' not found.", file=sys.stderr)
        print("[voice_listen] Download with:", file=sys.stderr)
        print(f"  whisper-cpp-download-ggml-model {model_name}", file=sys.stderr)
        sys.exit(1)

    # Ensure FIFO exists
    ensure_fifo(FIFO_PATH)

    print(f"[voice_listen] Model: {model_path}", file=sys.stderr)
    print(f"[voice_listen] FIFO:  {FIFO_PATH}", file=sys.stderr)
    print(f"[voice_listen] VAD:   {vad_sensitivity} (threshold {vad_thold})", file=sys.stderr)
    print(f"[voice_listen] Mode:  {input_mode}", file=sys.stderr)
    print("[voice_listen] Listening...", file=sys.stderr)

    # Run whisper.cpp stream
    cmd = [
        stream_bin,
        "--model", model_path,
        "--step", "500",
        "--length", "5000",
        "--vad-thold", str(vad_thold),
        "--keep", "200",
    ]

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )

    # whisper-stream progressively refines its transcription across every
    # 500ms step.  We just keep overwriting `current_segment` with each
    # new text line — only the final refinement matters.  The complete
    # message is sent when Caps Lock transitions OFF.
    current_segment = ""
    was_caps_on = False

    try:
        for line in proc.stdout:  # type: ignore
            raw_segment = line.rsplit("\r", 1)[-1]
            clean = _ANSI_RE.sub("", raw_segment).strip()

            if input_mode == "caps_lock_toggle":
                caps_on = is_caps_lock_on()

                # Caps Lock just turned OFF — send whatever we have
                if was_caps_on and not caps_on:
                    if current_segment:
                        if write_to_fifo(FIFO_PATH, current_segment):
                            print(f"[voice_listen] >> {current_segment}", file=sys.stderr)
                        current_segment = ""
                    else:
                        # No speech detected — send interrupt signal
                        write_to_fifo(FIFO_PATH, "__INTERRUPT__")
                        print("[voice_listen] >> __INTERRUPT__", file=sys.stderr)
                    was_caps_on = False
                    continue

                was_caps_on = caps_on

                if caps_on and clean and not clean.startswith("["):
                    current_segment = clean
                    print(f"[voice_listen] (refining) {clean}", file=sys.stderr)
            else:
                # always_on mode: send immediately
                if clean and not clean.startswith("["):
                    if write_to_fifo(FIFO_PATH, clean):
                        print(f"[voice_listen] >> {clean}", file=sys.stderr)
    except KeyboardInterrupt:
        pass
    finally:
        if current_segment:
            write_to_fifo(FIFO_PATH, current_segment)
        proc.terminate()
        proc.wait()


if __name__ == "__main__":
    main()
