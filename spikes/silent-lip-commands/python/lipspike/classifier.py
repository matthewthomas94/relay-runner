"""Nearest-neighbour DTW template classifier and its honesty check.

`Evaluation.run` is leave-one-out accuracy plus a label-permutation test, the
same procedure subvox uses to answer "is the signal real?".
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field

import numpy as np

from .dtw import dtw_distance
from .features import channel_scales, scaled, segment_features


@dataclass
class Template:
    label: str
    frames: np.ndarray  # (T, 6) raw geometry


@dataclass
class Prediction:
    ranked: list[tuple[str, float]]
    confidence: float
    accepted: bool

    @property
    def best(self) -> str | None:
        return self.ranked[0][0] if self.ranked else None


def margin(sorted_distances: list[float]) -> float:
    if len(sorted_distances) < 2 or sorted_distances[1] <= 0:
        return 0.0
    return max(0.0, 1.0 - sorted_distances[0] / sorted_distances[1])


class TemplateClassifier:
    def __init__(self, templates: list[Template], use_velocity: bool = True, band: float = 0.25):
        if len({t.label for t in templates}) < 2:
            raise ValueError("need at least two labels")
        self.use_velocity = use_velocity
        self.band = band
        raw = [segment_features(t.frames, use_velocity) for t in templates]
        self.scales = channel_scales(raw)
        self.entries = [(t.label, scaled(r, self.scales)) for t, r in zip(templates, raw)]

    @property
    def labels(self) -> list[str]:
        return sorted({l for l, _ in self.entries})

    def rank(self, frames: np.ndarray) -> list[tuple[str, float]]:
        q = scaled(segment_features(frames, self.use_velocity), self.scales)
        best: dict[str, float] = {}
        for label, ref in self.entries:
            d = dtw_distance(q, ref, self.band)
            best[label] = min(best.get(label, float("inf")), d)
        return sorted(best.items(), key=lambda kv: kv[1])

    def predict(self, frames: np.ndarray, max_distance: float, min_confidence: float) -> Prediction:
        ranked = self.rank(frames)
        conf = margin([d for _, d in ranked])
        accepted = bool(ranked) and ranked[0][1] <= max_distance and conf >= min_confidence
        return Prediction(ranked, conf, accepted)


@dataclass
class Evaluation:
    labels: list[str]
    confusion: np.ndarray  # [actual][predicted]
    accuracy: float
    chance: float  # always guess the most common label
    permutation_mean: float
    permutation_p95: float
    p_value: float
    permutations: int
    template_count: int
    per_label_accuracy: dict[str, float] = field(default_factory=dict)

    @staticmethod
    def run(
        templates: list[Template],
        use_velocity: bool = True,
        band: float = 0.25,
        permutations: int = 500,
        seed: int | None = None,
    ) -> "Evaluation":
        labels = sorted({t.label for t in templates})
        counts = {l: sum(1 for t in templates if t.label == l) for l in labels}
        if len(labels) < 2 or min(counts.values()) < 2:
            raise ValueError("need >= 2 labels with >= 2 takes each")
        raw = [segment_features(t.frames, use_velocity) for t in templates]
        scales = channel_scales(raw)
        seqs = [scaled(r, scales) for r in raw]
        n = len(seqs)

        # Pairwise distances once; every labelling (true or permuted) reuses them.
        D = np.zeros((n, n))
        for i in range(n):
            for j in range(i + 1, n):
                D[i, j] = D[j, i] = dtw_distance(seqs[i], seqs[j], band)
        np.fill_diagonal(D, np.inf)

        index = {l: k for k, l in enumerate(labels)}
        truth = np.array([index[t.label] for t in templates])
        L = len(labels)

        def leave_one_out(assign: np.ndarray) -> np.ndarray:
            pred = np.empty(n, dtype=int)
            for i in range(n):
                best = np.full(L, np.inf)
                np.minimum.at(best, assign, D[i])
                pred[i] = int(np.argmin(best))
            return pred

        pred = leave_one_out(truth)
        observed = float((pred == truth).mean())
        confusion = np.zeros((L, L), dtype=int)
        for p, a in zip(pred, truth):
            confusion[a, p] += 1

        rng = random.Random(seed)
        null = []
        for _ in range(permutations):
            shuffled = truth.copy()
            rng.shuffle(shuffled)
            null.append(float((leave_one_out(shuffled) == shuffled).mean()))
        null.sort()
        at_least = sum(1 for a in null if a >= observed)
        per_label = {
            l: confusion[k, k] / max(1, confusion[k].sum()) for l, k in index.items()
        }
        return Evaluation(
            labels=labels,
            confusion=confusion,
            accuracy=observed,
            chance=max(counts.values()) / n,
            permutation_mean=float(np.mean(null)) if null else 0.0,
            permutation_p95=null[int((len(null) - 1) * 0.95)] if null else 0.0,
            p_value=(at_least + 1) / (permutations + 1),
            permutations=permutations,
            template_count=n,
            per_label_accuracy=per_label,
        )

    def report(self) -> str:
        lines = [
            f"templates={self.template_count} labels={len(self.labels)}",
            f"leave-one-out accuracy={self.accuracy:.3f} chance={self.chance:.3f}",
            f"permutation null mean={self.permutation_mean:.3f} p95={self.permutation_p95:.3f} p={self.p_value:.4f}",
            "per-label: " + ", ".join(f"{l}={a:.2f}" for l, a in self.per_label_accuracy.items()),
        ]
        return "\n".join(lines)
