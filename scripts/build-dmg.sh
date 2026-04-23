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
for f in voice_bridge.py tts_worker.py tts_filter.py config.py voice_wrap.py requirements.txt; do
    if [ -f "$PROJECT_ROOT/services/$f" ]; then
        cp "$PROJECT_ROOT/services/$f" "$APP_DIR/Contents/SharedSupport/services/"
    fi
done

# Scripts
cp "$PROJECT_ROOT/scripts/relay-bridge" "$APP_DIR/Contents/SharedSupport/scripts/"
chmod +x "$APP_DIR/Contents/SharedSupport/scripts/relay-bridge"

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

# Stage the contents of the DMG: the app, an Applications symlink for the
# drag target, and a hidden .background folder holding the installer artwork.
DMG_STAGING="$DIST_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING/.background"
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

DMG_BG_SRC="$PROJECT_ROOT/assets/dmg-background.tiff"
if [ ! -f "$DMG_BG_SRC" ]; then
    echo "==> Generating DMG background..."
    python3 "$PROJECT_ROOT/scripts/generate-dmg-background.py"
fi
cp "$DMG_BG_SRC" "$DMG_STAGING/.background/background.tiff"

# Build a writable DMG so we can script Finder before locking it down.
DMG_TMP="$DIST_DIR/$DMG_NAME-tmp.dmg"
rm -f "$DMG_TMP"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -fs HFS+ \
    -format UDRW \
    "$DMG_TMP"

echo "==> Customizing DMG window..."
MOUNT_POINT="/Volumes/$APP_NAME"

# A leftover mount from a previous failed run will block reattach — eject it.
if [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
fi

hdiutil attach "$DMG_TMP" -readwrite -noautoopen -noverify >/dev/null

# Wait for Finder to register the volume — polling beats a fixed sleep.
for _ in $(seq 1 20); do
    if [ -d "$MOUNT_POINT" ]; then break; fi
    sleep 0.5
done

# Wait for Finder to register the volume (not just the kernel mount)
for _ in $(seq 1 20); do
    if [ "$(osascript -e "tell application \"Finder\" to exists disk \"$APP_NAME\"" 2>/dev/null)" = "true" ]; then break; fi
    sleep 0.5
done
# Nudge Finder to enumerate disks so the subsequent `tell disk` resolves
osascript -e 'tell application "Finder" to name of every disk' >/dev/null 2>&1 || true

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {200, 120, 840, 540}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set text size of theViewOptions to 13
        set background picture of theViewOptions to file ".background:background.tiff"
        set position of item "$APP_NAME.app" of container window to {160, 210}
        set position of item "Applications" of container window to {480, 210}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_POINT" >/dev/null

echo "==> Compressing DMG..."
hdiutil convert "$DMG_TMP" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DIST_DIR/$DMG_NAME.dmg" >/dev/null

rm -f "$DMG_TMP"
rm -rf "$DMG_STAGING"

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
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Submitting DMG for notarisation (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$DIST_DIR/$DMG_NAME.dmg" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    echo "==> Stapling ticket..."
    xcrun stapler staple "$DIST_DIR/$DMG_NAME.dmg"
    # Verify so a broken staple fails the build here, not on a user's Mac.
    xcrun stapler validate "$DIST_DIR/$DMG_NAME.dmg"
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
