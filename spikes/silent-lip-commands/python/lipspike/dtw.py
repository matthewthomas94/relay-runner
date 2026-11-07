"""Dynamic time warping with a Sakoe-Chiba band (port of subvox DTW.swift)."""

from __future__ import annotations

import numpy as np


def dtw_distance(a: np.ndarray, b: np.ndarray, band_fraction: float = 0.25) -> float:
    n, m = len(a), len(b)
    if n == 0 or m == 0:
        return float("inf")
    band = max(abs(n - m), int(max(n, m) * band_fraction))
    # Pairwise Euclidean cost matrix.
    cost = np.sqrt(((a[:, None, :] - b[None, :, :]) ** 2).sum(axis=2))
    prev = np.full(m + 1, np.inf)
    prev[0] = 0.0
    for i in range(1, n + 1):
        cur = np.full(m + 1, np.inf)
        lo = max(1, i - band)
        hi = min(m, i + band)
        row = cost[i - 1]
        for j in range(lo, hi + 1):
            cur[j] = row[j - 1] + min(prev[j], cur[j - 1], prev[j - 1])
        prev = cur
    # Normalise by maximum path length so long and short words compare fairly.
    return float(prev[m] / (n + m))
