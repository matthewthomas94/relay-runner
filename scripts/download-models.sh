#!/bin/bash
# Downloads STT and TTS models for bundling into the app.
# Run this before `cargo tauri build`.
#
# Models are stored in models/ (gitignored) and bundled via tauri.conf.json.
#
# Note: Parakeet STT models are managed by FluidAudio's built-in downloader
# (AsrModels.downloadAndLoad) and cached automatically on first use.
# This script only downloads the TTS model for bundling.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MODELS_DIR="$PROJECT_ROOT/models"

KOKORO_DIR="$MODELS_DIR/kokoro"

echo "=== Voice Terminal Model Downloader ==="
echo ""

# -- Kokoro TTS model ---------------------------------------------------------

download_kokoro_model() {
    if [ -f "$KOKORO_DIR/kokoro-v1.0.onnx" ] && [ -f "$KOKORO_DIR/voices-v1.0.bin" ]; then
        echo "[kokoro] Model already downloaded, skipping."
        return
    fi

    echo "[kokoro] Downloading Kokoro model (~300MB)..."
    mkdir -p "$KOKORO_DIR"

    python3 -c "
from huggingface_hub import hf_hub_download
for f in ['kokoro-v1.0.onnx', 'voices-v1.0.bin']:
    hf_hub_download(
        repo_id='fastrtc/kokoro-onnx',
        filename=f,
        local_dir='${KOKORO_DIR}',
        local_dir_use_symlinks=False,
    )
print('Done.')
"
    echo "[kokoro] Model saved to $KOKORO_DIR"
}

# -- Download all --------------------------------------------------------------

echo "--- TTS Model (Kokoro) ---"
download_kokoro_model

echo ""
echo "--- STT Model (Parakeet) ---"
echo "[parakeet] Models are downloaded automatically by FluidAudio on first launch."
echo "[parakeet] To pre-download, build and run: cd stt-sidecar && swift run voice-listen --help"

echo ""
echo "=== Done ==="
echo ""
du -sh "$KOKORO_DIR"/* 2>/dev/null || true
