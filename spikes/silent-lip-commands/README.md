# Spike: silent lip commands from the Mac camera

**Question.** Can lip geometry from an ordinary RGB camera, with nothing trained
on anyone else's data, separate a small vocabulary of silently mouthed command
words well enough to drive Relay Runner controls (stop, cancel, play, replay…)?

**Approach (Option A from the research).** A camera version of
[joeblau/subvox](https://github.com/joeblau/subvox): per-frame lip geometry
instead of AirPods motion, the same nearest-neighbour DTW template classifier,
and the same honesty check (leave-one-out accuracy against a label-permutation
null). No pretrained lip-reading weights, so none of the LRS3 / LRW
non-commercial licence problems that block every open-vocabulary option.

Findings are in [REPORT.md](REPORT.md).

## Layout

```
python/lipspike/          the pipeline (runs anywhere, numpy only)
  geometry.py             6 channels: width, outer_h, inner_h, outer_area, inner_area, jaw
  features.py             trim quiet edges, mean-centre, velocities, per-channel scaling
  dtw.py                  Sakoe-Chiba DTW (port of subvox)
  classifier.py           1-NN template classifier + leave-one-out / permutation Evaluation
  segmenter.py            auto word segmentation from articulation energy (port of subvox)
  cli.py                  lipspike record | evaluate | decode | export
  landmarks_mediapipe.py  MediaPipe Face Landmarker -> geometry (video files, Linux validation)
  mediapipe_source.py     JSONL frame source from a webcam or video via MediaPipe
python/experiments/       GRID corpus extraction + experiment runner used for REPORT.md
python/tests/             unit tests (pytest)
mac/                      LipCapture: SwiftPM tool, AVFoundation + Vision -> JSONL geometry
```

Both landmark sources emit the same 6 numbers per frame, normalised by
inter-ocular distance, so templates and evaluation never see raw landmarks.

## Run it on your Mac

```sh
cd spikes/silent-lip-commands/python
python3 -m venv .venv && . .venv/bin/activate
pip install -e ".[test]"
pytest -q

# Vision-based capture (first run triggers the camera permission prompt for Terminal)
swift run -c release --package-path ../mac LipCapture --list-devices

# Record 10 silent takes of each command word, ~1.5 s each
lipspike record --label stop   --takes 10
lipspike record --label cancel --takes 10
lipspike record --label play   --takes 10
lipspike record --label replay --takes 10

# Is the signal real? Leave-one-out accuracy vs 500 shuffled-label runs.
lipspike evaluate

# Live decode with auto segmentation (hold still 2 s to calibrate, then mouth words)
lipspike decode
```

`--source` overrides the capture command; e.g. to use MediaPipe instead of Vision:

```sh
pip install -e ".[video]"
curl -LO https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
lipspike --source "python -m lipspike.mediapipe_source --model face_landmarker.task" record --label stop
```

The dataset is a plain JSON file at `~/.lipspike/dataset.json` (`LIPSPIKE_DATASET` to move it).

## Reproduce the GRID experiment

```sh
# GRID corpus, speaker s1 low-res video + align files (research licence, not redistributed)
python experiments/grid_extract.py data/grid/s1 face_landmarker.task s1_geometry.npz --limit 500
python experiments/grid_experiment.py s1_geometry.npz data/grid/s1/align --vocab colours --takes 20
```
