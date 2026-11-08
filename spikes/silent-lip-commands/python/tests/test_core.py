import numpy as np
import pytest

from lipspike.classifier import Evaluation, Template, TemplateClassifier, margin
from lipspike.dtw import dtw_distance
from lipspike.features import segment_features, trim
from lipspike.geometry import frame_from_contours, polygon_area


def test_polygon_area_unit_square():
    assert polygon_area([(0, 0), (1, 0), (1, 1), (0, 1)]) == pytest.approx(1.0)


def test_geometry_is_scale_invariant():
    outer = [(0, 0), (4, -1), (8, 0), (4, 2)]
    inner = [(2, 0), (4, -0.5), (6, 0), (4, 1)]
    a = frame_from_contours(outer, inner, (0, -5), (8, -5), (4, 6))
    scale = lambda pts: [(x * 3, y * 3) for x, y in pts]
    b = frame_from_contours(scale(outer), scale(inner), (0, -15), (24, -15), (12, 18))
    assert a == pytest.approx(b)


def test_dtw_identity_and_warping():
    a = np.array([[0.0], [1.0], [2.0], [1.0], [0.0]])
    assert dtw_distance(a, a) == 0.0
    slow = np.repeat(a, 2, axis=0)
    other = np.array([[2.0], [1.0], [0.0], [1.0], [2.0]])
    assert dtw_distance(a, slow) < dtw_distance(a, other)


def test_trim_removes_quiet_edges():
    quiet = np.zeros((10, 6))
    burst = np.cumsum(np.random.default_rng(0).normal(size=(10, 6)), axis=0)
    frames = np.concatenate([quiet, burst, burst[-1] + np.zeros((10, 6))])
    t = trim(frames)
    assert 10 <= len(t) < len(frames)


def test_segment_features_shape():
    f = np.random.default_rng(1).normal(size=(20, 6))
    assert segment_features(f).shape == (len(trim(f)), 12)
    assert segment_features(f, use_velocity=False).shape[1] == 6


def _synthetic_word(rng, kind: str, n: int = 20) -> np.ndarray:
    t = np.linspace(0, 1, n)
    base = np.full((n, 6), 0.5)
    if kind == "open":  # aperture rises then falls
        base[:, 2] += 0.3 * np.sin(np.pi * t)
        base[:, 4] += 0.2 * np.sin(np.pi * t)
    elif kind == "wide":  # width pulse
        base[:, 0] += 0.3 * np.sin(np.pi * t)
    elif kind == "jaw":
        base[:, 5] += 0.2 * np.sin(np.pi * t) ** 2
    return base + rng.normal(scale=0.02, size=base.shape)


def test_classifier_and_evaluation_on_synthetic_words():
    rng = np.random.default_rng(42)
    templates = [
        Template(k, _synthetic_word(rng, k, n=rng.integers(14, 26)))
        for k in ("open", "wide", "jaw")
        for _ in range(8)
    ]
    clf = TemplateClassifier(templates)
    pred = clf.predict(_synthetic_word(rng, "wide"), max_distance=10.0, min_confidence=0.0)
    assert pred.best == "wide"
    ev = Evaluation.run(templates, permutations=100, seed=0)
    assert ev.accuracy > 0.9
    assert ev.p_value < 0.05
    assert ev.permutation_mean < 0.6


def test_evaluation_rejects_pure_noise():
    rng = np.random.default_rng(7)
    templates = [Template(k, rng.normal(size=(20, 6))) for k in ("a", "b") for _ in range(10)]
    ev = Evaluation.run(templates, permutations=100, seed=0)
    assert ev.p_value > 0.05 or ev.accuracy < 0.75


def test_margin():
    assert margin([1.0, 2.0]) == pytest.approx(0.5)
    assert margin([1.0]) == 0.0


def test_segmenter_auto_detects_a_burst():
    from lipspike.segmenter import Segmenter

    got = []
    seg = Segmenter(got.append)
    seg.calibrate()
    rng = np.random.default_rng(3)
    t = 0.0
    rest = np.full(6, 0.5)
    # 3 s of near-still mouth at 30 fps for calibration, then a 0.6 s burst, then quiet.
    for _ in range(90):
        seg.ingest(t, list(rest + rng.normal(scale=1e-4, size=6)))
        t += 1 / 30
    assert not seg.is_calibrating and seg.noise_floor is not None
    seg.auto_enabled = True
    for k in range(18):
        seg.ingest(t, list(rest + 0.2 * np.sin(np.pi * k / 18)))
        t += 1 / 30
    for _ in range(40):
        seg.ingest(t, list(rest + rng.normal(scale=1e-4, size=6)))
        t += 1 / 30
    assert len(got) == 1
    assert 15 <= len(got[0]) <= 60
