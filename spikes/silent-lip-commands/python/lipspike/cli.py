"""lipspike command line.

  lipspike record   --label stop --takes 10        record templates from a camera stream
  lipspike evaluate                                leave-one-out + permutation test
  lipspike decode                                  live nearest-template decode
  lipspike export                                  dump dataset summary

The camera stream is any process that prints one JSON object per frame on
stdout: {"t": <seconds>, "g": [width, outer_h, inner_h, outer_area, inner_area, jaw]}.
On a Mac that is the Vision-based `LipCapture` tool in ../mac; anywhere else,
`lipspike.landmarks_mediapipe` can feed it from a webcam or a video file.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import shlex
import subprocess
import sys
import threading
import time
from dataclasses import asdict
from pathlib import Path

import numpy as np

from .classifier import Evaluation, Template, TemplateClassifier
from .segmenter import Segmenter

DEFAULT_DATASET = Path(os.environ.get("LIPSPIKE_DATASET", Path.home() / ".lipspike" / "dataset.json"))
DEFAULT_SOURCE = os.environ.get("LIPSPIKE_SOURCE", "../mac/.build/release/LipCapture stream")


def load_dataset(path: Path) -> list[Template]:
    if not path.exists():
        return []
    raw = json.loads(path.read_text())
    return [Template(t["label"], np.array(t["frames"], dtype=float)) for t in raw]


def save_dataset(path: Path, templates: list[Template]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps([{"label": t.label, "frames": t.frames.tolist()} for t in templates]))


class FrameSource:
    """Reads JSONL frames from a subprocess on a background thread."""

    def __init__(self, command: str):
        self.proc = subprocess.Popen(shlex.split(command), stdout=subprocess.PIPE, text=True, bufsize=1)
        self.q: queue.Queue[tuple[float, list[float]]] = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                d = json.loads(line)
                self.q.put((float(d["t"]), [float(x) for x in d["g"]]))
            except (ValueError, KeyError):
                continue

    def drain(self) -> list[tuple[float, list[float]]]:
        out = []
        while True:
            try:
                out.append(self.q.get_nowait())
            except queue.Empty:
                return out

    def close(self) -> None:
        self.proc.terminate()


def cmd_record(args: argparse.Namespace) -> None:
    templates = load_dataset(args.dataset)
    src = FrameSource(args.source)
    print(f"Recording {args.takes} takes of '{args.label}', {args.seconds:.1f}s each. Dataset: {args.dataset}")
    print("Wait for frames to start flowing, then press Enter and mouth the word silently.")
    # Wait until the camera is producing frames.
    while not src.drain():
        time.sleep(0.1)
    try:
        for k in range(args.takes):
            input(f"[{k + 1}/{args.takes}] Enter to record '{args.label}'... ")
            src.drain()
            frames: list[list[float]] = []
            t_end = time.time() + args.seconds
            while time.time() < t_end:
                frames.extend(g for _, g in src.drain())
                time.sleep(0.01)
            if len(frames) < 6:
                print("   too few frames; is the face in view? take discarded")
                continue
            templates.append(Template(args.label, np.array(frames)))
            print(f"   stored {len(frames)} frames")
        save_dataset(args.dataset, templates)
        print(f"Saved. Dataset now has {len(templates)} takes across {len({t.label for t in templates})} labels.")
    finally:
        src.close()


def cmd_evaluate(args: argparse.Namespace) -> None:
    templates = load_dataset(args.dataset)
    ev = Evaluation.run(templates, use_velocity=not args.no_velocity, permutations=args.perms, seed=args.seed)
    print(ev.report())
    print("confusion rows=actual cols=predicted, labels:", ev.labels)
    print(ev.confusion)
    if ev.p_value < 0.05:
        print("RESULT: lip geometry separates these words better than chance (p < 0.05).")
    else:
        print("RESULT: not distinguishable from chance. Record more takes, or articulate more.")


def cmd_decode(args: argparse.Namespace) -> None:
    templates = load_dataset(args.dataset)
    clf = TemplateClassifier(templates, use_velocity=not args.no_velocity)
    print(f"Vocabulary: {clf.labels}")

    def on_segment(frames: np.ndarray) -> None:
        p = clf.predict(frames, args.max_distance, args.min_confidence)
        ranked = ", ".join(f"{l}:{d:.2f}" for l, d in p.ranked[:3])
        tag = p.best if p.accepted else f"? ({p.best})"
        print(f"{tag:>14}  conf={p.confidence:.2f}  frames={len(frames)}  [{ranked}]", flush=True)

    seg = Segmenter(on_segment, trigger_ratio=args.trigger_ratio)
    src = FrameSource(args.source)
    seg.calibrate()
    print("Calibrating noise floor: keep your mouth still for 2 seconds...")
    try:
        while True:
            for t, g in src.drain():
                seg.ingest(t, g)
                if not seg.is_calibrating and not seg.auto_enabled:
                    seg.auto_enabled = True
                    print(f"Listening (noise floor={seg.noise_floor:.4f}, threshold={seg.threshold:.4f}). Mouth a word.")
            time.sleep(0.01)
    except KeyboardInterrupt:
        pass
    finally:
        src.close()


def cmd_export(args: argparse.Namespace) -> None:
    templates = load_dataset(args.dataset)
    by: dict[str, list[int]] = {}
    for t in templates:
        by.setdefault(t.label, []).append(len(t.frames))
    for label, lens in sorted(by.items()):
        print(f"{label:>12}: {len(lens)} takes, frames min={min(lens)} median={int(np.median(lens))} max={max(lens)}")


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="lipspike", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    ap.add_argument("--source", default=DEFAULT_SOURCE, help="command that prints JSONL geometry frames")
    ap.add_argument("--no-velocity", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("record")
    r.add_argument("--label", required=True)
    r.add_argument("--takes", type=int, default=10)
    r.add_argument("--seconds", type=float, default=1.5)
    r.set_defaults(fn=cmd_record)

    e = sub.add_parser("evaluate")
    e.add_argument("--perms", type=int, default=500)
    e.add_argument("--seed", type=int, default=0)
    e.set_defaults(fn=cmd_evaluate)

    d = sub.add_parser("decode")
    d.add_argument("--max-distance", type=float, default=1.5)
    d.add_argument("--min-confidence", type=float, default=0.1)
    d.add_argument("--trigger-ratio", type=float, default=3.0)
    d.set_defaults(fn=cmd_decode)

    x = sub.add_parser("export")
    x.set_defaults(fn=cmd_export)

    args = ap.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
