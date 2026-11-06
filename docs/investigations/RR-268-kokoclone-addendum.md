# RR-268 — Inline rerun including KokoClone

> **Removed:** the custom voices feature this investigation informed was removed from Relay Runner by RR-462 (2026-11-06). Kept as history; referenced code and scripts no longer exist.

Date: 2026-09-08. Relay source baseline: `f2f684c`.

## Outcome

**Further evidence; shortlist KokoClone alongside Qwen3-TTS/MLX. Do not integrate either yet.**

The requested “koroclone” is interpreted as [Ashish-Patnaik/KokoClone](https://github.com/Ashish-Patnaik/kokoclone), not an RVC-based fork. This corrects the original candidate-coverage gap. Qwen remains the prior measured leader, not a demonstrated winner against KokoClone. KokoClone deserves the next comparative evaluation because it offers a different approach that may reuse Relay's existing synthesis output. That potential is an architectural inference, not a speed or quality result.

This is a foreground inline research rerun, not a daemon worker run. Public source and metadata were read; no dependencies, weights, audio, prototypes or app changes were made. Historical run 112 and the original benchmark report remain intact. This addendum supersedes their candidate shortlist, not their measurements.

## Verified identities and provenance

| Component | Identity observed | Evidence boundary |
| --- | --- | --- |
| KokoClone | Package 0.1.0; commit `dd6bd3acd3010dc223978839761db74957195f98`, dated 2026-04-19 | GitHub commit API and pinned source; not an independently validated release |
| Kanade runtime | Package 0.1.0; commit `961f20bf892c59f391d0b6c5f7b88e70ed919b99`, dated 2026-06-19 | Upstream runtime metadata; KokoClone's dependency does not pin this revision |
| Default conversion checkpoint | `frothywater/kanade-12.5hz`, revision `bfc4a8a753ea71394cf98e752ca68c7fbc847f0d` | Hub API lists config.yaml and model.safetensors; weights were not downloaded or hashed locally |

The [KokoClone license](https://github.com/Ashish-Patnaik/kokoclone/blob/dd6bd3acd3010dc223978839761db74957195f98/LICENSE) is Apache-2.0. The [Kanade model card](https://huggingface.co/frothywater/kanade-12.5hz) labels its weights MIT, describes a 120M-parameter LibriTTS/WavLM-base+ model with a 24 kHz Vocos vocoder, and warns that fallback from FlashAttention to PyTorch SDPA does not guarantee paper-level quality. This matters for Mac evaluation and multilingual claims: the card lists English, while KokoClone advertises multiple synthesis languages.

Kanade's GitHub license endpoint returned 404 and the inspected root listing had no LICENSE file. **The runtime code's license was not established by this review; do not infer it from the model card.** Obtain an explicit upstream code grant before vendoring or distribution. The [Vocos model card](https://huggingface.co/charactr/vocos-mel-24khz) carries MIT metadata. Full transitive notices, WavLM provenance, converted Kokoro assets and safe loader behavior still require audit. These observations are not legal clearance.

## What KokoClone actually adds

The [core implementation](https://github.com/Ashish-Patnaik/kokoclone/blob/dd6bd3acd3010dc223978839761db74957195f98/core/cloner.py) synthesizes ordinary Kokoro audio, then applies Kanade conversion using a reference recording and a vocoder. It is not a generated Kokoro voice-pack file. Kanade/vocoder device selection is CUDA when available, otherwise CPU; there is no MPS selection. English generation chooses Bella, not Relay's George. Its separate conversion API could accept Relay-generated audio, but that integration is untested. Download calls use working-directory-relative assets without immutable revisions. Japanese setup can download a dictionary. Consequently, offline operation needs explicit provisioning and testing, not assumptions from cached behavior.

The [chunking implementation](https://github.com/Ashish-Patnaik/kokoclone/blob/dd6bd3acd3010dc223978839761db74957195f98/core/chunked_convert.py) collects converted mel chunks, concatenates them, and vocodes the complete result before returning. It is not a first-audio streaming API. Its function default targets 90% CUDA memory although prose says 50%; the positional-window assumptions also need checking against the exact model configuration. Chunking alone does not prove bounded whole-utterance memory. Mac latency, peak RAM, CPU load, power, cancellation and long-output stability remain unmeasured.

## Deployment and maintenance

The pinned [package manifest](https://github.com/Ashish-Patnaik/kokoclone/blob/dd6bd3acd3010dc223978839761db74957195f98/pyproject.toml) requires Python >=3.12, torch/torchaudio >=2.10, huggingface-hub >=1.5, and kokoro-onnx with its GPU extra; Kanade is an unpinned Git source. Relay's current requirements retain Hugging Face Hub <1. Do not merge these environments. The separate [requirements file](https://github.com/Ashish-Patnaik/kokoclone/blob/dd6bd3acd3010dc223978839761db74957195f98/requirements.txt) is largely unpinned and differs from the manifest, so its documented install routes are not equivalent reproducible environments.

The [Gradio app](https://github.com/Ashish-Patnaik/kokoclone/blob/dd6bd3acd3010dc223978839761db74957195f98/app.py) uses fixed output filenames and binds to all interfaces. Do not embed or launch that demo as Relay's service. A private subprocess adapter, unique outputs, controlled downloads and a locked dependency manifest would be required. Recent commits show activity, not a maintenance SLA or macOS qualification.

## Revised comparison

| Candidate | Evidence available | Decision |
| --- | --- | --- |
| Existing Kokoro/George | Current Relay synthesis and playback implementation | Keep baseline and fallback |
| KokoClone / Kanade | Upstream source inspection only; no local performance or listening data | New comparison candidate; resolve code-license uncertainty and qualify Mac runtime first |
| Qwen3-TTS 0.6B Base / MLX | Prior M4/24 GB synthetic-reference results: warm RTF 0.780–0.903, completed-chunk latency 2.783–7.814 s | Retain comparator and prior measured leader, not production selection |
| Chatterbox multilingual v3 / MLX | Prior same-machine warm RTF 1.280–2.593, latency 6.393–8.312 s | Secondary comparator; prior runs slower/larger |
| XTTS-v2 | Authoritative checkpoint terms refreshed | Exclude from commercial default under these terms |

The [Qwen base card](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base) confirms Apache-2.0 metadata and reference-audio cloning. Its advertised streaming latency is not a measurement of the prior MLX adapter. The [Chatterbox card](https://huggingface.co/ResembleAI/chatterbox) confirms MIT metadata and multilingual v3; this does not verify the community conversion's exact provenance. The [XTTS checkpoint license](https://huggingface.co/coqui/XTTS-v2/raw/main/LICENSE.txt) explicitly limits the model and outputs to non-commercial use. Prior runtime versions and benchmark revisions are preserved in the original report, not represented as newly benchmarked or latest releases.

## Relay architecture and privacy decision

Current source inspection confirms `services/tts_worker.py` directly calls Kokoro and writes WAV output, while `services/preview_voice.py` is also Kokoro-specific. Settings, persistence, preview and engine reload would all need deliberate integration; saving an engine name alone is insufficient.

Retain the original report's shared SpeechCoordinator, identity-scoped cancellation, replay and exactly-once George fallback. For KokoClone, evaluate a conversion subprocess below that boundary using existing Kokoro output; for Qwen, evaluate direct synthesis. Preserve command/utterance identity through both stages. A conversion timeout must not leave Preparing speech stuck or play both original and converted audio. Preview must use the same selected engine path. Codex and Claude should share the adapter; neither provider gains access to reference assets.

Retain the original proposed consent/import/deletion contract: permissioned reference audio, private Application Support storage outside repositories, no reference uploads, explicit model-download consent, owner-only temporary files, deletion of derived assets and replay, and update rollback. Model cards and demo availability do not establish speaker consent. These remain proposed contracts, not shipped functionality.

## Bounded next validation

1. Resolve Kanade code licensing; pin every runtime/model/vocoder revision, dependency and checksum. Verify a Mac-compatible CPU installation in an isolated environment. Do not silently patch in MPS and present that as stock KokoClone support.
2. With separate permission for downloads and audio, compare KokoClone, Qwen and George using the same consented 5–10 second reference and short, medium, technical and long prompts. No reference transcript is required by KokoClone's API; provide one where another candidate needs it. Evaluate languages separately.
3. Run ten cold and ten warm samples on M4/24 GB and the lowest supported memory tier. Record p50/p95 first audible playback, synthesis/conversion time, RTF, total memory, disk, CPU/GPU, power and cancellation. KokoClone's complete pipeline footprint is unknown; parameter count is not a RAM measurement.
4. Blind listening must compare similarity, intelligibility, naturalness and pronunciation. Agree product latency/quality thresholds before testing; no winner can be declared from waveform generation or marketing claims.
5. Only after a favorable result, authorize installed-app integration tests covering offline restart, interrupted downloads, corrupt assets, crashes/timeouts, cancellation, replay, deletion and exactly-once fallback with both providers.

Research rerun complete; production validation remains open. No follow-up tickets or workers were created. Documentation consistency and `git diff --check` are the appropriate checks for this source-only investigation; no runtime test or audible pass is claimed.
