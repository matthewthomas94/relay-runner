#!/usr/bin/env python3
"""Generate the DMG installer background image.

Produces a 640x420 installer canvas with Relay Runner install copy.
The window is sized 640x420 in dmgbuild-settings.py; the app icon sits
centered below the headline.

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

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"

WIDTH = 640
HEIGHT = 420

BG_COLOR = (7, 7, 9, 255)
TEXT_COLOR = (245, 245, 247, 255)
SECONDARY_TEXT_COLOR = (166, 166, 173, 255)


def font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw_centered(
    draw: ImageDraw.ImageDraw,
    text: str,
    y: int,
    selected_font,
    fill,
    width: int,
) -> None:
    bbox = draw.textbbox((0, 0), text, font=selected_font)
    x = (width - (bbox[2] - bbox[0])) // 2
    draw.text((x, y), text, font=selected_font, fill=fill)


def render(scale: int) -> Image.Image:
    w, h = WIDTH * scale, HEIGHT * scale
    img = Image.new("RGBA", (w, h), BG_COLOR)

    draw = ImageDraw.Draw(img)
    draw_centered(draw, "Install Relay Runner", 58 * scale, font(32 * scale), TEXT_COLOR, w)
    draw_centered(
        draw,
        "Double-click the app icon to install.",
        104 * scale,
        font(17 * scale),
        SECONDARY_TEXT_COLOR,
        w,
    )
    draw_centered(
        draw,
        "Relay Runner will copy itself to Applications and launch.",
        362 * scale,
        font(14 * scale),
        SECONDARY_TEXT_COLOR,
        w,
    )
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
