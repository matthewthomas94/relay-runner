#!/bin/bash
# build-dmg.sh — Build Relay Runner.app and package into a DMG.
#
# Usage:
#   ./scripts/build-dmg.sh              # Release build + DMG
#   ./scripts/build-dmg.sh --debug      # Debug build + DMG
#
# Signing & notarisation are opt-in via environment variables so local
# dev builds don't fail when no cert is installed:
#
#   SIGN_IDENTITY    Developer ID Application identity (e.g. "Developer ID
#                    Application: Jane Doe (TEAMID)"). Unset → ad-hoc sign,
#                    which is fine for local testing but will not run
#                    unquarantined on another Mac.
#
#   NOTARY_PROFILE   notarytool keychain profile name (created once with
#                    `xcrun notarytool store-credentials <name>`). When set
#                    together with SIGN_IDENTITY, the final DMG is
#                    submitted for notarisation and stapled.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

APP_NAME="Relay Runner"
BUNDLE_ID="com.relayrunner.app"
DMG_NAME="RelayRunner"

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG="debug"
fi

BUILD_DIR="$PROJECT_ROOT/.build/$CONFIG"
DIST_DIR="$PROJECT_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

echo "==> Building ($CONFIG)..."
swift build -c "$CONFIG"

echo "==> Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/SharedSupport/services"
mkdir -p "$APP_DIR/Contents/SharedSupport/scripts"

# Binary
cp "$BUILD_DIR/relay-runner" "$APP_DIR/Contents/MacOS/relay-runner"

# Helper binary: Relay Actions MCP server. Spawned by `claude` (not by the
# menu-bar app) when a session is active and the MCP entry registered by
# scripts/relay-bridge points here. Lives alongside the main binary so the TCC
# attribution falls on the bundle (Screen Recording / Accessibility prompts
# read "Relay Runner", not "relay-actions-mcp").
cp "$BUILD_DIR/relay-actions-mcp" "$APP_DIR/Contents/MacOS/relay-actions-mcp"

# Helper binary: Relay Orchestrator MCP server. Same TCC-attribution rationale
# as relay-actions-mcp — sits in MacOS/ alongside the bundle so MCP tools
# inherit the bundle's identity. The orchestrator daemon process itself runs
# under launchd (via scripts/relay-orchestrator) and is just a Python script,
# but the MCP proxy is the Swift binary registered with `claude mcp add`.
cp "$BUILD_DIR/relay-orchestrator-mcp" "$APP_DIR/Contents/MacOS/relay-orchestrator-mcp"

# App icon: compile AppIcon.iconset into AppIcon.icns via macOS iconutil.
ICONSET_SRC="$PROJECT_ROOT/assets/AppIcon.iconset"
if [ -d "$ICONSET_SRC" ]; then
    echo "==> Building AppIcon.icns..."
    iconutil -c icns "$ICONSET_SRC" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
else
    echo "warning: $ICONSET_SRC not found; app will have no icon"
fi

# Info.plist
cp "$PROJECT_ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"

# Add CFBundleExecutable if not present
if ! /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_DIR/Contents/Info.plist" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string relay-runner" "$APP_DIR/Contents/Info.plist"
fi

# SPM resource bundle (contains asset catalog)
RESOURCE_BUNDLE="$BUILD_DIR/relay-runner_relay-runner.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"

    # SPM doesn't compile .xcassets — run actool so Image("TrayIcon") etc. resolve at runtime.
    COPIED_BUNDLE="$APP_DIR/Contents/Resources/relay-runner_relay-runner.bundle"
    XCASSETS="$COPIED_BUNDLE/Assets.xcassets"
    if [ -d "$XCASSETS" ]; then
        echo "==> Compiling Assets.xcassets..."
        xcrun actool "$XCASSETS" \
            --compile "$COPIED_BUNDLE" \
            --platform macosx \
            --minimum-deployment-target 13.0 \
            --output-partial-info-plist /tmp/relay-runner-actool.plist \
            > /dev/null
        rm -rf "$XCASSETS"
    fi
fi

# Python services
for f in voice_bridge.py tts_worker.py tts_filter.py config.py voice_wrap.py preview_voice.py \
         orchestrator.py orchestrator_workflow.md requirements.txt; do
    if [ -f "$PROJECT_ROOT/services/$f" ]; then
        cp "$PROJECT_ROOT/services/$f" "$APP_DIR/Contents/SharedSupport/services/"
    fi
done

# Scripts
cp "$PROJECT_ROOT/scripts/relay-bridge" "$APP_DIR/Contents/SharedSupport/scripts/"
chmod +x "$APP_DIR/Contents/SharedSupport/scripts/relay-bridge"
cp "$PROJECT_ROOT/scripts/relay-orchestrator" "$APP_DIR/Contents/SharedSupport/scripts/"
chmod +x "$APP_DIR/Contents/SharedSupport/scripts/relay-orchestrator"

# Setup script for Python venv (runs on first launch if needed)
cat > "$APP_DIR/Contents/SharedSupport/setup-venv.sh" << 'SETUP_EOF'
#!/bin/bash
# Creates a Python venv with required packages for Relay Runner services.
SERVICES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/services" && pwd)"
VENV_DIR="$SERVICES_DIR/.venv"

if [ -d "$VENV_DIR" ] && [ -x "$VENV_DIR/bin/python3" ]; then
    exit 0  # Already set up
fi

echo "[Relay Runner] Setting up Python environment..."
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet -r "$SERVICES_DIR/requirements.txt"
echo "[Relay Runner] Setup complete."
SETUP_EOF
chmod +x "$APP_DIR/Contents/SharedSupport/setup-venv.sh"

echo "==> Code signing..."

ENTITLEMENTS="$PROJECT_ROOT/scripts/relay-runner.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

if [ -n "$SIGN_IDENTITY" ]; then
    if [ ! -f "$ENTITLEMENTS" ]; then
        echo "error: SIGN_IDENTITY set but $ENTITLEMENTS not found" >&2
        exit 1
    fi
    # Sign nested Mach-O content first (inside-out is required by codesign).
    # The bundled Python services are .py text files — those don't need
    # signing. The only executables are the main binary and the relay-bridge
    # shell script, plus any dylibs / frameworks SPM dropped into the bundle.
    echo "  identity: $SIGN_IDENTITY"
    # Any embedded frameworks / dylibs (FluidAudio ships .dylibs via SPM plugins).
    find "$APP_DIR/Contents" \( -name "*.dylib" -o -name "*.framework" \) -print0 \
        | while IFS= read -r -d '' f; do
            codesign --force --timestamp --options runtime \
                --sign "$SIGN_IDENTITY" "$f"
          done
    # Helper binaries (MCP servers). No entitlements — TCC permissions inherit
    # from the bundle's bundle-id at first prompt. Still needs hardened runtime
    # + timestamp for notarisation.
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" \
        "$APP_DIR/Contents/MacOS/relay-actions-mcp"
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" \
        "$APP_DIR/Contents/MacOS/relay-orchestrator-mcp"
    # Main executable last, with entitlements + hardened runtime.
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP_DIR/Contents/MacOS/relay-runner"
    # Outer bundle seal — must be signed after everything nested is signed.
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP_DIR"
    # Verify. `--deep --strict` catches unsigned nested components that
    # would otherwise be rejected at notarisation / Gatekeeper time.
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
else
    echo "  (no SIGN_IDENTITY set — ad-hoc sign only; this build cannot be"
    echo "   distributed outside this Mac)"
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "==> Creating DMG..."
rm -f "$DIST_DIR/$DMG_NAME.dmg"

DMG_BG_SRC="$PROJECT_ROOT/assets/dmg-background.tiff"
if [ ! -f "$DMG_BG_SRC" ]; then
    echo "==> Generating DMG background..."
    python3 "$PROJECT_ROOT/scripts/generate-dmg-background.py"
fi

# dmgbuild writes the styled .DS_Store layout (background, icon
# positions, Applications drag target, window dimensions) directly via
# the `ds_store` Python library — no Finder, no AppleScript, no Apple
# Events / TCC grants needed. Same output locally and on CI.
#
# Apple's Xcode-bundled `/usr/bin/python3` ships with a too-old pip
# that can't install dmgbuild, so users typically have it on a
# Homebrew or python.org interpreter. Probe common locations until we
# find one with the module importable.
DMGBUILD_PYTHON=""
for __py in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 python; do
    if command -v "$__py" >/dev/null 2>&1 && \
       "$__py" -c 'import dmgbuild' >/dev/null 2>&1; then
        DMGBUILD_PYTHON="$__py"
        break
    fi
done
if [ -z "$DMGBUILD_PYTHON" ]; then
    echo "error: dmgbuild not installed on any python found on PATH." >&2
    echo "Install it with one of:" >&2
    echo "    pip3 install --user --break-system-packages dmgbuild" >&2
    echo "    /opt/homebrew/bin/python3 -m pip install --user --break-system-packages dmgbuild" >&2
    echo "    brew install pipx && pipx install dmgbuild" >&2
    exit 1
fi

RELAY_PROJECT_ROOT="$PROJECT_ROOT" "$DMGBUILD_PYTHON" -m dmgbuild \
    -s "$PROJECT_ROOT/scripts/dmgbuild-settings.py" \
    "$APP_NAME" \
    "$DIST_DIR/$DMG_NAME.dmg"

# Sign the DMG itself. Apple accepts unsigned DMGs into notarisation so this
# isn't strictly required, but a signed DMG passes Gatekeeper assessment
# directly (`spctl -a -t open --context context:primary-signature`) and
# survives renames + re-distribution without breaking the trust chain.
# Ad-hoc builds skip this — there's no identity to sign with.
if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Signing DMG..."
    codesign --force --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$DIST_DIR/$DMG_NAME.dmg"
    codesign --verify --verbose=2 "$DIST_DIR/$DMG_NAME.dmg"
fi

# Notarisation: Apple needs to scan the signed DMG before macOS will run
# it without Gatekeeper prompts on other machines. We skip when there's
# no signing identity (ad-hoc builds aren't notarisable) or no notarytool
# profile.
#
# We submit and return immediately (no `--wait`, no `stapler staple`).
# Apple's notary queue can take hours-to-days for fresh team IDs, and
# blocking CI on it doesn't change the outcome. The DMG ships signed but
# unstapled; Gatekeeper does an online notarisation check on first launch
# (slower cold start but works once Apple processes the submission).
# Once the submission shows "Accepted" in
# `xcrun notarytool history --keychain-profile <profile>`, run
# `xcrun stapler staple` against the DMG and redistribute for a faster
# offline-friendly UX.
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Submitting DMG for notarisation (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$DIST_DIR/$DMG_NAME.dmg" \
        --keychain-profile "$NOTARY_PROFILE"
    echo "==> Submission queued. Track status with:"
    echo "      xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
    echo "    Once 'Accepted', staple with:"
    echo "      xcrun stapler staple \"$DIST_DIR/$DMG_NAME.dmg\""
elif [ -n "$SIGN_IDENTITY" ]; then
    echo "  (SIGN_IDENTITY set but NOTARY_PROFILE unset — skipping notarisation."
    echo "   The DMG is signed but not notarised, so Gatekeeper will warn users.)"
fi

# If the app is already installed under /Applications, refresh it so this
# rebuild is what Spotlight, the Dock and Cmd-Tab actually see.
INSTALLED="/Applications/$APP_NAME.app"
if [ -d "$INSTALLED" ]; then
    echo "==> Updating installed copy at $INSTALLED..."
    rm -rf "$INSTALLED"
    cp -R "$APP_DIR" "$INSTALLED"
    mdimport "$INSTALLED"
fi

echo ""
echo "==> Done!"
echo "    App:  $APP_DIR"
echo "    DMG:  $DIST_DIR/$DMG_NAME.dmg"
echo ""
echo "    Size: $(du -sh "$DIST_DIR/$DMG_NAME.dmg" | cut -f1)"
