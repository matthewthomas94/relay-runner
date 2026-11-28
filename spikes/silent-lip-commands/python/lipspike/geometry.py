"""Raw per-frame lip geometry.

Both landmark sources (Apple Vision on the Mac, MediaPipe here) reduce a face to
the same 6 numbers so templates and evaluation code never see landmarks:

  width       mouth-corner distance
  outer_h     outer-lip vertical extent
  inner_h     inner-lip vertical extent (aperture)
  outer_area  outer-lip polygon area
  inner_area  inner-lip polygon area
  jaw         eye-midpoint to chin distance

Lengths are divided by the inter-ocular distance, areas by its square, so the
numbers are invariant to camera distance and resolution.
"""

from __future__ import annotations

import math
from typing import Sequence

CHANNELS = ("width", "outer_h", "inner_h", "outer_area", "inner_area", "jaw")

Point = tuple[float, float]


def polygon_area(points: Sequence[Point]) -> float:
    """Shoelace area of a closed polygon given in order."""
    if len(points) < 3:
        return 0.0
    s = 0.0
    for i, (x0, y0) in enumerate(points):
        x1, y1 = points[(i + 1) % len(points)]
        s += x0 * y1 - x1 * y0
    return abs(s) / 2.0


def dist(a: Point, b: Point) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def frame_from_contours(
    outer: Sequence[Point],
    inner: Sequence[Point],
    left_eye: Point,
    right_eye: Point,
    chin: Point,
) -> list[float]:
    """Compute the 6 geometry channels from lip contours and anchor points."""
    iod = dist(left_eye, right_eye)
    if iod <= 1e-9:
        raise ValueError("degenerate inter-ocular distance")
    xs = [p[0] for p in outer]
    ys = [p[1] for p in outer]
    iys = [p[1] for p in inner]
    eye_mid = ((left_eye[0] + right_eye[0]) / 2, (left_eye[1] + right_eye[1]) / 2)
    return [
        (max(xs) - min(xs)) / iod,
        (max(ys) - min(ys)) / iod,
        (max(iys) - min(iys)) / iod if inner else 0.0,
        polygon_area(outer) / (iod * iod),
        polygon_area(inner) / (iod * iod),
        dist(eye_mid, chin) / iod,
    ]
