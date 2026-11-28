"""Run the subvox-style signal test on GRID word segments.

usage: grid_experiment.py <geometry.npz> <align_dir> [--takes N] [--perms P]
       [--vocab commands|colours|digits|adverbs|all] [--no-velocity]
       [--test-geometry other.npz --test-align other_dir]   # cross-speaker

Each word occurrence in a clip becomes one "take": the geometry frames between
its align start/end plus a 2-frame context pad. Takes are then treated exactly
like user-recorded templates: leave-one-out nearest-neighbour DTW, then a
label-permutation test.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lipspike.classifier import Evaluation, Template, TemplateClassifier  # noqa: E402
from lipspike.grid import VOCABS, read_align  # noqa: E402

PAD = 2


def load_takes(npz_path: str, align_dir: str, vocab: set[str]) -> list[Template]:
    d = np.load(npz_path)
    takes = []
    for name in d["names"]:
        g, ok = d[f"g_{name}"], d[f"v_{name}"]
        align = Path(align_dir) / f"{name}.align"
        if not align.exists():
            continue
        for span in read_align(align):
            if span.word not in vocab:
                continue
            lo, hi = max(0, span.start_frame - PAD), min(len(g), span.end_frame + PAD)
            seg = g[lo:hi]
            if len(seg) < 4 or not ok[lo:hi].all():
                continue
            takes.append(Template(span.word, seg))
    return takes


def subsample(takes: list[Template], per_label: int, rng: random.Random) -> list[Template]:
    by = {}
    for t in takes:
        by.setdefault(t.label, []).append(t)
    out = []
    for label, items in sorted(by.items()):
        rng.shuffle(items)
        out.extend(items[:per_label])
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("geometry")
    ap.add_argument("align_dir")
    ap.add_argument("--vocab", default="colours")
    ap.add_argument("--takes", type=int, default=20)
    ap.add_argument("--perms", type=int, default=300)
    ap.add_argument("--no-velocity", action="store_true")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--test-geometry")
    ap.add_argument("--test-align")
    ap.add_argument("--json")
    args = ap.parse_args()

    vocab = set().union(*VOCABS.values()) if args.vocab == "all" else VOCABS[args.vocab]
    rng = random.Random(args.seed)
    takes = subsample(load_takes(args.geometry, args.align_dir, vocab), args.takes, rng)
    lengths = [len(t.frames) for t in takes]
    print(f"vocab={args.vocab} takes={len(takes)} labels={len({t.label for t in takes})} "
          f"frames/take min={min(lengths)} median={int(np.median(lengths))} max={max(lengths)}")

    ev = Evaluation.run(takes, use_velocity=not args.no_velocity, permutations=args.perms, seed=args.seed)
    print(ev.report())
    result = {
        "vocab": args.vocab, "takes_per_label": args.takes, "velocity": not args.no_velocity,
        "n": ev.template_count, "labels": ev.labels, "accuracy": ev.accuracy, "chance": ev.chance,
        "perm_mean": ev.permutation_mean, "perm_p95": ev.permutation_p95, "p": ev.p_value,
        "per_label": ev.per_label_accuracy, "confusion": ev.confusion.tolist(),
    }

    if args.test_geometry:
        clf = TemplateClassifier(takes, use_velocity=not args.no_velocity)
        test = subsample(load_takes(args.test_geometry, args.test_align, vocab), args.takes, rng)
        hits = sum(1 for t in test if clf.rank(t.frames)[0][0] == t.label)
        acc = hits / len(test)
        print(f"cross-speaker: train on {args.geometry}, test on {args.test_geometry}: accuracy={acc:.3f} n={len(test)}")
        result["cross_speaker_accuracy"] = acc
        result["cross_speaker_n"] = len(test)

    if args.json:
        Path(args.json).write_text(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
