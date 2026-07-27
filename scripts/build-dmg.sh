#!/bin/bash
# build-dmg.sh — Build Relay Runner.app and package release archives.
#
# Usage:
#   ./scripts/build-dmg.sh              # Release build + DMG + Sparkle zip
#   ./scripts/build-dmg.sh --debug      # Debug build + DMG + Sparkle zip
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
#                    together with SIGN_IDENTITY, the app is notarised and
#                    stapled before creating the Sparkle zip; the final DMG is
#                    notarised and stapled too.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

APP_NAME="Relay Runner"
BUNDLE_ID="com.relayrunner.app"
DMG_NAME="RelayRunner"
SPARKLE_ZIP_NAME="RelayRunner"

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG="debug"
fi

BUILD_DIR="$PROJECT_ROOT/.build/$CONFIG"
DIST_DIR="$PROJECT_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

remove_tree() {
    local path="$1"
    if [ -e "$path" ]; then
        chmod -R u+w "$path" 2>/dev/null || true
        rm -rf "$path"
    fi
}

submit_notarization() {
    local path="$1"
    local label="$2"
    local log_path="$DIST_DIR/notary-$label.log"
    local submit_failed=0
    rm -f "$log_path"

    if ! xcrun notarytool submit "$path" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$log_path"; then
        submit_failed=1
    fi

    local submission_id=""
    submission_id="$(awk '/id:/ { print $2 }' "$log_path" | tail -n 1)"

    if [ "$submit_failed" -ne 0 ] || ! grep -q "status: Accepted" "$log_path"; then
        echo "error: notarisation failed for $path" >&2
        if [ -n "$submission_id" ]; then
            echo "==> Notary log for $submission_id" >&2
            xcrun notarytool log "$submission_id" \
                --keychain-profile "$NOTARY_PROFILE" || true
        fi
        exit 1
    fi
}

echo "==> Building ($CONFIG)..."
swift build -c "$CONFIG"

echo "==> Creating app bundle..."
remove_tree "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/SharedSupport/services"
mkdir -p "$APP_DIR/Contents/SharedSupport/scripts"

# Binary
cp "$BUILD_DIR/relay-runner" "$APP_DIR/Contents/MacOS/relay-runner"

# Sparkle framework for in-app updates. SwiftPM keeps binary target artifacts
# outside the app bundle, so copy the resolved framework into the standard
# runtime location before signing the bundle.
SPARKLE_FRAMEWORK="$(find "$PROJECT_ROOT/.build/artifacts" "$BUILD_DIR" \
    -maxdepth 8 -type d -name "Sparkle.framework" -print -quit 2>/dev/null || true)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "error: Sparkle.framework not found after swift build" >&2
    exit 1
fi
ditto "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP_DIR/Contents/MacOS/relay-runner" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/relay-runner"
fi

# Helper binary: Relay Actions MCP server. Spawned by the active agent session
# and registered by scripts/relay-bridge. It remains a protocol adapter; the
# Accessibility-gated input work is forwarded to the menu-bar app so TCC
# attribution belongs to Relay Runner.
cp "$BUILD_DIR/relay-actions-mcp" "$APP_DIR/Contents/MacOS/relay-actions-mcp"

# Helper binary: Relay Vision MCP server. The screenshot observation tool,
# split out of relay-actions in RR-10. It forwards ScreenCaptureKit work to
# the menu-bar app so Screen Recording prompts/checks target Relay Runner.
cp "$BUILD_DIR/relay-vision-mcp" "$APP_DIR/Contents/MacOS/relay-vision-mcp"

# Helper binary: Relay Orchestrator MCP server. The orchestrator daemon process
# itself runs under launchd (via scripts/relay-orchestrator) and is just a
# Python script, but the MCP proxy is the Swift binary registered with the
# provider CLIs.
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

# SwiftTerm ships its optional Metal shaders as an SPM resource bundle. The
# embedded terminal currently uses the Core Graphics renderer, but packaging
# the bundle keeps the dependency complete and allows a later renderer switch
# without a release-only resource failure.
SWIFTTERM_RESOURCE_BUNDLE="$BUILD_DIR/SwiftTerm_SwiftTerm.bundle"
if [ -d "$SWIFTTERM_RESOURCE_BUNDLE" ]; then
    cp -R "$SWIFTTERM_RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
else
    echo "error: SwiftTerm resource bundle not found after swift build" >&2
    exit 1
fi

# Python services
for f in voice_bridge.py relay_completion_hook.py messenger.py command_actions.py relay_authorization.py pm_frontstage.py tts_worker.py tts_filter.py config.py voice_wrap.py preview_voice.py codex_model_catalog.py \
         graphify_core.py graphify_ingest.py orchestrator.py orchestrator_workflow.md \
         program_status.py requirements.txt session_capture.py tickets.py; do
    cp "$PROJECT_ROOT/services/$f" "$APP_DIR/Contents/SharedSupport/services/"
done
find "$APP_DIR/Contents/SharedSupport/services" -name "__pycache__" -type d -prune -exec rm -rf {} +
# Python services run from the signed app bundle. Keep the shipped source
# directory read-only so older launchers cannot add __pycache__ files and
# invalidate the bundle after Sparkle installs an update.
chmod -R a-w "$APP_DIR/Contents/SharedSupport/services"

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
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

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
    # Sparkle's framework also contains nested apps, XPC services, and helper
    # executables. Sign all nested code deepest-first so the enclosing bundle
    # seals are created after their children have Developer ID signatures.
    {
        find "$APP_DIR/Contents/Frameworks" \
            \( -name "*.app" -o -name "*.xpc" -o -name "*.framework" -o -name "*.dylib" \) \
            -print
        find "$APP_DIR/Contents/Frameworks" -type f -perm +111 -print | while IFS= read -r f; do
            if file "$f" | grep -q 'Mach-O'; then
                printf '%s\n' "$f"
            fi
        done
    } | awk '{ print length($0) "\t" $0 }' \
        | sort -rn \
        | cut -f2- \
        | awk '!seen[$0]++' \
        | while IFS= read -r f; do
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
        "$APP_DIR/Contents/MacOS/relay-vision-mcp"
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
else
    echo "  (no SIGN_IDENTITY set — ad-hoc sign only; this build cannot be"
    echo "   distributed outside this Mac)"
    codesign --force --deep --sign - "$APP_DIR"
fi
# Verify. `--deep --strict` catches unsigned nested components that
# would otherwise be rejected at notarisation / Gatekeeper time.
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# Notarise and staple the app bundle before creating the Sparkle archive.
# Sparkle validates the downloaded app with Gatekeeper after extraction; if CI
# publishes before Apple's ticket is accepted, users can hit an update failure
# even though the EdDSA archive signature is correct.
if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    APP_NOTARY_ZIP="$DIST_DIR/$SPARKLE_ZIP_NAME-app-notary.zip"
    rm -f "$APP_NOTARY_ZIP"
    echo "==> Creating app notarisation archive..."
    (cd "$DIST_DIR" && ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 \
        "$APP_NAME.app" "$(basename "$APP_NOTARY_ZIP")")

    echo "==> Submitting app for notarisation (profile: $NOTARY_PROFILE)..."
    submit_notarization "$APP_NOTARY_ZIP" "app"

    echo "==> Stapling app notarisation ticket..."
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    spctl -a -vv -t exec "$APP_DIR"
    rm -f "$APP_NOTARY_ZIP"
elif [ -n "$SIGN_IDENTITY" ]; then
    echo "  (SIGN_IDENTITY set but NOTARY_PROFILE unset — skipping notarisation."
    echo "   The app, DMG, and Sparkle zip are signed but not notarised, so Gatekeeper will warn users.)"
fi

echo "==> Creating Sparkle update archive..."
SPARKLE_ZIP="$DIST_DIR/$SPARKLE_ZIP_NAME.zip"
rm -f "$SPARKLE_ZIP"
(cd "$DIST_DIR" && ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 \
    "$APP_NAME.app" "$SPARKLE_ZIP_NAME.zip")

ZIP_SIZE_BYTES=$(stat -f%z "$SPARKLE_ZIP")
if [ "$ZIP_SIZE_BYTES" -lt 1000000 ]; then
    echo "error: created Sparkle zip is unexpectedly small (${ZIP_SIZE_BYTES} bytes); packaging failed." >&2
    exit 1
fi

ZIP_CHECK_DIR="$DIST_DIR/.sparkle-zip-check"
remove_tree "$ZIP_CHECK_DIR"
mkdir -p "$ZIP_CHECK_DIR"
ditto -x -k "$SPARKLE_ZIP" "$ZIP_CHECK_DIR"
if [ ! -d "$ZIP_CHECK_DIR/$APP_NAME.app" ]; then
    echo "error: Sparkle zip does not contain $APP_NAME.app at the archive root." >&2
    exit 1
fi
remove_tree "$ZIP_CHECK_DIR"

echo "==> Creating DMG..."
rm -f "$DIST_DIR/$DMG_NAME.dmg"

DMG_BG_SRC="$PROJECT_ROOT/assets/dmg-background.tiff"
if [ ! -f "$DMG_BG_SRC" ]; then
    echo "==> Generating DMG background..."
    python3 "$PROJECT_ROOT/scripts/generate-dmg-background.py"
fi

# dmgbuild writes the styled .DS_Store layout (background, icon
# position, window dimensions) directly via
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

DMG_SIZE_BYTES=$(stat -f%z "$DIST_DIR/$DMG_NAME.dmg")
if [ "$DMG_SIZE_BYTES" -lt 1000000 ]; then
    echo "error: created DMG is unexpectedly small (${DMG_SIZE_BYTES} bytes); packaging failed." >&2
    exit 1
fi

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

# Notarisation: the app bundle was already notarised and stapled before the
# Sparkle zip was created. The DMG itself also needs a notarisation ticket so
# first-install downloads pass Gatekeeper without a slow online lookup.
if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Submitting DMG for notarisation (profile: $NOTARY_PROFILE)..."
    submit_notarization "$DIST_DIR/$DMG_NAME.dmg" "dmg"
    echo "==> Stapling DMG notarisation ticket..."
    xcrun stapler staple "$DIST_DIR/$DMG_NAME.dmg"
    xcrun stapler validate "$DIST_DIR/$DMG_NAME.dmg"
elif [ -n "$SIGN_IDENTITY" ]; then
    echo "  (SIGN_IDENTITY set but NOTARY_PROFILE unset — skipping notarisation."
    echo "   The DMG and Sparkle zip are signed but not notarised, so Gatekeeper will warn users.)"
fi

# If the app is already installed under /Applications, refresh it so this
# rebuild is what Spotlight, the Dock and Cmd-Tab actually see.
INSTALLED="/Applications/$APP_NAME.app"
if [ "${RELAY_SKIP_APPLICATIONS_REFRESH:-0}" = "1" ]; then
    echo "==> Skipping installed app refresh (RELAY_SKIP_APPLICATIONS_REFRESH=1)."
elif [ -d "$INSTALLED" ]; then
    echo "==> Updating installed copy at $INSTALLED..."
    remove_tree "$INSTALLED"
    cp -R "$APP_DIR" "$INSTALLED"
    mdimport "$INSTALLED"
fi

echo ""
echo "==> Done!"
echo "    App:  $APP_DIR"
echo "    DMG:  $DIST_DIR/$DMG_NAME.dmg"
echo "    Zip:  $SPARKLE_ZIP"
echo ""
echo "    Size: $(du -sh "$DIST_DIR/$DMG_NAME.dmg" | cut -f1)"
echo "    Zip:  $(du -sh "$SPARKLE_ZIP" | cut -f1)"
