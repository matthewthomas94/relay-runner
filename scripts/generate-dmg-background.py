#!/usr/bin/env python3
"""Generate the DMG installer background image.

Produces a 640x420 black canvas with the supplied glass-arrow asset composited
between the eventual app-icon (left) and Applications (right) drop targets.
The window is sized 640x420 in build-dmg.sh; icons sit at x=160 and x=480 and
the arrow fills the gap.

Outputs (under assets/):
  dmg-background.png      640x420   (1x)
  dmg-background@2x.png   1280x840  (2x)
  dmg-background.tiff     HiDPI bundle for Finder

Run:
  python3 scripts/generate-dmg-background.py
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
ARROW_SRC = ASSETS / "glass-arrow.png"

WIDTH = 640
HEIGHT = 420

BG_COLOR = (0, 0, 0, 255)  # solid black, matching the Figma mock

ARROW_TARGET_WIDTH = 90  # @1x; the arrow's native aspect ratio sets the height


def render(scale: int) -> Image.Image:
    w, h = WIDTH * scale, HEIGHT * scale
    img = Image.new("RGBA", (w, h), BG_COLOR)

    arrow = Image.open(ARROW_SRC).convert("RGBA")
    target_w = ARROW_TARGET_WIDTH * scale
    target_h = round(arrow.height * (target_w / arrow.width))
    arrow = arrow.resize((target_w, target_h), Image.LANCZOS)

    x = (w - target_w) // 2
    y = (h - target_h) // 2
    img.paste(arrow, (x, y), arrow)
    return img


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)

    one_x = ASSETS / "dmg-background.png"
    two_x = ASSETS / "dmg-background@2x.png"
    tiff = ASSETS / "dmg-background.tiff"

    render(1).save(one_x)
    render(2).save(two_x)
    print(f"Wrote {one_x.relative_to(ROOT)}  ({WIDTH}x{HEIGHT})")
    print(f"Wrote {two_x.relative_to(ROOT)}  ({WIDTH * 2}x{HEIGHT * 2})")

    # Bundle into a multi-resolution TIFF so Finder picks the right rep.
    subprocess.run(
        ["tiffutil", "-cathidpicheck", str(one_x), str(two_x), "-out", str(tiff)],
        check=True,
    )
    print(f"Wrote {tiff.relative_to(ROOT)}  (HiDPI TIFF)")


if __name__ == "__main__":
    main()
