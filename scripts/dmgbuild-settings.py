"""dmgbuild settings for Relay Runner's installer DMG.

Invoked by scripts/build-dmg.sh. Produces the styled installer window
(custom background, positioned app icon, Applications drag target)
without needing Apple Events / Finder — works identically on CI
runners and local Macs.

Why not osascript+Finder: GitHub-hosted macOS runners lack the
Apple Events / Accessibility TCC grants `tell application "Finder"`
needs, so the AppleScript path silently produced unstyled DMGs on
CI builds. dmgbuild writes `.DS_Store` directly via the `ds_store`
Python library — no Finder involvement, deterministic output.

Run directly to debug:
    python3 -m dmgbuild -s scripts/dmgbuild-settings.py "Relay Runner" out.dmg
"""
import os

# dmgbuild evaluates settings with `exec(..., settings, settings)`, so
# `__file__` isn't defined here. build-dmg.sh exports
# `RELAY_PROJECT_ROOT` before invoking us; fall back to cwd for the
# (rare) case of running dmgbuild manually from the repo root.
PROJECT_ROOT = os.environ.get("RELAY_PROJECT_ROOT", os.getcwd())
APP_NAME = "Relay Runner"
APP_PATH = os.path.join(PROJECT_ROOT, "dist", f"{APP_NAME}.app")
BG_PATH = os.path.join(PROJECT_ROOT, "assets", "dmg-background.tiff")

# -- Volume / disk image --
volume_name = APP_NAME
format = "UDZO"
filesystem = "HFS+"
# size = None lets dmgbuild auto-pick based on contents.
size = None

# -- Contents --
files = [APP_PATH]
symlinks = {"Applications": "/Applications"}

# -- Window layout (matches the prior osascript bounds: 200,120 → 840,540) --
window_rect = ((200, 120), (640, 420))
icon_size = 128
text_size = 13
icon_locations = {
    f"{APP_NAME}.app": (160, 210),
    "Applications": (480, 210),
}
default_view = "icon-view"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

# -- Background --
background = BG_PATH
