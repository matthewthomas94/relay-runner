# Spike report: silent lip commands from the Mac camera

Date: 2026-11-03. Branch `spike/silent-lip-commands`, PR #51.

## Question

Can lip geometry from an ordinary RGB camera, with templates recorded only from
the user and no pretrained lip-reading model, separate a small vocabulary of
mouthed command words well enough to drive Relay Runner controls?

## What was built

- A 6-channel per-frame lip geometry (mouth width, outer and inner lip height,
  outer and inner lip area, eye-to-chin distance), each normalised by the
  inter-ocular distance so camera distance and resolution drop out.
- Segment features: trim quiet edges, mean-centre per channel (removes the
  resting mouth shape), append per-frame velocities, z-scale per channel.
- 1-nearest-neighbour DTW classifier over user templates, with a distance and
  margin gate, plus an energy-based auto segmenter. Both are direct ports of
  joeblau/subvox with lips in place of AirPods motion.
- The subvox honesty check: leave-one-out accuracy against a 300 to 500 shuffle
  label-permutation null.
- Two implementations that agree to six decimals on the same data: Swift
  (`mac/LipCapture`, AVFoundation + Vision, the product path) and Python
  (`python/lipspike`, the validation harness used below).

## Evidence: GRID corpus, word segments, per-speaker templates

Setup: GRID speakers s1 and s2, first 500 low-resolution clips each (360x288,
25 fps), MediaPipe Face Landmarker for geometry, word boundaries from the
corpus align files with a 2-frame pad. Each word occurrence is one "take";
20 takes per word are drawn at random. Words are short: 7 to 24 frames, median
10 to 13, which is 0.4 to 0.5 s. This is voiced speech, read quickly, in a
studio. It is a harder segmentation case than a deliberately mouthed command
and an easier imaging case than a laptop webcam.

| Vocabulary | Labels | Speaker | LOO accuracy | Chance | Permutation null mean / p95 | p |
|---|---|---|---|---|---|---|
| commands (bin, lay, place)* | 3 | s1 | 1.000 | 0.385 | 0.341 / 0.481 | 0.003 |
| commands | 3 | s2 | 0.961 | 0.392 | 0.343 / 0.471 | 0.003 |
| colours (blue, green, red, white) | 4 | s1 | 0.850 | 0.250 | 0.238 / 0.325 | 0.003 |
| colours | 4 | s2 | 0.975 | 0.250 | 0.240 / 0.350 | 0.003 |
| adverbs (again, now, please, soon) | 4 | s1 | 0.938 | 0.250 | 0.239 / 0.338 | 0.003 |
| adverbs | 4 | s2 | 0.950 | 0.250 | 0.244 / 0.338 | 0.003 |
| digits (zero to nine) | 10 | s1 | 0.730 | 0.100 | 0.095 / 0.135 | 0.003 |
| digits | 10 | s2 | 0.805 | 0.100 | 0.095 / 0.140 | 0.003 |
| all of the above | 21 | s1 | 0.755 | 0.049 | 0.045 / 0.066 | 0.003 |
| all of the above | 21 | s2 | 0.800 | 0.049 | 0.045 / 0.068 | 0.003 |

\* "set" clips sort after the first 500 files, so only three command words were available.

Ablations on the colours vocabulary:

| Variant | s1 | s2 |
|---|---|---|
| 20 takes per word, with velocity channels (baseline) | 0.850 | 0.975 |
| 20 takes, geometry only, no velocity | 0.838 | 0.912 |
| 10 takes per word | 0.725 | 1.000 |
| 5 takes per word | 0.700 | 0.950 |

Cross-speaker, templates from s1 applied to s2 with no adaptation:

| Vocabulary | Within-speaker (s1) | Cross-speaker (s1 templates, s2 takes) |
|---|---|---|
| colours | 0.850 | 0.625 |
| digits | 0.730 | 0.375 |

Confusions follow visemes, as expected: eight/nine/six, zero/six, red/white,
one/three, two/soon. Words with distinct lip rounding or jaw motion (blue,
now, please, place, three) are near perfect.

## Conclusions

1. **The signal is real.** On every vocabulary and both speakers the
   permutation p-value is at the floor of the test, and accuracy is 3 to 16
   times the shuffled-label null. A 4-word command set reaches 85 to 98% with
   20 takes per word, from 0.4 s voiced words cut automatically from fluent
   sentences, on 360x288 video.
2. **It is per-user by construction.** Cross-speaker accuracy drops to roughly
   half, which matches the research literature and Subvocal's own finding that
   per-user calibration is unavoidable. For Relay Runner that is fine: the user
   records 5 to 10 takes per command once; nobody else's data is needed.
3. **Vocabulary size is the lever.** 3 to 4 distinct words: 85 to 100%. Ten
   confusable words: 73 to 80%. Twenty-one words: 75 to 80%. A command set
   should be chosen for viseme distinctness (avoid pairs like six/nine).
4. **Velocity channels help a little; take count helps more.** 5 takes already
   beat chance comfortably; 20 takes add 5 to 15 points on the harder speaker.
5. **No licence exposure.** Nothing here uses LRS3, LRW, VoxCeleb or any
   pretrained lip model, so the approach can ship in a product. GRID was used
   only to validate the pipeline and nothing from it is kept.

## Uncertainties

- **Silent mouthing is not tested.** GRID is voiced. Silent articulation is
  smaller, so distances shrink; the within-user templates shrink with it, but
  the margin to confusable words will narrow. This is the one thing only an
  on-face run can answer.
- **Laptop webcam conditions are not tested.** Lighting, head angle and a
  30 fps built-in camera will differ from GRID's studio capture. The geometry
  normalisation handles distance and scale, not pose. A 30 fps camera gives
  more frames per word than GRID's 25, which should help.
- **Apple Vision versus MediaPipe.** The Swift tool uses Vision's lip and face
  contours; the validation used MediaPipe's 478-point mesh. Both compute the
  same 6 channels, but Vision's inner-lip contour is sparser, so inner height
  and area will be noisier. Templates and live frames come from the same
  source, so this affects margin, not correctness.
- **The Swift tool has not been run on a Mac.** The platform-independent files
  compile under Swift 6.0.3 on Linux and match Python numerically; the
  AVFoundation and Vision capture code is written against the documented API
  but unexercised.
- **False triggers.** The auto segmenter was tuned on synthetic data and
  subvox's constants. Talking, chewing or smiling will produce segments; the
  distance and margin gates reject them only if the templates are tight.

## Recommended next steps

1. Build `mac/LipCapture` on a Mac, record 10 silent takes each of `stop`,
   `cancel`, `play`, `replay`, run `LipCapture evaluate`, and compare against
   this report. That is a 15-minute test and the decisive one.
2. If it passes, pick the Relay control vocabulary for viseme distinctness and
   run `LipCapture decode` alongside normal use for an hour to measure false
   triggers.
3. Integrate as a Swift target in the app only after step 2: Vision capture
   already runs inside Relay Runner for Relay Desktop, so the permission story
   is unchanged.
4. If open dictation is still wanted later, it is a separate decision with the
   non-commercial weight licences as the blocker; this spike does not inform it.

## Reproduce

See README.md. Raw results are JSON files produced by
`python/experiments/grid_experiment.py --json`; the batch used here ran the
commands in the tables above with `--perms 300 --seed 0`.
