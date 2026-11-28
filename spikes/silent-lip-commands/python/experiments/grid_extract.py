"""Extract per-frame lip geometry for GRID clips with MediaPipe and cache it.

usage: grid_extract.py <grid_speaker_dir> <model.task> <out.npz> [--limit N]
Reads <dir>/<spk>/*.mpg and <dir>/align/*.align.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lipspike.landmarks_mediapipe import LandmarkExtractor  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("speaker_dir")
    ap.add_argument("model")
    ap.add_argument("out")
    ap.add_argument("--limit", type=int, default=400)
    args = ap.parse_args()
    root = Path(args.speaker_dir)
    videos = sorted(p for p in root.rglob("*.mpg"))[: args.limit]
    ext = LandmarkExtractor(args.model)
    geo, valid, names = {}, {}, []
    t0 = time.time()
    for k, v in enumerate(videos):
        g, ok = ext.video_geometry(v)
        geo[v.stem] = g
        valid[v.stem] = ok
        names.append(v.stem)
        if k % 25 == 0:
            print(f"{k}/{len(videos)} {v.stem} frames={len(g)} valid={ok.mean():.2f} {time.time()-t0:.0f}s", flush=True)
    np.savez_compressed(args.out, names=np.array(names), **{f"g_{n}": geo[n] for n in names}, **{f"v_{n}": valid[n] for n in names})
    print("saved", args.out, len(names))


if __name__ == "__main__":
    main()
