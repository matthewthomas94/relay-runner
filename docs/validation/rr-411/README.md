# RR-411 — Phonon 2 feasibility evidence

Evaluation of Relay source `9ee1da7b5cd7dc53c538415515162815d4f0f6ab`,
FluidAudio baseline `57551cd90e0bbec342766244358bcf08afb05290` (0.13.6), and
candidate `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7` (0.17.5).
Thresholds were frozen in `2a3c414f`; the operative stratified public-v2 corpus
was frozen in `0ef653f7` before any inference. Its SHA-256 is
`7e36e6e70a379a8aa347cdc0c0bc6350ec76f8af713904ad3d8b314468029768`.
This is an isolated feasibility harness, not production integration or release
validation. Production `Package.swift`, `Package.resolved`, model settings,
installation and running sessions remain unchanged. The daemon run record for
221 selected `codex:astra`, effort `high`. Local recognition is identical for
Codex and Claude; neither provider session was launched by the evaluation.

## Recommendation: STOP before downstream activation

The candidate builds and the frozen public quality proxies meet the proposed
+1 percentage-point WER limit. This is **not feasibility acceptance**: macOS 14
launch/v2 inference and the required live/representative evidence are absent.
Long-input timestamp shifts and nonempty output for the padded short probe also
need targeted validation. Keep RR-412's required-input gate unresolved; do not
enable defaults, install this prototype or dispatch downstream work from this
report. The implementation and all measurements available on this host are
complete; the outcome is `verification_blocked` for the external evidence below.

## Reproduce

Use a separate directory on an Apple Silicon Mac. The scripts require Python 3.9+,
FFmpeg, Xcode Swift 6.0+ (tested toolchain below), and internet access for public
fixtures, package resolution and initial model preparation. Model requests use
FluidAudio's loader; no inference service, custom downloader or extra backend is
introduced. The temporary cache is separate from the installed app's cache.

```sh
python3 scripts/experiments/phonon2/fixtures.py /tmp/rr411-evaluation/fixtures-v2
python3 scripts/experiments/phonon2/build.py baseline /tmp/rr411-evaluation/baseline
python3 scripts/experiments/phonon2/build.py candidate /tmp/rr411-evaluation/candidate
python3 scripts/experiments/phonon2/build-app.py /tmp/rr411-evaluation/app
python3 scripts/experiments/phonon2/run.py prepare /tmp/rr411-evaluation
# Wait for all builds and preparation to finish before timing:
python3 scripts/experiments/phonon2/run.py measure /tmp/rr411-evaluation
python3 scripts/experiments/phonon2/summarize.py /tmp/rr411-evaluation /tmp/rr411-evaluation/measurements.json
```

`build-app.py` requires a new destination. It exports committed source and applies
only the candidate dependency pin and the three call-site adaptations in that
copy; it never launches or installs the product. Build scripts select the SDK
bundled with `/Applications/Xcode.app` to avoid mixing the Swift 6.2.3 compiler
with the newer system CLT SDK. In this environment the unqualified SDK lookup
selected CLT macOS 27; the tested SDK is Xcode macOS 26.2. No system toolchain
selection is changed.

The fixture preparer verifies pinned preview revisions and all hashes on replay.
`python3 scripts/experiments/phonon2/test_summary.py` checks summary integrity,
weighted WER, nearest-rank p95 and frozen boundary/intent coverage.
If the preview has moved, retrieve the pinned parquet revision and reproduce the
same rows/bytes; do not regenerate the manifest to fit new results. Local
`input.json` contains public reference text and paths; it stays outside Git.
The evaluator emits numeric/boolean diagnostics only, never transcript text.
Every measurement process is additionally run with a deny-network sandbox.
`run.py` checks fixture/reference hashes and model file hashes before timing;
`summarize.py` rejects missing or duplicate cases/passes. Each independent
snapshot uses fresh decoder state. No audio capture or command execution occurs.

## Runtime and integration audit

All upstream source links below are pinned to the candidate commit:
[package](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Package.swift),
[Swift 6.2 manifest](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Package@swift-6.2.swift),
[ASR manager](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift),
[transcription routing](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager%2BTranscription.swift),
[token processing](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager%2BTokenProcessing.swift).

- Both upstream releases require Swift tools 6.0; Relay's manifest can retain
  tools 5.9 and macOS 14 when built with a compatible compiler. Candidate has a
  Swift 6.2 manifest exposing the default-enabled `NemoTextProcessing` trait.
  Phonon itself requires macOS 15; the candidate rejects that selection on macOS
  14 before download. Legacy v2/v3 remain the intended macOS 14 path, subject to
  the missing actual-OS launch/inference verification.
- `AsrManager.transcribe(samples, source:)` is removed. The candidate takes
  `decoderState: inout TdtDecoderState`; callers create a fresh state with
  `TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)` for
  each bounded snapshot. This preserves baseline reset behavior without carrying
  overlapping-snapshot state. Two command call sites and the note adapter need
  this change. Model loading/progress, result fields and cleanup remain usable.
- Candidate v3-family decoding uses `JointDecisionv3`, v3 blank ID 8192, and
  v3-family silence-aligned long-input processing; baseline v3 used the legacy
  `JointDecision`. The harness downloads both through the same pinned loader
  for the baseline/candidate v3 comparison. V2 remains blank ID 1024.
- Sample arrays <=15 seconds are frame-aligned and padded internally; longer
  arrays enter `ChunkProcessor`. The harness never crops long inputs. Real
  tail probes test both sides of the boundary and 25/31 seconds.
- SentencePiece markers still become leading spaces in timing tokens. Candidate
  timing conversion subtracts one 80 ms encoder frame by default; ownership
  near note seams needs real validation even when token assembly matches.
  Token confidences come from decoder values, not a harness-generated score.
  The library's aggregate confidence has fallback constants, so the harness
  reports actual timing-token presence/count/range separately.
- The basic ASR path assembles model punctuation and text directly; it does not
  invoke NeMo inverse text normalization. Library decoding/hallucination and
  deduplication changes are still substantial; matching signatures is not
  quality evidence. No Relay silence filter was changed in this ticket.

## Loader audit and smallest remedies

Source evidence: [registry](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/ModelRegistry.swift),
[ASR loader](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift),
[hub](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/Shared/Download/ModelHub.swift),
[cache](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/Shared/Download/ModelCache.swift),
[file downloader](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/Shared/Download/FileDownloader.swift).

| Area | Demonstrated source behavior | Smallest migration remedy |
| --- | --- | --- |
| Revision | Phonon/v2/v3 use `main`; `ModelRegistry.revisionOverrides` supports immutable pins. The Hub default Phonon encoder changed to a multifunction ladder after the selected release. This evaluation pins `a812a0dfef205660787ef6234317ab79acf4d5d6`, the release-era default sparse 15 s encoder. | Set one reviewed pin before any preparation, using the existing override. Keep it stable for a recording. |
| Vocabulary | `ensureVocabularyDownloaded` constructs its fallback resolve URL without the revision override. Normal Hub model downloads include the vocabulary, avoiding that fallback in the measured preparation. | Fix the missing-vocabulary fallback upstream or at the narrow loader seam to pass the same revision; verify vocabulary hash before readiness. |
| Integrity | New downloads reject HTML, empty and wrong-size bodies. Cache validity checks layout/partial files; an existing file is skipped without a digest check. A same-size mutation is not authenticated. | Verify a small pinned SHA-256 manifest after preparation and on untrusted cache reuse; retain FluidAudio transport. The harness checks every selected file against pinned Hub LFS SHA-256 or Git blob ID and records local SHA-256. |
| Partial recovery | `.partial` staging, byte-range resume and validators, bounded retry/stall handling, atomic placement. Cancellation/transient network failure preserve partial bytes; offline failure does not purge. Permanent load failure can purge the model directory and retry once. | Retain these mechanisms; test interruption/corruption in the future product preparation path. Avoid deleting working legacy assets or treating device/compiler incompatibility as a download problem. |
| Revision cache | A matching `.fluidaudio-revision` preserves partials; a mismatched pin purges that repo directory before preparation. Old unmarked `main` caches remain accepted. | Prepare in a distinct revision-owned location before committing a migration, preserving explicit rollback assets. |
| Concurrency | Static loader methods have per-call task groups but no process-wide preparation single-flight. Two workflow managers can check/create/purge the same paths concurrently. Registry override setters are mutable, nonisolated globals. | Initialize registry once and serialize/deduplicate preparation by model/revision in one small shared coordinator; keep inference managers workflow-owned. |
| Offline reuse | Candidate exposes `ModelHub.offlineMode`; baseline has no equivalent switch. | Measured runs use OS-level network denial for both, plus candidate offline mode. Product readiness still needs a successful local fixture. |

Source audit is not a claim that forced network interruption, concurrent
preparation, disk exhaustion, or corruption recovery were physically exercised.
The remedy belongs to RR-412 after feasibility acceptance, not a new downloader.

## Binary, resources and attribution

Candidate links the Rust static `NemoTextProcessing` v0.3.1 XCFramework by
default. SwiftPM verifies archive checksum
`5fa8c10d4ec26c1bb2413125f351a7222a4c68a23b74476680fbada7e26fc6aa`.
The 6.2 trait can opt out for ASR-only clients, but this evaluation keeps defaults
so a shipping decision cannot hide linkage/resource costs. Swift <6.2 always
links it. No `PhononTDT.xcframework` or separate Fermion runtime is added.

The new `FluidAudio_FluidAudio.bundle` contains LuxTTS G2P resources even for an
ASR client. Relay's current `build-dmg.sh` copies Relay and SwiftTerm bundles,
not this bundle. RR-412/release packaging must copy the dependency bundle before
sealing/signing the app and verify lookup in the signed distribution. A static
Rust library does not require embedding a separate dynamic framework. Check
nested code, final bundle seal, notarization and preserving upgrade on the real
release candidate; this evaluation does not sign or install an app.

FluidAudio is Apache-2.0. Phonon weights are CC-BY-4.0, derived by Fermion
Research from NVIDIA Parakeet v3 and converted by FluidInference. Retain the
pinned model [LICENSE](https://huggingface.co/FluidInference/phonon-2-coreml/blob/a812a0dfef205660787ef6234317ab79acf4d5d6/LICENSE)
and [NOTICE](https://huggingface.co/FluidInference/phonon-2-coreml/blob/a812a0dfef205660787ef6234317ab79acf4d5d6/NOTICE), including training/change attribution.
For NeMo/Rust attribution, upstream's
[notice](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/ThirdPartyLicenses/NemoTextProcessing-LICENSE.md)
identifies Apache-2.0 NVIDIA NeMo grammars and MIT/Apache Rust dependencies,
but still labels the binary v0.3.0 while the package uses v0.3.1. Reconcile this
notice against v0.3.1 before release; do not silently ship the stale version
label. Add the actual shipped G2P/resource notices as well. Production notices
are deferred with production dependency integration.

## Available build evidence

The isolated candidate Relay release build passed (732.16 s, including dependency
resolution/build). The only application edits in that copy were the exact
FluidAudio pin and three fresh-decoder-state call-site adaptations. Compiler
warnings remain in existing AppState/MeetingAudioCapture Sendable closures; no
warning was suppressed. The main worktree dependency pins and sources are unchanged.

`otool -l` reports `minos 14.0`, SDK 26.2 for both evaluators and the candidate
Relay executable. This proves the declared binary deployment floor, not launch
or inference compatibility on macOS 14. `otool -L` shows no separate NeMo dynamic
framework; the candidate app still depends on its normal Sparkle framework.
The unstripped candidate app executable is 35,570,048 bytes. The dependency
resource bundle is 1,019,385 bytes (two files), in addition to existing Relay
and SwiftTerm bundles. These are build-tree sizes, not DMG/download size or a
controlled baseline-app size delta. The evaluator comparison below includes
Swift linker retention and must not be described as the app's shipping delta.

## Host, fixtures and measurement interpretation

[environment.json](environment.json) records the Apple M4 MacBookPro (10 CPU
cores, 24 GiB), macOS 27.0.1 (26A434), Xcode 26.2 / Swift 6.2.3, AC power and
Low Power Mode off. [candidate-package-resolved.json](candidate-package-resolved.json)
records all dependencies of the built app copy. [model-files.json](model-files.json)
records 70 selected files, exact model revisions and verified sizes/digests:
Phonon 357,726,026 bytes, v2 464,413,250 bytes, v3 495,913,442 bytes including
both joint variants. No alternative encoder or compute-unit override was used.
The default is CPU + Neural Engine; those settings do not constitute a hardware
trace proving that every operator ran on ANE.

The unstripped evaluator binaries are 5,377,240 bytes (baseline) and 18,242,456
bytes (candidate). The difference is 12,865,216 bytes for this harness and
default dependency features, not a measured app distribution size regression.

Fresh isolated preparation took 104.905 s for v2, 147.932 s for v3 (including
legacy joint preparation), and 375.374 s for Phonon. This includes downloading,
loading, Core ML compilation and manager initialization. App compilation
overlapped preparation, and existing system Core ML caches were not cleared;
these numbers are observed setup costs, not a controlled cold-machine ranking.
Do not change the eight-minute product timeout from this single host alone.

The operative public corpus contains 28 en-AU-labelled MINDS banking utterances
(two per intent), 20 AMI IHM utterances, eight German MINDS utterances, five
deterministically noisy command derivatives and eight length probes. Dataset
revisions, licenses, attribution links, source-row IDs and reference/audio hashes
are in the frozen manifest. Both sources provide human reference transcripts
under CC-BY-4.0 for permitted local evaluation. Audio and reference text remain
in the temporary directory. The command set is a proxy, not Relay action tests;
locale labels do not establish representative accent coverage. AMI includes
meeting/technical speech, but this small prefix does not establish names,
numbers, natural noise or overlap coverage. Synthetic noise is scored separately.

Timings below are serial, unpaced sample-array calls after all builds and
preparation finished. Each runtime/model runs one first pass plus three warm
passes, in frozen order, with network denied. `model_ms` is FluidAudio's own
`processingTime` for its recognition pipeline, not an isolated encoder kernel.
`wall_ms` surrounds the public transcription call; neither includes capture,
partial cadence, user release, queue delay, note persistence or provider delivery.
The first-pass p95 is a corpus statistic, not every case being cold. The first
inference and cached process-restart preparation are recorded separately. Small
corpora and fixed run order do not support broad device performance claims.

## Measured results

[measurements.json](measurements.json) contains transcript-free aggregate metrics
and per-boundary observations. All five offline runs completed: 1,284 attempted
calls, 1,264 successful inference results and 20 expected raw-short rejections.
Scored word-error counts stayed identical across all four passes of each case.

| Corpus | Reference words | Baseline v2 WER | Phonon WER | Delta (percentage points) | Frozen proxy WER gate |
| --- | ---: | ---: | ---: | ---: | --- |
| Commands (28) | 438 | 13.242% (58 errors) | 13.927% (61 errors) | +0.685 | Within +1 pp |
| Meeting (20) | 254 | 9.449% (24 errors) | 8.661% (22 errors) | -0.787 | Within +1 pp |
| Synthetic noise (5, separate) | 91 | 19.780% (18 errors) | 18.681% (17 errors) | -1.099 | Within +1 pp |

Candidate v2 retains all baseline v2 aggregate error counts on these fixtures.
Candidate v3 retains all baseline v3 aggregate error counts, including German:
16/142 words = 11.268% WER on eight clips. This demonstrates a functioning explicit
v3 path on this host; it is not proof for every language or macOS 14. Phonon was
not substituted for the German path.

| Runtime/model | Command warm p95 call / library (ms) | Meeting warm p95 call / library (ms) | First command call (ms) | Cached process restart (s) |
| --- | ---: | ---: | ---: | ---: |
| baseline-v2 | 299.5 / 295.7 | 264.5 / 261.5 | 308.7 | 0.567 |
| candidate-phonon2 | 337.9 / 337.3 | 265.0 / 264.5 | 254.6 | 0.423 |
| candidate-v2 | 220.3 / 219.3 | 196.2 / 195.6 | 206.5 | 0.676 |
| baseline-v3 | 381.9 / 378.4 | 311.6 / 307.0 | 293.3 | 0.557 |
| candidate-v3 | 284.3 / 283.8 | 214.2 / 213.6 | 222.7 | 0.430 |

Phonon command call p95 is 38.4 ms slower than baseline v2 on this run; meeting
call p95 differs by 0.6 ms. A model call below 500 ms does **not** pass the
release-to-final gate, and faster upgraded-v2 decoding must not be credited to
Phonon's model alone. Capture-to-first-partial, release-to-final and final-window
lag are explicitly `null`, not zero or inferred from throughput.

### Sample lengths and note-result contract

The raw 0.1-second input is explicitly rejected by all five configurations.
Its one-second padded version completes: v2/v3 produce no tokens (no confidence
values to report); Phonon produces three tokens. This cropped probe has no
full-utterance reference, so do not label that output correct or use it to approve
the existing silence/hallucination filter.

Every 6, 14.999, 15, 15.001, 25 and 31-second tail probe returns speech with
three errors against the same 15-word reference in every configuration/pass.
No dropped tail or silent input truncation was observed in these probes.
The baseline's long-input `duration` is zero despite nonzero trailing tokens;
the candidate reports the actual array duration. Do not use baseline duration
alone to detect truncation. Token timing remains materially different:

| Input seconds | Baseline v2 final token end | Candidate v2 final token end | Phonon final token end |
| ---: | ---: | ---: | ---: |
| 6 | 5.760 s | 5.680 s | 5.760 s |
| 14.999 | 14.720 s | 14.640 s | 14.720 s |
| 15 | 14.720 s | 14.640 s | 14.720 s |
| 15.001 | 14.640 s | 14.560 s | 14.720 s |
| 25 | 24.800 s | 24.720 s | 23.760 s |
| 31 | 30.800 s | 30.720 s | 30.000 s |

Candidate v2's 80 ms shift agrees with the audited emission-delay change.
Phonon's final token is 1.04 s earlier than baseline v2 on the 25-second probe
and 0.80 s earlier on the 31-second probe. This is comparative output evidence,
not an independently aligned timestamp ground truth. Long-window chunking and
model alignment cannot be declared semantically interchangeable. Validate actual
word-onset ownership at note seams before integration.

All 1,264 successful outputs reassemble to the library text using Relay's
whitespace-marked word assembly, including punctuation after whitespace cleanup;
there are zero assembly mismatches. This verifies transport/assembly preservation,
not punctuation quality against a human-edited reference. Timing-token confidence
fields are present for every emitted token; Phonon's first-pass observed range
is 0.327881–1.0 across these inputs. These are library values, not calibrated
probabilities. Empty v2/v3 padded results have null confidence ranges; no values
were fabricated.

No candidate tokens violated the checked bounds (finite/nonnegative onset, end
not before onset, end no more than 100 ms beyond input). Baseline v2 had three
meeting clips with a token end 110–150 ms beyond input, repeated in all passes
(12 flags). These checks do not establish monotonic alignment or accuracy at
ownership boundaries. Leading spaces, punctuation counts, ranges and boundary
results are retained in the numeric artifact.

## Verification and remaining external evidence

Completed locally: both exact-revision evaluator release builds; the isolated
candidate Relay release build; frozen-fixture replay; upstream digest verification
for all 70 selected model files; all five serial offline model comparisons;
summary completeness/duplicate rejection; four harness tests; Python compilation
and Git whitespace checks. No capture, provider session, signing, install or
production-default change was performed. Source audit findings are distinguished
from exercised cache reuse; interruption/concurrency/corruption recovery was not
claimed tested.

**Verification blocker:** this host runs macOS 27.0.1 and cannot supply macOS 14
launch plus real Parakeet inference. No representative Relay-critical reference
corpus or instrumented live microphone/system-audio session was available to
measure first partial, release-to-final, note final-window lag and semantic
timestamp ownership. The public proxy lacks guaranteed technical names, critical
action phrases, natural noise and synchronized overlapping sources. It cannot
satisfy those evidence gates or the separate lower-end 60-minute release soak.

**Resume condition:** provide an Apple Silicon macOS 14 environment and run the
candidate app launch/legacy v2 fixture there; provide public or explicitly
consented referenced critical-command and overlapping-source fixtures, freeze
their identities before paired evaluation, and run the existing live capture
paths with timestamps for first partial, user release/final delivery, window close
and final delivery. Validate the observed token-time shifts and short-input
behavior against reference evidence. Retain the lower-end 60-minute two-source
soak, lifecycle/recovery and signed-package checks as release gates in RR-416.
A PM must then accept a viable pinned revision and evidence explicitly before
RR-412 activation; this report grants no such acceptance.
