#!/bin/bash
# fetch-agent-desktop.sh — download the pinned vercel-labs/agent-desktop release
# that Relay Desktop bundles, verify it, and print the directory holding the
# `agent-desktop` CLI, its `agent-desktop-macos-helper`, and its LICENSE.
#
# The archive for the host architecture is cached under
# .build/agent-desktop/v<version>/<target>/ and reused when its contents are
# already verified. Every byte is checked against the SHA-256 pins below (taken
# from the release's checksums.txt and the LICENSE at the matching tag) before
# anything is extracted or copied, so a tampered download never reaches the
# app bundle.
#
#   AGENT_DESKTOP_ARCHIVE   Optional local archive to use instead of
#                           downloading. It must still match the pinned
#                           checksum for the host architecture.

set -euo pipefail

AGENT_DESKTOP_VERSION="1.0.2"
AGENT_DESKTOP_REPO="vercel-labs/agent-desktop"
# sha256 of agent-desktop-v<version>-<target>.tar.gz on the GitHub release.
AGENT_DESKTOP_SHA256_AARCH64="7bee385196d7b478de80cf05ca4304aaa38f0eba593b3406ad3c247c1773be19"
AGENT_DESKTOP_SHA256_X86_64="8edda6df17eafc042395502a823dbb8415bc8ac14835a6731e4d8becc9cb4121"
# sha256 of LICENSE (Apache License 2.0) at tag v<version>.
AGENT_DESKTOP_LICENSE_SHA256="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

case "$(uname -m)" in
    arm64|aarch64)
        TARGET="aarch64-apple-darwin"
        EXPECTED_SHA256="$AGENT_DESKTOP_SHA256_AARCH64"
        ;;
    x86_64)
        TARGET="x86_64-apple-darwin"
        EXPECTED_SHA256="$AGENT_DESKTOP_SHA256_X86_64"
        ;;
    *)
        echo "error: unsupported architecture $(uname -m) for agent-desktop" >&2
        exit 1
        ;;
esac

ARCHIVE_NAME="agent-desktop-v${AGENT_DESKTOP_VERSION}-${TARGET}.tar.gz"
RELEASE_URL="https://github.com/${AGENT_DESKTOP_REPO}/releases/download/v${AGENT_DESKTOP_VERSION}/${ARCHIVE_NAME}"
LICENSE_URL="https://raw.githubusercontent.com/${AGENT_DESKTOP_REPO}/v${AGENT_DESKTOP_VERSION}/LICENSE"
CACHE_DIR="${AGENT_DESKTOP_CACHE_DIR:-$PROJECT_ROOT/.build/agent-desktop}/v${AGENT_DESKTOP_VERSION}/${TARGET}"
VERIFIED_MARKER="$CACHE_DIR/.verified"

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

verify_sha256() {
    local path="$1" expected="$2" label="$3"
    local actual
    actual="$(sha256_of "$path")"
    if [ "$actual" != "$expected" ]; then
        echo "error: $label checksum mismatch" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        rm -f "$path"
        exit 1
    fi
}

if [ -f "$VERIFIED_MARKER" ] \
    && [ -x "$CACHE_DIR/agent-desktop" ] \
    && [ -x "$CACHE_DIR/agent-desktop-macos-helper" ] \
    && [ -f "$CACHE_DIR/LICENSE" ] \
    && [ "$(cat "$VERIFIED_MARKER")" = "$EXPECTED_SHA256 $AGENT_DESKTOP_LICENSE_SHA256" ]; then
    echo "$CACHE_DIR"
    exit 0
fi

rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"
ARCHIVE_PATH="$CACHE_DIR/$ARCHIVE_NAME"

if [ -n "${AGENT_DESKTOP_ARCHIVE:-}" ]; then
    cp "$AGENT_DESKTOP_ARCHIVE" "$ARCHIVE_PATH"
else
    echo "==> Downloading $ARCHIVE_NAME" >&2
    curl -fsSL --retry 3 --retry-delay 2 -o "$ARCHIVE_PATH" "$RELEASE_URL"
fi
verify_sha256 "$ARCHIVE_PATH" "$EXPECTED_SHA256" "$ARCHIVE_NAME"

if [ -n "${AGENT_DESKTOP_LICENSE:-}" ]; then
    cp "$AGENT_DESKTOP_LICENSE" "$CACHE_DIR/LICENSE"
else
    curl -fsSL --retry 3 --retry-delay 2 -o "$CACHE_DIR/LICENSE" "$LICENSE_URL"
fi
verify_sha256 "$CACHE_DIR/LICENSE" "$AGENT_DESKTOP_LICENSE_SHA256" "agent-desktop LICENSE"

tar -xzf "$ARCHIVE_PATH" -C "$CACHE_DIR" agent-desktop agent-desktop-macos-helper
rm -f "$ARCHIVE_PATH"
chmod 755 "$CACHE_DIR/agent-desktop" "$CACHE_DIR/agent-desktop-macos-helper"
for binary in agent-desktop agent-desktop-macos-helper; do
    if ! file "$CACHE_DIR/$binary" | grep -q "Mach-O 64-bit executable"; then
        echo "error: $binary in $ARCHIVE_NAME is not a Mach-O executable" >&2
        exit 1
    fi
done
printf '%s %s\n' "$EXPECTED_SHA256" "$AGENT_DESKTOP_LICENSE_SHA256" > "$VERIFIED_MARKER"
echo "$CACHE_DIR"
