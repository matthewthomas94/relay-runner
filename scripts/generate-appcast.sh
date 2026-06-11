#!/bin/bash
# Generate Relay Runner's Sparkle appcast from the release update archive.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.3}"
SPARKLE_TOOLS_URL="${SPARKLE_TOOLS_URL:-https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz}"
SPARKLE_APPCAST_URL="${SPARKLE_APPCAST_URL:-https://updates.relayrunner.app/appcast.xml}"
SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://updates.relayrunner.app/}"
DIST_DIR="${DIST_DIR:-$PROJECT_ROOT/dist}"
SPARKLE_ARCHIVE_PATH="${SPARKLE_ARCHIVE_PATH:-$DIST_DIR/RelayRunner.zip}"
SPARKLE_APPCAST_OUTPUT="${SPARKLE_APPCAST_OUTPUT:-$DIST_DIR/appcast.xml}"
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-}"

if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    echo "error: SPARKLE_ED_PRIVATE_KEY is required to sign the Sparkle appcast." >&2
    exit 1
fi

if [ ! -f "$SPARKLE_ARCHIVE_PATH" ]; then
    echo "error: Sparkle archive not found: $SPARKLE_ARCHIVE_PATH" >&2
    exit 1
fi

case "$SPARKLE_DOWNLOAD_URL_PREFIX" in
    https://*/)
        ;;
    *)
        echo "error: SPARKLE_DOWNLOAD_URL_PREFIX must be an https URL ending in /." >&2
        exit 1
        ;;
esac

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ARCHIVES_DIR="$WORK_DIR/archives"
mkdir -p "$ARCHIVES_DIR"
cp "$SPARKLE_ARCHIVE_PATH" "$ARCHIVES_DIR/$(basename "$SPARKLE_ARCHIVE_PATH")"

if curl -fsSL "$SPARKLE_APPCAST_URL" -o "$ARCHIVES_DIR/appcast.xml"; then
    echo "==> Downloaded existing appcast from $SPARKLE_APPCAST_URL"
else
    echo "==> No existing appcast found at $SPARKLE_APPCAST_URL; generating a new feed."
fi

if [ -z "$SPARKLE_BIN_DIR" ]; then
    echo "==> Downloading Sparkle $SPARKLE_VERSION release tools..."
    curl -fsSL "$SPARKLE_TOOLS_URL" -o "$WORK_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
    tar -xJf "$WORK_DIR/Sparkle-$SPARKLE_VERSION.tar.xz" -C "$WORK_DIR"
    SPARKLE_BIN_DIR="$WORK_DIR/bin"
fi

GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"
if [ ! -x "$GENERATE_APPCAST" ]; then
    echo "error: generate_appcast not found or not executable at $GENERATE_APPCAST" >&2
    exit 1
fi

echo "==> Generating Sparkle appcast..."
echo "$SPARKLE_ED_PRIVATE_KEY" | "$GENERATE_APPCAST" \
    --ed-key-file - \
    --download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX" \
    -o "$ARCHIVES_DIR/appcast.xml" \
    "$ARCHIVES_DIR"

mkdir -p "$(dirname "$SPARKLE_APPCAST_OUTPUT")"
cp "$ARCHIVES_DIR/appcast.xml" "$SPARKLE_APPCAST_OUTPUT"

if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$SPARKLE_APPCAST_OUTPUT"
fi

if ! grep -F -q "sparkle:edSignature" "$SPARKLE_APPCAST_OUTPUT"; then
    echo "error: generated appcast is missing sparkle:edSignature." >&2
    exit 1
fi

if ! grep -F -q "$(basename "$SPARKLE_ARCHIVE_PATH")" "$SPARKLE_APPCAST_OUTPUT"; then
    echo "error: generated appcast does not reference $(basename "$SPARKLE_ARCHIVE_PATH")." >&2
    exit 1
fi

echo "==> Appcast: $SPARKLE_APPCAST_OUTPUT"
