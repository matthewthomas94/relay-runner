# Phonon 2 transcription migration

Accepted implementation direction, 17 October 2026. Source inspected at Relay commit `38bfecdb597f4c5b8b66b5ee2429ad77bc94d0bc`. Performance targets remain subject to the feasibility gate below.

Selected model: Phonon 2, confirmed after considering Parakeet Redux. Replace the default English recognizer on supported systems in both ordinary voice sessions and Note Taker. Keep transcription local, retain the existing controls and saved-note contract, and validate the change against Relay's current Parakeet behavior before changing the default.

**Integration decision.** Upgrade the existing FluidAudio dependency and use `AsrModelVersion.phonon2`. FluidAudio added this in v0.17.5; Relay currently resolves v0.13.6. This corrects the initial draft's separate `PhononCoreML` runtime proposal. Reuse FluidAudio's recognizer, model loader, and result contract in both workflows; a second runtime, general backend abstraction, custom downloader, and helper IPC are not baseline requirements. [FluidAudio v0.17.5 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.5)

**Compatibility decision.** Keep Relay's macOS 14 deployment target. The candidate FluidAudio package still targets macOS 14, while its Phonon model requires macOS 15. On macOS 14, preserve the current working Parakeet selection and show Phonon as unavailable with the OS requirement; never download it or label another model as Phonon. New installations on 14 retain the current v2 default. On macOS 15+, Phonon becomes the default English model only after validation and successful preparation. Verify this conditional support on both OS versions before release. [Pinned package manifest](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Package.swift)

Phonon is documented for English. Preserve explicitly selected Parakeet v3 configurations for multilingual use in the first release, and keep Parakeet available for an explicit rollback. Removing every Parakeet option would additionally retire existing multilingual support and requires a separate decision. [Fermion model information](https://www.fermionresearch.com/models/phonon-2/)

**Verified upstream inputs.** FluidAudio's Phonon build uses the v3-family tokenizer, 15-second encoder window, and decoding paths. The published default model directory is approximately 360 MB. First Neural Engine preparation is reported at about a minute; measure on supported Macs rather than assuming that duration. Relay must continue generating live partials from its own bounded snapshots. [Pinned Phonon integration documentation](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Documentation/ASR/Phonon2.md)

| Input | Candidate pin / constraint |
| --- | --- |
| Swift runtime | Candidate baseline: FluidAudio `v0.17.5`, commit `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7`. Review API and behavior changes from v0.13.6, build with Relay's toolchain, then freeze the accepted revision. |
| Model bundle | `FluidInference/phonon-2-coreml`. Resolve and record an immutable model revision and selected file hashes during feasibility; do not reuse the separate Fermion runtime's model bundle or revision. |
| Download and compute placement | Default sparse encoder: about 321 MB; complete model directory about 360 MB, excluding caches. Start with the Neural Engine default. GPU use of this sparse encoder has a documented repeated load cost; alternate dense encoders are outside the initial scope. |
| Window handling | FluidAudio's 15-second encoder and existing long-input path must handle Relay's short partials, six-second note windows, and 25-second command chunks. Test the transitions rather than changing capture windows preemptively. |
| Licensing and binary dependency | FluidAudio Apache-2.0; model CC-BY-4.0. Review the upgrade's `NemoTextProcessing` binary dependency, bundled resources, attribution, and signing. The baseline does not add `PhononTDT.xcframework`. |

**Redux comparison.** FluidAudio v0.17.3 added Redux with the same existing recognition API. Its approximately 220 MB Core ML distribution retains 25 languages but also requires macOS 15. The maintainers report worse English accuracy and slower Neural Engine throughput than v3, making small downloads its main advantage for this project. Their published tests are not Relay measurements. Redux is not included in the selected implementation scope. [Pinned Redux documentation](https://github.com/FluidInference/FluidAudio/blob/a6b826ce9a09028fc685a4b32a8927ec920c3188/Documentation/ASR/ParakeetRedux.md)

Vendor throughput and benchmark results are motivation for evaluation, not a Relay performance promise. No model inference or physical capture was run while preparing this spec.

**Current integration points.** Both workflows consume `config.stt.model`, but they instantiate separate FluidAudio recognizers. Dependency resolution currently pins FluidAudio 0.13.6. Both loaders interpret any model name without `v3` as Parakeet v2, so changing the configuration string alone would silently keep the old recognizer.

| Surface | Current behavior and work required |
| --- | --- |
| [STTEngine.swift](/Users/matthewthomas/dev/relay-runner/Sources/relay-runner/STT/STTEngine.swift) | Owns command capture, gestures, status, FIFO delivery, and `AsrManager`. Update explicit model resolution and any API changes from the FluidAudio upgrade; retain both command loops. Preserve 500 ms refinement, 25-second recording chunks, one-second chunk overlap, finalization, and capture-epoch rejection. |
| [TranscriptAccumulator.swift](/Users/matthewthomas/dev/relay-runner/Sources/relay-runner/STT/TranscriptAccumulator.swift) | Joins committed command text with live refinements. Verify Phonon punctuation, repeated words, and chunk boundaries against this existing behavior. |
| [FluidAudioMeetingTranscriber.swift](/Users/matthewthomas/dev/relay-runner/Sources/relay-runner/Notes/FluidAudioMeetingTranscriber.swift) | Retain the existing note-only adapter and select `.phonon2` through the shared model resolver. Verify result timings against the upgraded library without introducing command delivery into notes. |
| [MeetingTranscriptProducer.swift](/Users/matthewthomas/dev/relay-runner/Sources/relay-runner/Notes/MeetingTranscriptProducer.swift) | Six-second windows, one-second right overlap, five-second ownership, partials starting at two seconds, and a bounded 24-window queue. Its word assembler currently expects whitespace-marked subword tokens. |
| [MeetingNoteCoordinator.swift](/Users/matthewthomas/dev/relay-runner/Sources/relay-runner/Notes/MeetingNoteCoordinator.swift) and [MeetingNoteRecoveryStore.swift](/Users/matthewthomas/dev/relay-runner/Sources/relay-runner/Notes/MeetingNoteRecoveryStore.swift) | Construct the note recognizer and preserve accepted audio, revision cursors, final tails, and idempotent saves. Recovery journals currently do not record the ASR model identity. |
| [AppState.swift](/Users/matthewthomas/dev/relay-runner/Sources/relay-runner/App/AppState.swift) | Coordinates session/note ownership and settings reload. Note factories capture the selected model, so model changes must also invalidate an idle cached coordinator without changing an active recording. |
| [Config.swift](/Users/matthewthomas/dev/relay-runner/Sources/relay-runner/Config/Config.swift), [ConfigManager.swift](/Users/matthewthomas/dev/relay-runner/Sources/relay-runner/Config/ConfigManager.swift), and [services/config.py](/Users/matthewthomas/dev/relay-runner/services/config.py) | Swift and Python both default to Parakeet v2 and migrate old Whisper identifiers. Define matching Phonon defaults, migration, and rollback behavior. |
| [STTSettingsTab.swift](/Users/matthewthomas/dev/relay-runner/Sources/relay-runner/Settings/STTSettingsTab.swift) and [SetupRuntimeReadiness.swift](/Users/matthewthomas/dev/relay-runner/Sources/relay-runner/Onboarding/SetupRuntimeReadiness.swift) | Update model choices, English labeling, download/compile/retry states, and readiness. Existing setup timeout is eight minutes; measure before changing it. |

**Model resolution.** Replace both substring-based selectors with one small shared, explicit mapping: `phonon-2` to `.phonon2`, `parakeet-tdt-v2` to `.v2`, and `parakeet-tdt-v3` to `.v3`. Reject unknown identifiers and unsupported OS/model combinations before loading. Keep the existing capture and recognition interfaces; introduce no general backend framework solely for this change.

Keep recognizer instances owned by their workflows and reuse the existing FluidAudio cache. Preserve serialized inference, off-main-thread processing, and capture-epoch/revision checks. Validate cancellation behavior against the selected FluidAudio release: even if native inference cannot stop immediately, an invalidated result must never be delivered. Review library-level changes to decoding, timestamps, normalization, and defaults as part of the dependency upgrade, including continued v2/v3 behavior.

**Model installation and readiness.** Use FluidAudio's loader and progress callbacks. Audit its revision pinning, integrity checks, partial-download recovery, and cache reuse; address a demonstrated gap without duplicating the entire downloader. Keep model data outside the signed app bundle and deduplicate preparation. Handle interrupted/corrupt downloads, unavailable network, insufficient disk, and retry without deleting working legacy assets. A cached installation must transcribe offline. Report actual download progress and named preparation phases without inventing compile percentages. Validate a prepared installation with a local fixture before publishing readiness; readiness itself must not open the microphone.

**Ordinary voice sessions.** Preserve toggle start/stop/cancel, non-toggle capture, tutorial isolation, microphone ownership, media settling, reference-audio suspension, and final command delivery. Keep bounded snapshot recognition rather than assuming native streaming. Check input lengths near every encoder boundary and command-chunk rollover, including delayed processing that grows a snapshot. Do not let a stopped session, changed device, or superseded model-load operation publish stale text or reopen capture. Maintain the existing bridge/intent protocol and test delivery with both Codex and Claude. Evaluate the current silence/hallucination filter using Phonon outputs; do not copy assumptions about Parakeet's noise behavior without evidence.

**Note Taker.** Preserve separate microphone and system-audio streams, their shared timeline and source labels, all durable checkpoints, and current bounded queues. Feed each existing producer window through the current FluidAudio adapter; do not replace the producer with whole-meeting transcription. The producer remains the owner of final segment boundaries and overlap decisions.

Retain the existing token-to-word assembly if the upgraded FluidAudio result contract matches it. Verify whitespace, punctuation, token timestamps, and confidence semantics with real Phonon outputs before changing that code. Fermion's separate Swift runtime returns a different word structure; its adapter requirements do not apply automatically to FluidAudio. Convert window-relative timing to the note timeline once and assign a word by its onset in the owned half-open interval, matching current behavior. The older capture document describes midpoint ownership and must be corrected when this change lands. Test genuine repeated speech, overlap seams, and final tails explicitly.

Record the selected backend, runtime/model revision, and relevant decoding identity in new local recovery journals. Freeze that identity for a recording and its pending tail. Maintain decoding compatibility with existing journals; a legacy journal with no model identity must retain its saved text and expose any necessary backend choice before re-transcribing its unsaved audio. Never re-transcribe completed notes automatically. A later setting change applies to the next recording, and switching to a work session waits for the existing note finalization boundary.

Keep note IDs, artifact references, global-library location, canonical save APIs, and title/summary behavior intact. Recording speech remains document content: it must not enter the voice FIFO, start a foreground provider/messenger, or create/dispatch work. Existing post-save metadata generation remains a separate lifecycle. Source labels remain microphone/system; this change does not add speaker diarization, echo cancellation, or cross-source deduplication.

**Settings and migration.** Offer Phonon 2 as the recommended English model on macOS 15+ after validation. New supported installations use it by default; macOS 14 keeps v2. For existing v2 users on supported systems, prepare Phonon successfully before a one-time switch at an idle boundary; retain the previous choice for rollback and record that migration so an explicit rollback is not immediately undone. Preserve an explicit v3 selection for multilingual use. Keep Swift and Python consistent for persisted identifiers, legacy Whisper aliases, and supported-OS defaults. Surface the actual active model if preparation fails; keep the previous model selected until the switch succeeds. Do not change an active recording's backend. Keep existing caches until a separate cleanup decision.

**Implementation tickets.** RR-411 through RR-416 follow the dependency graph below. A benchmark/prototype that writes a harness is implementation work, not a read-only spike. Dispatch requires an explicit user action.

The user authorized execution on 2026-10-18, starting RR-411 on the available Apple Silicon Mac with public fixtures. Corpus selection, provenance and freezing the proposed thresholds before measurements are worker deliverables. Unavailable macOS 14 or live validation no longer blocks starting RR-411; it remains required acceptance evidence and must be recorded as an exact verification blocker when it cannot be completed. RR-412's explicit feasibility-acceptance gate and the later release gates remain in place.

| Package | Scope and completion evidence | Dependencies | Assigned worker |
| --- | --- | --- | --- |
| A — RR-411: Dependency feasibility and baseline | Build candidate FluidAudio v0.17.5 with Relay's toolchain; identify required API changes, binary linkage, model revision/checksums, real sample-array transcription and timings. Compare commands and meeting clips against the configured v2 baseline and v3 where relevant. Produce an evidence-based proceed/stop result. | Supported test Mac and consented/public fixtures; macOS 14 environment for compatibility proof | claude:opus / medium: dependency/API drift and performance uncertainty |
| B — RR-412: Model selection and preparation | Integrate the accepted dependency revision, explicit model resolver, OS gating, existing-loader preparation, progress, readiness and stale-result handling. Prove offline reuse and failure recovery. | RR-411; explicit acceptance of feasibility is a required input | claude:opus / medium: bounded integration with loading and compatibility checks |
| C — RR-413: Ordinary workflow | Wire both command loops; retain gestures, partial/final text, tutorial ownership, cancellation and bridge delivery. Pass lifecycle/accumulation tests plus representative live dictation. | RR-412 | claude:opus / medium: bounded integration with lifecycle races |
| D — RR-414: Notes and recovery | Select Phonon in the existing note adapter; verify timing and punctuation; preserve dual-source ownership, backpressure, pause/stop tails and journal replay across upgrades. | RR-412 | claude:opus / medium: durable audio and transcript-boundary correctness |
| E — RR-415: Configuration and setup | Implement matching Swift/Python default policy and one-time migration, settings labeling, safe model changes, setup progress, retry and rollback. Keep automatic switching inactive pending release validation; manual selection supports validation. | RR-413, RR-414 | claude:opus / medium: shared configuration and lifecycle compatibility |
| F — RR-416: Release validation and activation | Verify both paths on the signed build, run the real-time meeting soak, validate platform/update metadata and notices, then enable the default switch only against passing recorded results and verify the final candidate. Public release publication is separate. | RR-415, transitively both workflows | claude:opus / medium: installed behavior and multi-surface regression evidence |

All six tickets use the user-selected `claude:opus` with `worker_effort: medium` (changed from `codex:astra` / high on 2026-10-18) and require Claude worker execution. Product validation still covers the existing downstream Codex and Claude session paths. Physical validation and consented recordings must be recorded as required inputs before dispatching work that promises them.

**Acceptance and release gates.** The following numerical limits are proposed acceptance targets, not measured results. Record the test Mac, OS, power mode, model/runtime revisions, corpus, and both cold/warm runs. Fix the baseline corpus and thresholds before comparing implementations.

| Area | Required evidence |
| --- | --- |
| Recognition quality | Paired command and meeting corpora covering Australian English, technical terms, names, numbers, short replies, quiet/noisy speech, and overlapping sources. Proposed gate: no more than +1 absolute percentage point normalized WER versus the corresponding Parakeet baseline on either corpus; review punctuation separately; zero new action-changing errors in the fixed critical-command cases. |
| Command responsiveness | Measure capture-to-first-partial and release-to-final separately from model-only time. Proposed warm p95 release-to-final at most 500 ms and no regression versus the measured baseline. Retain the current partial cadence without an accumulating recognition backlog. |
| Continuous notes | At least 60 minutes of real-time-paced two-source input on a representative lower-end supported Mac. Zero silent audio drops, missing acknowledged tails, new overlap duplicates, or unbounded queue/memory growth. Proposed steady-state p95 final recognition lag at most two seconds after a window closes. |
| Lifecycle and recovery | Cancel during loading/inference; repeated start/stop; work ↔ notes transitions; permission denial; device changes and sleep/wake; crash/relaunch; offline saves and retries; old/new journal replay. Saved segment identity, ordering, and content remain intact. |
| Setup and rollback | Fresh install, interrupted/corrupt download, warm restart, cached offline start, safe settings change, failed Phonon preparation, and explicit rollback. No repeated migration after rollback and no microphone capture merely because a model is ready. |
| Privacy and separation | No audio/transcript upload for STT; no new raw-audio or transcript diagnostics. Notes reach the note writer; commands reach the existing provider bridge. Note-only capture works without starting Codex or Claude. |
| Release package | Verify Relay still launches and transcribes with its legacy model on macOS 14, and Phonon works on macOS 15+. Keep the app OS floor consistent across `Package.swift`, `Info.plist`, documentation, and Sparkle metadata. Verify new dependency binaries/resources, bundled licenses/notices, signature and preserving upgrade. |

Extend the existing `STTRecordingAccumulationTests`, `STTCaptureOwnershipTests`, `MeetingTranscriptProducerTests`, `MeetingNoteCoordinatorTests`, `ConfigManagerTests`, `SetupRuntimeReadinessTests`, and Python configuration tests. Add focused tests for explicit model resolution, OS gating, verified cache reuse, timestamp compatibility, revision-pinned recovery, encoder boundaries, and stale inference results. Keep synthetic test results, real-model benchmarks, signed-build checks, and human-visible/audible validation as separate evidence.

Update [configuration documentation](/Users/matthewthomas/dev/relay-runner/docs/configuration.md), [architecture documentation](/Users/matthewthomas/dev/relay-runner/docs/architecture.md), [note capture documentation](/Users/matthewthomas/dev/relay-runner/docs/specs/project-note-capture.md), [third-party notices](/Users/matthewthomas/dev/relay-runner/THIRD_PARTY_NOTICES.md), and release/setup copy as part of the implementation. FluidAudio remains the transcription runtime.

This is a multi-file dependency/model migration. The main risks are dependency behavior changes, first-use preparation, timestamp semantics at note boundaries, and interrupted-note recovery. The feasibility package is the first gate; the default changes only after both workflows pass their release checks.

## RR-411 frozen evaluation protocol (public-v1)

Frozen before paired inference on 18 October 2026. The versioned manifest is
`scripts/experiments/phonon2/corpus-v1.json` (SHA-256
`7cfe3fd7521f3b25b16c00f6d51e422997ca85d5aa4c976f1dc0e383d913cb65`).
It fixes dataset revisions, row IDs, audio/reference hashes, deterministic
transformations and model revisions. These are evaluation targets, not results.

Use the first 20 MINDS-14 en-AU training rows as a small public command proxy,
the first 20 AMI IHM training rows as a meeting proxy, and the first eight
MINDS-14 de-DE rows to check preservation of v3. All are CC-BY-4.0; upstream
attribution links are in the manifest. Keep downloaded audio and reference text
outside Git. Add a separately scored 20 dB deterministic Gaussian-noise subset
of the first five commands. These subsets do not constitute a representative
release corpus: no guaranteed Relay-specific critical phrases, names, natural
noise, or synchronized overlapping sources. Do not interpret banking requests
in the public fixtures as instructions to execute anything.

Score normalized WER as total word edit distance / total reference words;
normalization is Unicode lowercase followed by splitting on non-alphanumeric
characters, identically for both models. Preserve punctuation in inference and
report its presence separately; normalization does not establish punctuation
correctness. Run one first pass and three warm passes in fixed manifest order.
Report first-process inference separately from first-use model preparation and
warm process restart. Do not describe an existing Core ML cache as a truly cold
machine. Report per-corpus warm p95 model and call wall time using nearest rank;
do not substitute them for physical capture-to-first-partial, release-to-final,
or note final-window lag.

Retain the proposed gates unchanged: at most +1 absolute percentage point WER
on each command/meeting corpus, zero new action-changing critical-command
errors, warm p95 release-to-final <=500 ms and no baseline regression, and
steady-state p95 note final-window lag <=2 s. Missing live/critical evidence
leaves these gates unresolved. The 60-minute two-source soak and macOS 14
launch/Parakeet evidence remain required and cannot be satisfied by this proxy.

Probe sample arrays at 0.1 s raw, 0.1 s padded to 1 s, 6 s, 14.999 s, 15 s,
15.001 s, 25 s and 31 s (delayed-snapshot overshoot). Longer probes place known
public speech at the end after silence so dropped tails can be detected rather
than inferred from a successful return. Check duration, tail recognition, token
onsets/ends, whitespace assembly and actual confidence presence. Use fresh
decoder state for each independent candidate snapshot to preserve the old
source-specific reset behavior. No production model/default change is authorized
by this evaluation; the PM must separately accept feasibility for RR-412.

**PM acceptance and verification waiver (2026-10-18).** The PM accepted the
RR-411 offline evidence as RR-412's feasibility input: FluidAudio v0.17.5 at
`0b1f4628`, `FluidInference/phonon-2-coreml` pinned at `a812a0df`, operative
public-v2 WER for Phonon versus v2 of +0.685 pp on commands and −0.787 pp on
meetings, and zero punctuation assembly mismatches. The same day the user waived
RR-411's remaining external verification. The following are **accepted risk, not
verified**: (1) macOS 14 launch and legacy Parakeet inference; (2) consented
critical-command and overlapping-source fixtures; (3) live partial, final and
note final-window timing. RR-411 closes as done on this basis. The waiver does
not satisfy the corresponding release gates for RR-416.

### Pre-measurement corpus amendment (public-v2)

Before any model inference, inspection found that MINDS-14 rows are intent-sorted:
the public-v1 command prefix covered only bill payments. Public-v2 replaces that
prefix with the first two en-AU examples of each of its 14 banking intents
(28 commands). Meeting and multilingual selection, model pins and every numerical
threshold above stay unchanged. Regular clips shorter than one second receive
zero padding to one second, matching Relay's note adapter and the baseline
runtime's minimum; the deliberately raw 0.1-second boundary probe stays raw.
There are 69 fixtures including the five noisy derivatives and eight boundaries.
The original v1 manifest is retained as an unused protocol record. No comparison
results informed this amendment.

The operative manifest is `scripts/experiments/phonon2/corpus-v2.json`, SHA-256
`7e36e6e70a379a8aa347cdc0c0bc6350ec76f8af713904ad3d8b314468029768`.
The stratification improves public proxy coverage; it does not fill the explicitly
missing Relay-critical phrases, natural noise or overlapping-source evidence.

The tail probe uses the first selected command fitting within six seconds,
without cropping speech; all boundary sample counts were checked before inference.

## RR-413 ordinary workflow evidence

### Changes

- `STTEngineDependencies.transcribe` is an injectable seam, so the capture loops
  can be tested without a model. Production still uses a fresh `TdtDecoderState`
  for each snapshot.
- The silence/hallucination filter moved to `TranscriptFilter`, shared by both
  loops and by the offline harness. Its decisions are unchanged.
- `cancelRecording` now bumps `captureInterruptionEpoch`, as stop, ownership
  close (switching to notes), reference-audio suspension and device
  reconfiguration already do. Every inference result is checked against the
  epoch before it is published, so a stale partial or final is dropped.
- A chunk whose snapshot the filter drops as silence still rolls over at 25 s
  with 1 s overlap. Previously it skipped the rollover.
- `TranscriptAccumulator.join` dedupes only a suffix/prefix overlap of at most
  five words, the most 1 s of shared audio can re-transcribe. Shared words take
  their trailing punctuation from the later segment. Containment-based dedupe
  was removed, because it deleted genuinely repeated speech.
- Fixed a pre-existing race. The Caps Lock loop's initial reset cleared a wheel
  request made before the loop started. It now clears only audio.

The 500 ms cadence, chunk sizes, gestures, tutorial isolation, media settle,
reference-audio suspension, defaults, Note Taker, and the FIFO/bridge contract
are unchanged.

### Tests

`STTRecordingAccumulationTests` and `STTCaptureOwnershipTests` cover:

- repeated speech across a rollover;
- boundary punctuation;
- a single final delivery per release, written once to the command FIFO;
- stale results after stop, cancel, device change, model supersede and the
  switch to notes;
- silent-chunk rollover;
- tutorial isolation.

Ten consecutive runs passed: 39 tests in about 19 s each run.

### Offline replay (`scripts/experiments/phonon2/dictation.swift`)

The replay drives RR-411's public-v2 fixtures through the production
accumulator and filter on a virtual clock. The clock models the 500 ms cadence,
25 s rollover and 1 s overlap, and advances by measured inference time. Each
model ran four passes on the pinned revisions; pass 0 is a fresh process.

| Scenario | Baseline (eec42416) | RR-413 |
|---|---|---|
| short, ~15 s, beyond 15 s, 25 s rollover, ~31 s overshoot | — | identical or equivalent to baseline |
| repeated speech (12× "I need to change my address", 72 words) | 30 words kept, 42 errors, both models | 72 words kept, 0 errors, both models |
| two rollovers, Phonon (errors per pass) | 35 / 30 / 36 / 45 | 39 / 40 / 35 / 40 |
| two rollovers, v2 (errors per pass) | 25 / 30 / 25 / 38 | 44 / 38 / 34 / 29 |
| aggregate non-repeated WER | Phonon 22.0 %, v2 21.0 % | Phonon 22.5 %, v2 22.9 % |

The two-rollover numbers swing as much between passes as between builds. Rollover
boundaries move with measured inference time, so this is noise, not a
regression.

Neither build produced a duplicated boundary from a correct join. The only
adjacent duplicate appears in the model's own live output. Both builds keep a
few gapped near-duplicates such as "it just keeps um it just keeps": the
recognizer re-hears the overlap with a filler word, and exact suffix/prefix
matching doesn't catch it. This limitation predates RR-413.

### Silence filter

Measured output from both models:

- Digital silence and Gaussian noise (RMS 0.002–0.03, 1 s and 3 s) were all
  dropped.
- Short valid utterances were kept (Phonon "Yeah.", "So, I think", "Hm."), and
  so were the command probes.

### Latency (offline proxy)

These figures time the model call at release on the replay clock. They are not
physical capture-to-text latency.

| Model | Warm p95 release-to-final | Warm max refinement |
|---|---|---|
| Parakeet v2, baseline | 427 ms | 485 ms |
| Parakeet v2, RR-413 | 422 ms | 472 ms |
| Phonon 2, baseline | 418 ms | 760 ms |
| Phonon 2, RR-413 | 396 ms | 766 ms |

Every model and build meets the warm p95 ≤ 500 ms gate. RR-413 shows no
regression against the same-run Parakeet baseline.

### Known limitations

- A Caps Lock toggle-stop within the 0.5 s hold threshold still counts as a tap.
  That is existing behavior.

### Not verified (waived 2026-10-18)

- Live dictation on hardware, in both the Caps Lock and always-on loops.
- Live delivery of the final text to Codex and Claude.

Both are accepted risk. The FIFO payload and bridge contract are unchanged, so
both providers receive the same single final line the tests assert.

## RR-416 validation evidence and activation decision

**Update (2026-10-19): activated.** The user revised the meeting gate and
accepted the result below. Both activation flags are now `true`:

- **Fresh macOS 15+ installs** set up and download only Phonon 2.
- **macOS 14** keeps Parakeet v2 as the install and default model.
- **Parakeet v2 and v3** stay selectable in Settings and download only when
  chosen.
- **Implicit v2 users on macOS 15+:**
  - With no cached v2, Phonon is adopted before the engine starts, so v2 is
    never downloaded.
  - Otherwise the one-time migration runs. After a successful switch it deletes
    the superseded v2 cache.
  - A failed migration, an explicit choice and a rollback keep every Parakeet
    cache.
- **Pending note recovery pinned to v2** re-downloads v2 on demand.

Activation evidence (M4, macOS 27, same fixtures and pinned models as below):

- Unit: full `swift test` ran 1409 tests with 4 skipped. Two UI/PTY timing
  tests failed while the Python suite loaded the CPU, then passed in isolation.
  Full Python suite: 1339 tests. Three unrelated failures: the queue-drain test
  also fails on the base commit, and the shell-lock and voice-bridge tests are
  load flakes.
- Soak: a 60-minute real-time two-source rerun matched the post-Stop WER below
  exactly, with 0 drops, duplicates or overlaps. Live final-window lag p95 was
  774 ms (gate ≤ 2 s), measured while the Python suite was running.
- Signed build: `scripts/build-dmg.sh --app-only` with
  `RELAY_SKIP_APPLICATIONS_REFRESH=1`, version 0.4.67 (71), Developer ID
  `QK9K4AQRNH`. `codesign --verify --deep --strict` passes and
  `LSMinimumSystemVersion` is 14.0. Not notarized or installed.
- The waived items below are still unverified.

The original decision follows.

**Decision: activation stays disabled.** On the production post-Stop note path,
Phonon's meeting WER is more than 1 point worse than Parakeet v2's. That fails
the frozen gate. `STTModelPolicy.phononDefaultActive` and
`PHONON_DEFAULT_ACTIVE` remain `false`, and the one-time migration stays inert.
The gate was not relaxed after measurement.

### Identity and environment

- Source: `relay/rr-416` from `61d78455` (RR-415 merge). The app and the soak
  harness were built from that tree plus this section's uncommitted notice and
  harness files. Neither affects the app binary.
- Signed local build: `scripts/build-dmg.sh --app-only` with
  `RELAY_SKIP_APPLICATIONS_REFRESH=1`, version 0.4.67 (71). It is signed with
  Developer ID team `QK9K4AQRNH` and timestamped, and
  `codesign --verify --deep --strict` passes. It is not notarized, packaged or
  installed, and the running `/Applications` copy was left untouched.
  - `relay-runner` binary SHA-256:
    `eb0e2ea28db451e1a0b22bc92d42d134ac1a5c15e702e89bacee62bcad23fce3`.
- Runtime and models: FluidAudio v0.17.5 (`0b1f4628`).
  - `phonon-2-coreml` `a812a0df`
  - `parakeet-tdt-0.6b-v2-coreml` `ee09c569`
  - `parakeet-tdt-0.6b-v3-coreml` `7dd20fe6`
  - All loaded offline from a local cache.
- Hardware: Mac16,1 (M4, 10 cores, 24 GB) on macOS 27.0.1 (26A434), AC power,
  Low Power Mode off. Xcode 26.2 (17C52), Swift 6.2.3. This is the only Mac
  available; it is not the lower-end test Mac.
- Fixtures: RR-411 public-v2 (`corpus-v2.json`), held outside Git. No private
  recordings were used.

### Evidence types

| Type | What ran |
|---|---|
| Unit | Full `swift test` at `61d78455`: 1404 tests, 4 skipped, 0 failures. Covers RR-412–RR-415 preparation, rollback, migration, journal replay and pending-tail cases. |
| Real-model offline | The 60-minute note soak and window probe below; RR-413 dictation replay latency. |
| Signed build | Local build, signature and bundle metadata only. Not launched against live audio. |
| Installed / human | None. Waived; see below. |

### 60-minute real-time two-source note soak

`scripts/experiments/phonon2/notesoak.swift` drives the production
`MeetingTranscriptProducer`, `MeetingRecordingTranscriber` and
`FluidAudioMeetingTranscriber`. The sources are copied in by
`build-notesoak.py`. Two sources run at a 100 ms wall-clock cadence; each
interleaves meeting and command clips with low-level noise gaps.

- **Record-only**, the shipping capture path: 57.6M samples accepted per
  source, 0 drops.
- **Live** Phonon windows, which measure load:
  - 1435 finals, 0 drops, maximum queue depth 2.
  - Final-window lag p50 195 ms, p95 332 ms (gate ≤ 2 s), maximum 3543 ms.
  - Tick lateness p95 87 ms. Stop drain 189 ms.
  - 0 duplicates and 0 overlaps.
- **Memory** (process footprint): 50.1 MB loaded, 49.2 MB first-half maximum,
  59.8 MB second-half maximum. Batch peak 545.7 MB during post-Stop
  transcription. Steady state shows no unbounded growth.

Post-Stop on the same spooled recording:

| Model | Finals | Mic WER | System WER | Windows with lost speech (mic / system) | Wall time |
|---|---|---|---|---|---|
| Parakeet v2 | 1345 | 19.13 % | 20.24 % | 43 / 48 | 128 s |
| Phonon 2 | 1391 | 21.99 % | 22.43 % | 27 / 21 | 158 s |
| Δ Phonon − v2 | | **+2.86 pp** | **+2.19 pp** | | |

Live Phonon WER was 21.1 % (mic) and 21.8 % (system).

The +1 pp gate fails for both sources. This differs from RR-411's per-clip
offline result (−0.787 pp on meetings). The soak instead uses the
production's 6 s context / 5 s owned windows over continuous audio.

### Lost post-Stop windows

Post-Stop produced 44 fewer segments than live.

- A 6-minute diagnostic run isolated three such windows; one is mic 105.0–110.0 s.
- In each, the final window's owned text was empty. Live mode falls back to
  the window's earlier partial; post-Stop has no partials, so that speech is
  lost.
- Single-window probe (`notesoak probe`):
  - Phonon on 105–111 s returns only "Like something that remains.", with
    every token after 5.12 s.
  - Phonon on 105–110 s, and v2 on the same 105–111 s audio, both transcribe
    the first 4 s ("take out … is there a limit? Thanks.").
- So within the 6 s context Phonon sometimes omits the leading speech entirely.
  This is model output, not the producer's onset filtering. The post-Stop path
  turns those omissions into missing note content; Parakeet shows the same
  mechanism more often. The cost is already counted in the WER above.

### Other gates

| Gate | Result |
|---|---|
| Command WER (RR-411 public-v2) | +0.685 pp: passes |
| Warm command p95 release-to-final (RR-413 replay) | Phonon 396 ms vs v2 422 ms: passes |
| Note final-window lag p95 (this soak, M4) | 332 ms: passes on this Mac only |
| OS floor | `LSMinimumSystemVersion` 14.0 = `Package.swift` `.macOS(.v14)`; Sparkle `generate_appcast` reads it from the archive. No update metadata was generated or pushed. |
| Attribution | Added the `NemoTextProcessing.xcframework` binary (text-processing-rs v0.3.1, Apache 2.0), new with FluidAudio v0.17.5, to `THIRD_PARTY_NOTICES.md`. `build-dmg.sh` copies licences only from `.build/checkouts`, so this artifact had none. |

### Not verified (waived 2026-10-18)

These remain accepted risk:

- macOS 14 launch and Parakeet inference.
- The 60-minute soak on a lower-end Mac.
- Live capture: permissions, device changes, sleep/wake and crash/relaunch.
- Human UAT.
- Live Codex and Claude delivery.
- Notarization and a preserving install.

### Resume

To activate, one of the following must happen first:

- A follow-up change removes the post-Stop loss, for example by re-decoding an
  empty final window over its owned range only. The soak must then show Phonon
  within +1 pp of v2 on both sources.
- The user explicitly revises the meeting gate.

Then set both activation flags and update the two tests asserting the inactive
default. Rerun `swift test`, the soak and the signed build.
