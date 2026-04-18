#!/bin/bash
# build-dmg.sh — Build Relay Runner.app and package into a DMG.
#
# Usage:
#   ./scripts/build-dmg.sh              # Release build + DMG
#   ./scripts/build-dmg.sh --debug      # Debug build + DMG

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

# Ad-hoc code sign
echo "==> Code signing..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Creating DMG..."
rm -f "$DIST_DIR/$DMG_NAME.dmg"

# Create a temporary DMG directory
DMG_STAGING="$DIST_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DIST_DIR/$DMG_NAME.dmg"

rm -rf "$DMG_STAGING"

echo ""
echo "==> Done!"
echo "    App:  $APP_DIR"
echo "    DMG:  $DIST_DIR/$DMG_NAME.dmg"
echo ""
echo "    Size: $(du -sh "$DIST_DIR/$DMG_NAME.dmg" | cut -f1)"
