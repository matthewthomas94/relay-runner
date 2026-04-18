#!/usr/bin/env python3
"""Slice the master Relay Runner icon into the macOS appiconset + iconset.

Source: assets/RR - App Icon.png (square master, ideally ≥1024 px).
Outputs:
  - Sources/relay-runner/Resources/Assets.xcassets/AppIcon.appiconset/
  - assets/AppIcon.iconset/

Applies the macOS Big Sur rounded-square mask before sub-sampling so every
emitted size has the standard corner radius.
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


def center_crop_square(img: Image.Image) -> Image.Image:
    w, h = img.size
    if w == h:
        return img
    side = min(w, h)
    left = (w - side) // 2
    top = (h - side) // 2
    return img.crop((left, top, left + side, top + side))


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def apply_rounded_mask(img: Image.Image) -> Image.Image:
    size = img.size[0]
    radius = int(round(size * CORNER_RADIUS_FRAC))
    mask = rounded_mask(size, radius)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img.convert("RGBA"), (0, 0), mask=mask)
    return out


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"Source image not found: {SOURCE}")

    ASSETS.mkdir(parents=True, exist_ok=True)
    ICONSET.mkdir(parents=True, exist_ok=True)

    src = Image.open(SOURCE).convert("RGBA")
    src = center_crop_square(src)
    print(f"Source: {SOURCE.name} {src.size[0]}x{src.size[1]}")

    # Mask the master once at full resolution, then resample for each target size.
    masked_master = apply_rounded_mask(src)

    cache: dict[int, Image.Image] = {}
    for filename, px in SIZES:
        if px not in cache:
            cache[px] = masked_master.resize((px, px), Image.LANCZOS)
        out = cache[px]
        for outdir in (ASSETS, ICONSET):
            out.save(outdir / filename)
        print(f"  {filename:32s} {px}x{px}")

    (ASSETS / "Contents.json").write_text(CONTENTS_JSON)
    print(f"\nWrote {ASSETS}")
    print(f"Wrote {ICONSET}")


if __name__ == "__main__":
    main()
