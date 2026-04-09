#!/usr/bin/env bash
# Voice listener — captures mic audio via whisper.cpp stream, writes to FIFO.
# Requires: whisper.cpp (brew install whisper-cpp) or built from source.

set -euo pipefail

VOICE_FIFO="${VOICE_FIFO:-/tmp/voice_in.fifo}"
WHISPER_MODEL="${WHISPER_MODEL:-base.en}"

# Resolve whisper.cpp stream binary
WHISPER_STREAM=""
for candidate in \
    "whisper-stream" \
    "stream" \
    "/usr/local/bin/whisper-stream" \
    "/opt/homebrew/bin/whisper-stream" \
    "$HOME/.local/bin/whisper-stream"; do
    if command -v "$candidate" &>/dev/null; then
        WHISPER_STREAM="$candidate"
        break
    fi
done

if [[ -z "$WHISPER_STREAM" ]]; then
    echo "[voice_listen] Error: whisper.cpp stream binary not found." >&2
    echo "[voice_listen] Install via: brew install whisper-cpp" >&2
    echo "[voice_listen] Or build from source: https://github.com/ggerganov/whisper.cpp" >&2
    exit 1
fi

# Resolve model path
MODEL_PATH=""
for candidate in \
    "$HOME/.local/share/whisper.cpp/models/ggml-${WHISPER_MODEL}.bin" \
    "/usr/local/share/whisper.cpp/models/ggml-${WHISPER_MODEL}.bin" \
    "/opt/homebrew/share/whisper.cpp/models/ggml-${WHISPER_MODEL}.bin" \
    "$HOME/whisper.cpp/models/ggml-${WHISPER_MODEL}.bin"; do
    if [[ -f "$candidate" ]]; then
        MODEL_PATH="$candidate"
        break
    fi
done

if [[ -z "$MODEL_PATH" ]]; then
    echo "[voice_listen] Error: Whisper model '${WHISPER_MODEL}' not found." >&2
    echo "[voice_listen] Download it with:" >&2
    echo "  bash <(curl -s https://raw.githubusercontent.com/ggerganov/whisper.cpp/master/models/download-ggml-model.sh) ${WHISPER_MODEL}" >&2
    exit 1
fi

# Ensure FIFO exists
if [[ ! -p "$VOICE_FIFO" ]]; then
    mkfifo "$VOICE_FIFO" 2>/dev/null || true
fi

echo "[voice_listen] Model: $MODEL_PATH" >&2
echo "[voice_listen] FIFO:  $VOICE_FIFO" >&2
echo "[voice_listen] Listening..." >&2

# Run whisper.cpp stream with VAD, writing transcriptions to FIFO.
# --step 500     : process audio every 500ms
# --length 5000  : max segment length 5s
# --vad-thold 0.6: voice activity detection threshold
# --keep 200     : keep 200ms of audio context between steps
exec "$WHISPER_STREAM" \
    --model "$MODEL_PATH" \
    --step 500 \
    --length 5000 \
    --vad-thold 0.6 \
    --keep 200 \
    --no-timestamps \
    2>/dev/null \
    | while IFS= read -r line; do
        # Skip empty lines and whisper.cpp status messages
        trimmed="${line#"${line%%[![:space:]]*}"}"
        if [[ -n "$trimmed" && "$trimmed" != "["* ]]; then
            printf '%s\n' "$trimmed" > "$VOICE_FIFO"
        fi
    done
