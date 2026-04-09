#!/usr/bin/env python3
"""Voice listener — captures mic audio via whisper.cpp stream, writes to FIFO."""

import os
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
        # Exists and is a FIFO (or something else) — check if it's a pipe
        import stat
        if stat.S_ISFIFO(os.stat(path).st_mode):
            return
        os.remove(path)
    elif os.path.exists(path):
        os.remove(path)
    os.mkfifo(path)


def main():
    cfg = load_config()
    stt = cfg["stt"]

    model_name = stt["model"]
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
    print("[voice_listen] Listening...", file=sys.stderr)

    # Run whisper.cpp stream
    cmd = [
        stream_bin,
        "--model", model_path,
        "--step", "500",
        "--length", "5000",
        "--vad-thold", str(vad_thold),
        "--keep", "200",
        "--no-timestamps",
    ]

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )

    try:
        for line in proc.stdout:  # type: ignore
            trimmed = line.strip()
            if trimmed and not trimmed.startswith("["):
                # Write to FIFO (blocking write — will wait for reader)
                with open(FIFO_PATH, "w") as fifo:
                    fifo.write(trimmed + "\n")
                    fifo.flush()
    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()
        proc.wait()


if __name__ == "__main__":
    main()
