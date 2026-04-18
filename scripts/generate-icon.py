#!/usr/bin/env python3
"""Slice the master Relay Runner icon into the macOS appiconset + iconset.

Source: assets/RR - App Icon.png. The master ships with its rounded-square
shape drawn on an opaque black square; we resample to each target size and then
knock out the corners with a rounded-rect alpha mask matching the macOS Big Sur
radius. The visible artwork inside the rounded shape is left untouched.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/RR - App Icon.png"
ASSETS = ROOT / "Sources/relay-runner/Resources/Assets.xcassets/AppIcon.appiconset"
ICONSET = ROOT / "assets/AppIcon.iconset"

SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

CORNER_RADIUS_FRAC = 0.2237  # macOS Big Sur full-bleed icon ratio

CONTENTS_JSON = """{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""


def round_corners(img: Image.Image) -> Image.Image:
    """Knock out the corners with a Big Sur rounded-rect alpha mask."""
    size = img.size[0]
    radius = int(round(size * CORNER_RADIUS_FRAC))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask=mask)
    return out


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"Source image not found: {SOURCE}")

    ASSETS.mkdir(parents=True, exist_ok=True)
    ICONSET.mkdir(parents=True, exist_ok=True)

    src = Image.open(SOURCE).convert("RGBA")
    print(f"Source: {SOURCE.name} {src.size[0]}x{src.size[1]}")

    cache: dict[int, Image.Image] = {}
    for filename, px in SIZES:
        if px not in cache:
            resized = src.resize((px, px), Image.LANCZOS)
            cache[px] = round_corners(resized)
        out = cache[px]
        for outdir in (ASSETS, ICONSET):
            out.save(outdir / filename)
        print(f"  {filename:32s} {px}x{px}")

    (ASSETS / "Contents.json").write_text(CONTENTS_JSON)
    print(f"\nWrote {ASSETS}")
    print(f"Wrote {ICONSET}")


if __name__ == "__main__":
    main()
