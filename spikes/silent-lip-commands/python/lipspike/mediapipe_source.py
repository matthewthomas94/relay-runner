"""Frame source that prints JSONL lip geometry from a webcam or video file.

    python -m lipspike.mediapipe_source --model face_landmarker.task [--camera 0 | --video clip.mp4]

Same output contract as the Mac `LipCapture` tool, so `lipspike record/decode`
can use either:  {"t": seconds, "g": [6 channels]}
"""

from __future__ import annotations

import argparse
import json
import sys
import time

from .geometry import frame_from_contours
from .landmarks_mediapipe import CHIN, INNER_LIPS, LEFT_EYE, OUTER_LIPS, RIGHT_EYE, _mean_point


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--camera", type=int, default=0)
    ap.add_argument("--video")
    args = ap.parse_args(argv)

    import cv2
    import mediapipe as mp
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision

    opts = vision.FaceLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=args.model),
        running_mode=vision.RunningMode.VIDEO,
        num_faces=1,
    )
    landmarker = vision.FaceLandmarker.create_from_options(opts)
    cap = cv2.VideoCapture(args.video if args.video else args.camera)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    start = time.monotonic()
    i = 0
    try:
        while True:
            ok, bgr = cap.read()
            if not ok:
                break
            t = i / fps if args.video else time.monotonic() - start
            h, w = bgr.shape[:2]
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            res = landmarker.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), int(t * 1000))
            i += 1
            if not res.face_landmarks:
                continue
            lm = res.face_landmarks[0]
            pts = lambda idx: [(lm[k].x * w, lm[k].y * h) for k in idx]
            g = frame_from_contours(
                pts(OUTER_LIPS), pts(INNER_LIPS),
                _mean_point(lm, LEFT_EYE, w, h), _mean_point(lm, RIGHT_EYE, w, h),
                (lm[CHIN].x * w, lm[CHIN].y * h),
            )
            sys.stdout.write(json.dumps({"t": round(t, 4), "g": [round(x, 6) for x in g]}) + "\n")
            sys.stdout.flush()
    finally:
        landmarker.close()
        cap.release()


if __name__ == "__main__":
    main()
