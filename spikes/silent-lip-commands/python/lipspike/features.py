"""Segment-level feature extraction: trim, mean-centre, add velocities, scale.

Ported from subvox MotionFeatures with lips instead of head motion.
"""

from __future__ import annotations

import numpy as np

from .geometry import CHANNELS


def velocity(frames: np.ndarray) -> np.ndarray:
    """First difference along time, zero-padded at the start."""
    v = np.diff(frames, axis=0, prepend=frames[:1])
    return v


def energy(frames: np.ndarray) -> np.ndarray:
    """Per-frame articulation activity: L2 norm of channel velocities.

    Geometry channels are already distance-normalised, so no reweighting is
    needed (subvox needed a 5x weight to balance rad/s against g).
    """
    return np.linalg.norm(velocity(frames), axis=1)


def trim(frames: np.ndarray, padding: int = 2, min_len: int = 5) -> np.ndarray:
    """Drop quiet lead-in / lead-out frames so templates align on articulation.

    Threshold is relative to the segment itself, so training and decoding
    behave the same.
    """
    n = len(frames)
    if n <= 6:
        return frames
    e = energy(frames)
    s = np.sort(e)
    floor = s[n // 5]
    peak = s[-1]
    if peak <= floor * 1.5:
        return frames
    thr = floor + 0.15 * (peak - floor)
    active = np.flatnonzero(e > thr)
    if len(active) == 0:
        return frames
    lo = max(0, int(active[0]) - padding)
    hi = min(n - 1, int(active[-1]) + padding)
    if hi - lo + 1 < min_len:
        return frames
    return frames[lo : hi + 1]


def segment_features(frames: np.ndarray, use_velocity: bool = True) -> np.ndarray:
    """Per-frame feature vectors for one segment.

    Mean-centering per channel removes the speaker's resting mouth shape and
    slow posture drift (the lip analogue of subvox removing heading bias).
    """
    f = np.asarray(frames, dtype=float)
    if f.ndim != 2 or f.shape[1] != len(CHANNELS):
        raise ValueError(f"expected (T, {len(CHANNELS)}) frames, got {f.shape}")
    f = trim(f)
    centred = f - f.mean(axis=0, keepdims=True)
    if use_velocity:
        return np.concatenate([centred, velocity(f)], axis=1)
    return centred


def channel_scales(sequences: list[np.ndarray]) -> np.ndarray:
    """Per-channel std across a corpus so no channel dominates the distance."""
    stacked = np.concatenate(sequences, axis=0)
    if len(stacked) < 2:
        return np.ones(stacked.shape[1])
    return np.maximum(stacked.std(axis=0), 1e-6)


def scaled(frames: np.ndarray, scales: np.ndarray) -> np.ndarray:
    return frames / scales
