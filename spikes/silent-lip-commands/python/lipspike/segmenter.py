"""Cut a continuous geometry stream into word-sized segments.

Port of subvox CaptureController: a manual hold mode, or an auto mode that
triggers when smoothed articulation energy rises above a calibrated noise
floor, with pre-roll and hangover.
"""

from __future__ import annotations

from collections.abc import Callable

import numpy as np

Frame = tuple[float, list[float]]  # (timestamp seconds, 6 geometry channels)


class Segmenter:
    calibration_seconds = 2.0
    preroll_seconds = 0.3
    hangover_seconds = 0.35
    max_auto_seconds = 3.0
    max_hold_seconds = 6.0

    def __init__(self, on_segment: Callable[[np.ndarray], None], trigger_ratio: float = 3.0):
        self.on_segment = on_segment
        self.trigger_ratio = trigger_ratio
        self.auto_enabled = False
        self.energy = 0.0
        self.noise_floor: float | None = None
        self._capturing = False
        self._manual = False
        self._buffer: list[Frame] = []
        self._preroll: list[Frame] = []
        self._calibrating = False
        self._calibration: list[float] = []
        self._calibration_end: float | None = None
        self._quiet_since: float | None = None
        self._last: list[float] | None = None

    @property
    def threshold(self) -> float | None:
        return None if self.noise_floor is None else self.noise_floor * self.trigger_ratio

    @property
    def is_capturing(self) -> bool:
        return self._capturing

    @property
    def is_calibrating(self) -> bool:
        return self._calibrating

    def begin(self) -> None:
        if self._capturing:
            return
        self._manual = True
        self._capturing = True
        self._buffer = list(self._preroll)

    def end(self) -> None:
        if self._capturing and self._manual:
            self._finish()

    def calibrate(self) -> None:
        self._calibration = []
        self._calibration_end = None
        self._calibrating = True

    def ingest(self, t: float, g: list[float]) -> None:
        # Instantaneous articulation energy: norm of channel velocity.
        e = 0.0 if self._last is None else float(np.linalg.norm(np.subtract(g, self._last)))
        self._last = list(g)
        self.energy = self.energy * 0.6 + e * 0.4

        if self._calibrating:
            if self._calibration_end is None:
                self._calibration_end = t + self.calibration_seconds
            self._calibration.append(self.energy)
            if t >= self._calibration_end:
                s = sorted(self._calibration)
                self.noise_floor = max(s[len(s) // 2], 1e-5)
                self._calibrating = False

        self._preroll.append((t, list(g)))
        while self._preroll and self._preroll[0][0] < t - self.preroll_seconds:
            self._preroll.pop(0)

        thr = self.threshold
        if self._capturing:
            self._buffer.append((t, list(g)))
            duration = t - self._buffer[0][0]
            if self._manual:
                if duration > self.max_hold_seconds:
                    self._finish()
            elif thr is not None:
                if self.energy < thr * 0.7:
                    self._quiet_since = t if self._quiet_since is None else self._quiet_since
                    if t - self._quiet_since > self.hangover_seconds:
                        self._finish()
                else:
                    self._quiet_since = None
                if self._capturing and duration > self.max_auto_seconds:
                    self._finish()
        elif self.auto_enabled and not self._calibrating and thr is not None and self.energy > thr:
            self._manual = False
            self._capturing = True
            self._quiet_since = None
            self._buffer = list(self._preroll)

    def _finish(self) -> None:
        seg = self._buffer
        self._buffer = []
        self._capturing = False
        self._manual = False
        self._quiet_since = None
        if len(seg) >= 4 and seg[-1][0] - seg[0][0] >= 0.15:
            self.on_segment(np.array([g for _, g in seg], dtype=float))
