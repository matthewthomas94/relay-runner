#!/usr/bin/env python3
"""Generate the Relay Runner macOS app icon.

Produces a full AppIcon.appiconset at Sources/relay-runner/Resources/Assets.xcassets/
and a standalone AppIcon.iconset directory that build-dmg.sh converts to AppIcon.icns
via `iconutil`.

Design: macOS Big Sur-style rounded square with a warm orange-pink gradient (matching
the STT particle theme), a cream-colored capsule representing the transcription pill,
and three ascending sound-wave bars suggesting voice input.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Sources/relay-runner/Resources/Assets.xcassets/AppIcon.appiconset"
ICONSET = ROOT / "assets/AppIcon.iconset"

# macOS app icon sizes: (filename, pixel size)
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


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def lerp_color(c1, c2, t):
    return tuple(int(round(lerp(c1[i], c2[i], t))) for i in range(3))


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    """Alpha mask for a rounded square of the given size."""
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def diagonal_gradient(size: int, top_left, bottom_right) -> Image.Image:
    """Warm diagonal gradient image (top-left light, bottom-right dark)."""
    img = Image.new("RGB", (size, size), top_left)
    pixels = img.load()
    # Diagonal gradient: normalize along (x+y)/(2*(size-1))
    denom = 2 * (size - 1) if size > 1 else 1
    for y in range(size):
        for x in range(size):
            t = (x + y) / denom
            pixels[x, y] = lerp_color(top_left, bottom_right, t)
    return img


def radial_highlight(size: int, center, radius_frac: float, strength: float) -> Image.Image:
    """Soft white radial highlight overlay (RGBA)."""
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = overlay.load()
    cx, cy = center
    r = size * radius_frac
    for y in range(size):
        for x in range(size):
            dx = x - cx
            dy = y - cy
            d = math.sqrt(dx * dx + dy * dy)
            if d < r:
                falloff = (1 - d / r) ** 2
                a = int(round(255 * strength * falloff))
                pixels[x, y] = (255, 255, 255, a)
    return overlay


def draw_master(size: int) -> Image.Image:
    """Draw the master icon at the given pixel size.

    All drawing is relative to `size` so sub-sampled renders stay crisp.
    """
    # macOS Big Sur corner radius ratio for a full-bleed icon ~ 0.2237 (185/824)
    # We bake the rounded square directly at 1024 proportions.
    corner_radius = int(round(size * 0.2237))

    # Warm gradient palette (top-left warm peach → bottom-right deep rose)
    c_top = (255, 176, 120)   # warm peach
    c_bot = (214, 84, 110)    # deep rose

    base = diagonal_gradient(size, c_top, c_bot).convert("RGBA")

    # Soft top-left radial highlight for depth
    hl = radial_highlight(size, (size * 0.28, size * 0.24), 0.7, 0.35)
    base = Image.alpha_composite(base, hl)

    # Bottom-right soft shadow for depth
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)
    sdraw.ellipse(
        (
            int(size * 0.55),
            int(size * 0.60),
            int(size * 1.15),
            int(size * 1.20),
        ),
        fill=(80, 20, 40, 110),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=size * 0.08))
    base = Image.alpha_composite(base, shadow)

    # --- Foreground: capsule "pill" with ascending waveform bars ---
    fg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    fdraw = ImageDraw.Draw(fg)

    # Pill dimensions (centered, slightly above center to leave room for shadow)
    pill_w = size * 0.60
    pill_h = size * 0.30
    pill_cx = size * 0.5
    pill_cy = size * 0.55
    pill_l = pill_cx - pill_w / 2
    pill_t = pill_cy - pill_h / 2
    pill_r = pill_cx + pill_w / 2
    pill_b = pill_cy + pill_h / 2
    pill_radius = pill_h / 2

    # Pill drop shadow
    pshadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    psdraw = ImageDraw.Draw(pshadow)
    psdraw.rounded_rectangle(
        (pill_l, pill_t + size * 0.02, pill_r, pill_b + size * 0.04),
        radius=pill_radius,
        fill=(60, 10, 30, 140),
    )
    pshadow = pshadow.filter(ImageFilter.GaussianBlur(radius=size * 0.022))
    fg = Image.alpha_composite(fg, pshadow)
    fdraw = ImageDraw.Draw(fg)

    # Pill body: warm cream
    pill_fill = (255, 244, 228, 255)
    fdraw.rounded_rectangle(
        (pill_l, pill_t, pill_r, pill_b),
        radius=pill_radius,
        fill=pill_fill,
    )

    # Subtle inner top highlight on the pill
    hl_h = pill_h * 0.35
    hl_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hldraw = ImageDraw.Draw(hl_layer)
    hldraw.rounded_rectangle(
        (pill_l + pill_h * 0.15, pill_t + pill_h * 0.08,
         pill_r - pill_h * 0.15, pill_t + hl_h),
        radius=hl_h / 2,
        fill=(255, 255, 255, 110),
    )
    hl_layer = hl_layer.filter(ImageFilter.GaussianBlur(radius=size * 0.008))
    fg = Image.alpha_composite(fg, hl_layer)
    fdraw = ImageDraw.Draw(fg)

    # Waveform: 5 ascending/descending bars inside the pill
    bar_color = (200, 70, 95, 255)  # deep rose accent
    num_bars = 5
    bar_spacing = pill_w * 0.10
    bar_area_w = pill_w * 0.55
    bar_w = bar_area_w / (num_bars + (num_bars - 1) * 0.5)
    bar_gap = bar_w * 0.5
    total_w = num_bars * bar_w + (num_bars - 1) * bar_gap
    start_x = pill_cx - total_w / 2
    # Heights form a gentle symmetric arc (shorter ends, taller middle)
    heights = [0.40, 0.70, 0.95, 0.70, 0.40]
    max_h = pill_h * 0.62
    for i in range(num_bars):
        bx = start_x + i * (bar_w + bar_gap)
        h = max_h * heights[i]
        by_top = pill_cy - h / 2
        by_bot = pill_cy + h / 2
        fdraw.rounded_rectangle(
            (bx, by_top, bx + bar_w, by_bot),
            radius=bar_w / 2,
            fill=bar_color,
        )

    out = Image.alpha_composite(base, fg)

    # Clip to rounded square
    mask = rounded_rect_mask(size, corner_radius)
    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    result.paste(out, (0, 0), mask)
    return result


def main():
    # Render master at 1024 once; down-sample via LANCZOS for other sizes
    # (sharper small icons than re-rendering geometry at 16/32px).
    master = draw_master(1024)

    ASSETS.mkdir(parents=True, exist_ok=True)
    ICONSET.mkdir(parents=True, exist_ok=True)

    for filename, pixel_size in SIZES:
        if pixel_size == 1024:
            img = master.copy()
        else:
            img = master.resize((pixel_size, pixel_size), Image.LANCZOS)
        img.save(ASSETS / filename, "PNG")
        img.save(ICONSET / filename, "PNG")

    # Contents.json for the asset catalog's AppIcon
    contents = """{
  "images" : [
    {"idiom":"mac","scale":"1x","size":"16x16","filename":"icon_16x16.png"},
    {"idiom":"mac","scale":"2x","size":"16x16","filename":"icon_16x16@2x.png"},
    {"idiom":"mac","scale":"1x","size":"32x32","filename":"icon_32x32.png"},
    {"idiom":"mac","scale":"2x","size":"32x32","filename":"icon_32x32@2x.png"},
    {"idiom":"mac","scale":"1x","size":"128x128","filename":"icon_128x128.png"},
    {"idiom":"mac","scale":"2x","size":"128x128","filename":"icon_128x128@2x.png"},
    {"idiom":"mac","scale":"1x","size":"256x256","filename":"icon_256x256.png"},
    {"idiom":"mac","scale":"2x","size":"256x256","filename":"icon_256x256@2x.png"},
    {"idiom":"mac","scale":"1x","size":"512x512","filename":"icon_512x512.png"},
    {"idiom":"mac","scale":"2x","size":"512x512","filename":"icon_512x512@2x.png"}
  ],
  "info" : {"author":"xcode","version":1}
}
"""
    (ASSETS / "Contents.json").write_text(contents)

    print(f"Wrote {len(SIZES)} PNGs to:")
    print(f"  {ASSETS}")
    print(f"  {ICONSET}")


if __name__ == "__main__":
    main()
