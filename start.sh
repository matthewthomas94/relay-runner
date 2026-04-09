#!/usr/bin/env bash
# Launcher — creates FIFO, starts background daemons, runs voice_wrap foreground.
# Usage: ./start.sh [-- command args...]
#   Default command: claude

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICE_FIFO="${VOICE_FIFO:-/tmp/voice_in.fifo}"
TTS_CONTROL_SOCK="${TTS_CONTROL_SOCK:-/tmp/tts_control.sock}"

# Track background PIDs for cleanup
PIDS=()

cleanup() {
    echo ""
    echo "[start] Shutting down..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -f "$VOICE_FIFO" "$TTS_CONTROL_SOCK"
    echo "[start] Clean."
}
trap cleanup EXIT INT TERM

# Parse arguments — everything after -- is the target command
CMD=("claude")
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "--" ]]; then
        shift
        CMD=("$@")
    else
        CMD=("$@")
    fi
fi

# Create FIFO
rm -f "$VOICE_FIFO"
mkfifo "$VOICE_FIFO"
echo "[start] FIFO: $VOICE_FIFO"

# Start voice listener (background)
if command -v whisper-stream &>/dev/null || command -v stream &>/dev/null; then
    bash "$SCRIPT_DIR/voice_listen.sh" &
    PIDS+=($!)
    echo "[start] Voice listener started (PID ${PIDS[-1]})"
else
    echo "[start] whisper.cpp not found — voice input disabled (FIFO still works for manual input)"
fi

# Start key daemon (background)
python3 "$SCRIPT_DIR/key_daemon.py" &
PIDS+=($!)
echo "[start] Key daemon started (PID ${PIDS[-1]})"

# Launch PTY wrapper (foreground)
echo "[start] Launching: ${CMD[*]}"
echo "---"
python3 "$SCRIPT_DIR/voice_wrap.py" "${CMD[@]}"
