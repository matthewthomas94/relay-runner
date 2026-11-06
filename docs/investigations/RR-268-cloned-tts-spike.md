# RR-268 — Custom cloned TTS voice spike

> **Removed:** the custom voices feature this investigation informed was removed from Relay Runner by RR-462 (2026-11-06). Kept as history; referenced code and scripts no longer exist.

Research update: the [2026-09-08 inline KokoClone rerun](RR-268-kokoclone-addendum.md) supersedes this report's candidate shortlist. Measurements below remain historical and were not rerun.

Date: 2026-09-07

Source baseline: `3788552` (`v0.4.51`)

Scope: research and disposable local benchmarks only; no production integration,
model bundling, installer change, Settings control, or default-voice change

## Decision

**Further evidence is required. Do not integrate a cloned-voice engine yet.**

The original request did not confirm an engine. Coqui XTTS-v2 is the likely
meaning of “cloned TTS,” but that interpretation remains unconfirmed. The
maintained runtime is now the Idiap fork published as `coqui-tts` 0.27.5, while
the XTTS-v2 checkpoint remains model version 2.0.3. Its code is MPL-2.0, but
the checkpoint is under Coqui Public Model License 1.0.0, which permits only
non-commercial use of the model and its outputs. It is therefore not a safe
default for a distributable Relay feature. The model also requires accepting
terms before download; this spike did not accept them on the user's behalf.

Two permissively licensed, local-first Apple Silicon paths were exercised with
the same prompts and a synthetic reference:

1. `mlx-audio` 0.5.1 with
   `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit` is the conditional technical
   leader. The runtime is MIT, the converted model card identifies Apache-2.0,
   cached offline generation worked, and its warm real-time factors were
   0.78–0.90. Time to the only returned audio chunk was still 2.78–7.81 seconds,
   with 5.55–6.43 GB peak MLX allocation.
2. `mlx-audio` 0.5.1 with
   `mlx-community/chatterbox-multilingual-v3` also worked offline and carries
   MIT metadata, but it needed a 2.71 GB checkpoint plus a 495 MB tokenizer,
   returned first audio after 6.39–8.31 seconds on a cached run, and was slower
   than real time for all three prompts.

Neither candidate is ready for a production recommendation. No intended engine
was confirmed, no consented human reference recording was available, and no
human listened to or rated the generated audio. The benchmark establishes
local execution and resource bounds, not acceptable likeness or quality.

No implementation tickets were created.

## Upstream identity, maintenance, and licensing

| Candidate | Exact project reviewed | Runtime / model terms | Reference contract | Disposition |
| --- | --- | --- | --- | --- |
| Coqui XTTS-v2 | Maintained [`idiap/coqui-ai-TTS`](https://github.com/idiap/coqui-ai-TTS), PyPI [`coqui-tts` 0.27.5](https://pypi.org/project/coqui-tts/); checkpoint described as XTTS-v2.0.3 | Runtime MPL-2.0. [`XTTS-v2` CPML 1.0.0](https://huggingface.co/coqui/XTTS-v2/raw/main/LICENSE.txt) allows only non-commercial use of the model and outputs. | Model card says about 6 seconds; audio plus language, with optional cached speaker identity. Download requires terms acceptance. | Reject as Relay's default/distributed engine. It may be evaluated only after the user confirms XTTS was intended and explicitly accepts the applicable terms for non-commercial evaluation. |
| Qwen3-TTS Base via MLX | [`Blaizzy/mlx-audio` v0.5.1](https://github.com/Blaizzy/mlx-audio/releases/tag/v0.5.1); model revision `50f45ef0047cde7e84c2ef04326acb8ada2436a7` | [`mlx-audio` is MIT](https://github.com/Blaizzy/mlx-audio/blob/main/LICENSE); [the 8-bit model card](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit) and [official base checkpoint](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base) identify Apache-2.0. | [Official Qwen documentation](https://github.com/QwenLM/Qwen3-TTS) describes a three-second rapid clone. Best ICL mode requires reference audio plus its exact transcript; x-vector-only can omit the transcript with reduced likeness. | Conditional leader for a second benchmark, not an integration decision. Pin and audit the conversion provenance before distribution. |
| Chatterbox Multilingual v3 via MLX | `mlx-audio` 0.5.1; model revision `03565773edd72e949572557597af8063bb49a18a`; S3 tokenizer revision `e0c9886f0e1c35ae85b1f27277416fb19fc72bec` | [`mlx-community/chatterbox-multilingual-v3`](https://huggingface.co/mlx-community/chatterbox-multilingual-v3) and the [official Resemble model card](https://huggingface.co/ResembleAI/chatterbox) identify MIT. Generated audio is perceptually watermarked. | MLX guidance recommends 5–15 seconds of clean WAV speech; the model does not require a transcript. | Viable comparison path, but reject as the first Relay candidate on measured latency and footprint. |

The original `coqui-ai/TTS` repository's last named release is 0.22.0 from
2023. The current maintained package is the Idiap fork. Its documentation says
it is tested on Ubuntu and “should” work on Mac; that is weaker than a supported
Apple Silicon deployment claim. This distinction is why “Coqui,” “TTS,” and
“XTTS-v2” should not be treated as interchangeable product identities.

The MLX candidates are community conversions. A production download manifest
would need the upstream model identity, conversion tool/version, immutable Hub
revision, declared license, expected file list and sizes, and SHA-256 values.
Model-card metadata alone is not a complete provenance audit.

## Existing Relay TTS path

| Boundary | Current behavior | Consequence for cloning |
| --- | --- | --- |
| Defaults and persistence | `TtsConfig` in `Sources/relay-runner/Config/Config.swift` defaults to `engine = "kokoro"`, `voice = "bm_george"`, rate 1.3, and queue mode. `ConfigManager` reads/writes `[tts]` in `~/Library/Application Support/relay-runner/config.toml`. Python `services/config.py` mirrors those defaults and migrates `say`/`piper` values to Kokoro. | `engine` already exists in persisted schema, but it is not an implemented engine switch. Old configs must continue to resolve to Kokoro/George. |
| Settings | `TTSSettingsTab` exposes a fixed Kokoro voice list, preview, playback mode, rate, chime, and notification. Preview invokes `ProcessManager.previewVoice`, which launches `services/preview_voice.py`; that script is Kokoro-specific. | Do not expose a clone choice until an asset is valid and its engine is installed. Preview must use the same selected synthesizer/fallback contract as session speech. |
| Hot reload | `AppState.saveConfig` atomically saves config and sends `reload` to the bridge whenever a running session exists. The bridge calls `SpeechCoordinator.reload_config`, which delegates to `TTSWorker.reload_config`. | Engine and asset changes can use the existing reload boundary, but an engine swap must be transactional: keep the old playable engine until the new one reports ready. |
| Speech arbitration | In relay mode `voice_bridge.py` wraps the executor in `SpeechCoordinator`. The coordinator owns command freshness, provider-neutral acceptance, exact-once delivery, queue/auto-play, cancellation, replay lineage, and privacy-safe event logging. | Cloning belongs below this boundary. Codex and Claude must submit the same `SpeechIntent`; neither provider should know which synthesizer renders it. |
| Synthesis | One long-lived `TTSWorker` loads Kokoro ONNX, sentence-splits text, speculates the first sentence, renders temporary 16-bit mono WAV files, and pipelines later chunks. It ignores the persisted `engine` value and always uses Kokoro. | Extract a narrow synthesizer adapter or local worker protocol. Do not fork coordinator/replay logic per engine. |
| Playback and UI | `TTSWorker` emits waiting/preparing/speaking/failed/idle state, then launches `afplay`; rate is applied with `afplay -r`. The latest completed WAV is retained for replay and temporary WAVs are removed as they are superseded. | A cloned engine should return a WAV plus sample rate to this unchanged playback/lifecycle path. Synthesis failure must not leave a playable preview or stale cloned voice selected. |
| Setup and offline readiness | `scripts/relay-bridge --venv-only` creates a user-writable venv, installs `services/requirements.txt`, and downloads Kokoro's ONNX and voices to `~/.local/share/kokoro`. `VenvInstaller.alreadyInstalled` requires both files. The app bundle contains read-only Python source, requirements, notices, and scripts. | A multi-gigabyte clone runtime must be an explicit optional download, not part of baseline onboarding. Readiness needs an engine-specific manifest, not another unconditional model check. |
| Packaging and updates | `build-dmg.sh` signs the Swift app and copies services into `Contents/SharedSupport`; Python wheels and speech models remain in user storage. Sparkle stops services before replacing the app. The existing venv persists, and setup currently treats successful imports as dependency readiness rather than reconciling every package version change. | Do not add MLX dependencies to the current voice venv. `mlx-audio` requires `huggingface_hub>=1.0` while Relay currently pins `<1`; it also adds large, fast-moving dependencies. An isolated optional runtime needs its own version marker, migration, rollback, and garbage collection. |

The current Kokoro model files are 353,746,785 bytes combined and live outside
the repository. They are the safe fallback and were not modified by this
spike.

## Benchmark method

### Environment

| Item | Value |
| --- | --- |
| Hardware | Apple M4, 24 GB unified memory (`arm64`) |
| OS | macOS 26.6.2 (25G83) |
| Relay source | `3788552`, package platform minimum macOS 14 |
| Current voice runtime | Python 3.13.13, NumPy 2.5.2, ONNX Runtime 1.28.0 |
| Disposable candidate runtime | Python 3.13, `mlx-audio` 0.5.1, MLX 0.32.2, Transformers 5.16.1, Hugging Face Hub 1.30.0 |
| Candidate storage | `/tmp/rr268-benchmark-run111`; no model, output, or environment was added to Relay or its app-support directory |

The same three representative Relay responses were used for every engine:

- Short: `I found the issue and the focused tests pass.`
- Medium: `The worker updated the voice pipeline, preserved replay and cancellation behavior, and verified equivalent Codex and Claude delivery.`
- Technical: `Build 52 passed 662 Python tests and 768 Swift tests. The remaining gate is a signed-app audio check on Apple Silicon.`

The reference was a 10.1-second WAV generated locally with the current Kokoro
`bm_george` voice from a transcript written for this spike. It was synthetic,
not a human recording and not evidence that the user consented to cloning any
real voice. It allowed repeatable execution without introducing a person's
biometric voice data.

Times cover the engine call through the returned waveform. “TTFA” is time to
the first chunk yielded by the candidate API. Both candidate APIs yielded one
chunk in these calls, so it is not a streaming playback onset. CPU percentage
is process CPU time divided by wall time; MLX work also executes on Metal and
is not represented by that percentage. `mlx.get_peak_memory()` records peak
MLX allocation. Direct GPU occupancy and power counters were unavailable.

### Cached local generation

| Engine / prompt | TTFA | Total synthesis | Audio duration | Real-time factor | Process CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| Current Kokoro / short | 3.941 s | 3.941 s | 3.136 s | 1.257 | 352% |
| Current Kokoro / medium | 8.017 s | 8.017 s | 8.896 s | 0.901 | 413% |
| Current Kokoro / technical | 10.621 s | 10.621 s | 11.328 s | 0.938 | 392% |
| Qwen3 0.6B 8-bit / short | 2.783 s | 2.817 s | 3.120 s | 0.903 | 106% |
| Qwen3 0.6B 8-bit / medium | 6.785 s | 6.989 s | 8.960 s | 0.780 | 105% |
| Qwen3 0.6B 8-bit / technical | 7.814 s | 8.022 s | 10.160 s | 0.790 | 107% |
| Chatterbox v3 / short | 6.393 s | 8.350 s | 3.220 s | 2.593 | 66% |
| Chatterbox v3 / medium | 7.505 s | 11.133 s | 8.700 s | 1.280 | 42% |
| Chatterbox v3 / technical | 8.312 s | 12.396 s | 9.340 s | 1.327 | 41% |

Kokoro returns a complete WAV, so its synthesis time is shown as TTFA. Relay's
sentence speculation can hide part of that cost when the user waits before
pressing play; the table deliberately measures engine work, not perceived UI
latency.

### Load, memory, and disk

| Engine | Model bytes | Cached load | Process peak RSS | Peak MLX allocation |
| --- | ---: | ---: | ---: | ---: |
| Current Kokoro ONNX | 353,746,785 (337 MiB) | 1.162 s | 809,615,360 bytes | Not applicable; ONNX CPU path |
| Qwen3 0.6B Base 8-bit | 1,991,296,593 (1.85 GiB) | 4.319 s | 2,183,004,160 bytes | 6,431,540,525 bytes |
| Chatterbox v3 + S3TokenizerV2 | 3,207,973,708 (2.99 GiB) | 2.929 s | up to 4,004,675,584 bytes | 4,762,592,091 bytes |

The disposable Python package cache was an additional 840 MB shared by the two
MLX candidates. The first Qwen download/load took 64.929 seconds and the first
Chatterbox download/load took 68.928 seconds on this connection. Those are not
repeatable product download benchmarks. They demonstrate why the UI must state
the exact download size and keep installation separate from first playback.

First-use compilation also matters. Before the MLX cache was warm, Qwen's short
prompt did not yield until 18.560 seconds; Chatterbox's first short generation
yielded at 28.004 seconds and completed at 33.552 seconds. A production design
would need an explicit prepare/warm state rather than letting the first spoken
reply absorb compilation.

### Offline and quality evidence

With `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`, and `uv --offline`, both
cached candidates loaded and generated the short prompt successfully. Qwen
loaded/generated in 3.749/2.890 seconds; Chatterbox in 2.137/6.969 seconds.
This establishes offline operation after dependencies and immutable model files
are present. It does not establish that their current download code is pinned,
verified, resumable, or safe enough for Relay.

No subjective voice-quality or speaker-similarity score is reported. The
synthetic reference is useful for execution timing but cannot answer whether a
clone resembles the user's intended voice, whether the pronunciation and tone
are acceptable, or whether a human prefers it to George. No ASR intelligibility
or speaker-embedding metric was used as a substitute for that missing human
judgment.

## Recommended architecture if the evidence gate passes

Keep `SpeechCoordinator`, playback, display state, replay, stop, freshness, and
provider ownership unchanged. Put engine selection below that boundary:

```text
Codex or Claude result
        |
        v
provider-neutral SpeechIntent / SpeechCoordinator
        |
        v
Synthesizer adapter ---- failure/timeout ----> Kokoro bm_george
   | current: Kokoro ONNX
   | optional: isolated MLX clone worker
        |
        v
temporary WAV -> existing afplay + UI/replay lifecycle
```

The optional worker should be a local subprocess with a small, versioned
request/response protocol: engine manifest, asset ID, text, language, and
response WAV metadata. It should never receive provider identity, repository
path, ticket data, prompts, or transcripts beyond the final text already
authorized for speech. Crash isolation and a separate environment avoid
dependency conflicts with the stable Kokoro worker.

On selecting a valid cloned voice, start and warm the optional worker before
committing the selection. Retain Kokoro throughout preparation. On missing or
corrupt assets, unsupported hardware, load failure, synthesis timeout, empty
audio, worker exit, or model-version mismatch:

1. cancel any partial cloned output;
2. render the same accepted `SpeechIntent` once with `bm_george`/Kokoro;
3. keep exact command and utterance lineage for replay and deduplication;
4. show a bounded “custom voice unavailable; using George” state; and
5. log engine/version/timing/error class without raw text, transcript, or audio.

The selection should be one global TTS setting shared by Codex and Claude.
Provider changes must not alter the voice, consent record, fallback, network
behavior, or asset location. Automated parity coverage should submit identical
Codex- and Claude-originated intents through the same adapter and assert equal
queue, cancellation, fallback, replay, and privacy behavior.

Do not install the candidate during base onboarding or ship its model in the
DMG. An optional model manager should display engine, immutable revision,
license link, download size, target directory, network host, free-space check,
and rollback behavior before download. A successful install should atomically
publish a signed/checksummed manifest only after every file verifies. Sparkle
updates may replace adapters but must not silently replace, upload, or relabel
voice assets.

## Consent, privacy, and asset lifecycle contract

A production import must require an unchecked affirmation such as: “I own this
voice or have explicit permission from the speaker to create and use a cloned
voice.” Relay should store the affirmation text version and timestamp, while
making clear that Relay cannot verify the claim. A separate notice should warn
that generated speech can impersonate a person and must not be used deceptively
or unlawfully.

Import should use a file picker and present, before copying:

- the selected engine/model and license;
- recommended duration, format, noise, and transcript requirements;
- whether Relay will retain the source recording;
- each network destination and purpose, or “no audio leaves this Mac”; and
- the local destination and a Delete action.

Recommended layout:

```text
~/Library/Application Support/relay-runner/voices/<asset-uuid>/
  manifest.json
  source/reference.wav
  source/transcript.txt
  derived/<engine-id>/<model-revision>/profile files
```

`manifest.json` should contain a random asset ID, user-visible name,
engine/model/revision, source and derived hashes, consent-record version and
timestamp, creation/update times, and validation status. It must not contain a
repository path, ticket ID, provider transcript, or raw Relay prompt. Derived
speaker embeddings and conditioning tokens are sensitive voice assets and get
the same protection and deletion behavior as source audio.

Source recordings, transcripts, profiles, and candidate caches must never be
written into a project workspace, `.orchestrator`, Git, ticket attachments,
support bundles, analytics, or ordinary diagnostics. Temporary import and WAV
output files should be created with owner-only permissions and removed after
atomic import or playback. Relay should not upload reference or derived assets
by default. Model downloads are separate from voice-data transfer and must be
described separately.

“Delete voice” should first switch active configuration to George, stop and
invalidate cloned replay, terminate work using that asset, then remove the
source, transcript, derived profiles, previews, and per-voice caches. The UI
must disclose that filesystem deletion cannot promise erasure from user-owned
backups, snapshots, or previously exported copies. “Reset Relay” and uninstall
documentation should name the voice directory explicitly rather than leaving
biometric assets behind accidentally.

## Risks and rejected shortcuts

- **Do not treat XTTS as confirmed.** The name was inferred, not supplied.
- **Do not accept model terms automatically.** License acceptance is a user or
  product-owner decision, not a setup side effect.
- **Do not add MLX to `services/requirements.txt`.** It conflicts with Relay's
  current Hugging Face Hub range, adds hundreds of MB of packages, and makes
  the stable voice runtime depend on a fast-moving optional stack.
- **Do not download from a mutable `main` revision.** Pin immutable revisions
  and checksums, and preserve license/notice material.
- **Do not serialize voice profiles with unrestricted pickle loading.** Prefer
  a schema-validated manifest plus safe tensor/array formats.
- **Do not infer similarity from successful waveform generation.** A clean,
  consented human reference and listening protocol are still required.
- **Do not promise Intel support.** The measured MLX path is Apple Silicon
  only. Unsupported Macs must retain Kokoro without exposing a dead control.
- **Do not keep both multi-gigabyte engines resident.** A selected optional
  worker plus Kokoro fallback is enough; unload abandoned candidate models.
- **Do not reuse Chatterbox output without documenting its watermark.** The
  official model card says every generated file includes the PerTh watermark.

## Evidence needed to resume

1. The user/product owner confirms the intended engine or confirms that Relay
   may select among XTTS, Qwen3-TTS, Chatterbox, or another named candidate.
2. A clean 5–15 second reference clip and exact transcript are provided with
   explicit permission to use them for local cloning tests. If the target is a
   third party, the speaker's permission must be documented by the user.
3. The product owner confirms whether commercial use and redistribution are in
   scope. XTTS-v2 must remain excluded if they are.
4. A listening protocol rates naturalness, similarity, intelligibility,
   pronunciation of Relay/tool terms, prosody, and failure artifacts for the
   same prompts, with George as a blind baseline.
5. Repeat cold/warm measurements capture at least ten runs, first playable
   audio rather than first completed array, total unified memory, Metal
   occupancy/power, thermals, and cancellation latency on the lowest supported
   Apple Silicon memory tier as well as the M4/24 GB machine.
6. An installed-app prototype proves offline restart, model corruption and
   deletion fallback, update/rollback, queue/auto-play, replay, barge-in, and
   equal Codex/Claude behavior without putting voice assets in a repository.
7. Security and licensing review approves the exact immutable runtime and model
   revisions, conversion provenance, notices, download host, and asset format.

Only after those gates support a direction should the orchestrator create
separate cold-start implementation tickets.

## Acceptance status

| Criterion | Status | Evidence |
| --- | --- | --- |
| Intended engine and exact terms confirmed | Blocked | XTTS was investigated as the likely meaning, but user intent is unconfirmed. Exact maintained XTTS runtime/model identities and licenses are recorded. |
| Existing Relay path mapped | Complete | Settings, config, reload, arbitration, synthesis, playback, setup, packaging, and update boundaries are mapped above. |
| Two local-first approaches compared | Complete for technical execution | Qwen3-TTS and Chatterbox were run with identical prompts/reference; XTTS was rejected on license/terms before download. |
| On-device measurements | Partial | Timing, RTF, process CPU, RSS, MLX allocation, size, and offline operation are recorded. Direct GPU occupancy/power, lower-tier hardware, and human quality/similarity are missing. |
| Consent/privacy/lifecycle contract | Complete as a proposed contract | Explicit consent, import, storage, network, deletion, and repository exclusion are defined. It has not been user-approved or implemented. |
| Licensing/provenance/packaging risks | Complete for spike | Material risks and required production audit are recorded; this is not legal approval. |
| Recommended architecture and provider parity | Complete as a conditional design | Adapter boundary, fallback, lifecycle, errors, packaging, and equal Codex/Claude behavior are specified. |
| No production integration | Complete | Only this investigation document was added. |
| Final decision | Complete | Further evidence; no implementation tickets created. |
