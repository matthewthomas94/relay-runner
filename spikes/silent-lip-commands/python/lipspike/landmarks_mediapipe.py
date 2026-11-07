"""MediaPipe Face Landmarker -> per-frame lip geometry.

Used here (Linux, no Apple frameworks) to validate the pipeline on video, and
usable on a Mac as a fallback to the Vision-based recorder. Both sources emit
the same 6 geometry channels (see geometry.py).
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from .geometry import frame_from_contours

# FaceMesh indices (MediaPipe canonical 478-point topology), in contour order.
OUTER_LIPS = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185]
INNER_LIPS = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191]
LEFT_EYE = [33, 133]
RIGHT_EYE = [362, 263]
CHIN = 152


def _mean_point(lm, idx, w, h):
    return (sum(lm[i].x for i in idx) / len(idx) * w, sum(lm[i].y for i in idx) / len(idx) * h)


class LandmarkExtractor:
    def __init__(self, model_path: str | Path):
        import mediapipe as mp
        from mediapipe.tasks import python as mp_python
        from mediapipe.tasks.python import vision

        self._mp = mp
        opts = vision.FaceLandmarkerOptions(
            base_options=mp_python.BaseOptions(model_asset_path=str(model_path)),
            running_mode=vision.RunningMode.VIDEO,
            num_faces=1,
        )
        self._make = lambda: vision.FaceLandmarker.create_from_options(opts)

    def video_geometry(self, path: str | Path) -> tuple[np.ndarray, np.ndarray]:
        """Return (geometry (T,6), valid (T,) bool). Frames without a face are NaN."""
        import cv2

        cap = cv2.VideoCapture(str(path))
        fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
        out, valid = [], []
        landmarker = self._make()
        i = 0
        try:
            while True:
                ok, bgr = cap.read()
                if not ok:
                    break
                h, w = bgr.shape[:2]
                rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
                image = self._mp.Image(image_format=self._mp.ImageFormat.SRGB, data=rgb)
                res = landmarker.detect_for_video(image, int(i * 1000 / fps))
                i += 1
                if not res.face_landmarks:
                    out.append([np.nan] * 6)
                    valid.append(False)
                    continue
                lm = res.face_landmarks[0]
                pts = lambda idx: [(lm[k].x * w, lm[k].y * h) for k in idx]
                out.append(
                    frame_from_contours(
                        pts(OUTER_LIPS),
                        pts(INNER_LIPS),
                        _mean_point(lm, LEFT_EYE, w, h),
                        _mean_point(lm, RIGHT_EYE, w, h),
                        (lm[CHIN].x * w, lm[CHIN].y * h),
                    )
                )
                valid.append(True)
        finally:
            landmarker.close()
            cap.release()
        return np.array(out, dtype=float), np.array(valid, dtype=bool)
