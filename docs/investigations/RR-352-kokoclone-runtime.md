# RR-352 — Isolated KokoClone runtime validation

> **Removed:** the custom voices feature this investigation informed was removed from Relay Runner by RR-462 (2026-11-06). Kept as history; referenced code and scripts no longer exist.

Date: 2026-09-08. Hardware: Apple M4, 24 GiB unified RAM. Branch: codex/kokoclone-prototype.

## Result

Initial technical feasibility passes: twelve finite, non-silent WAV outputs across two processes, including six with OS-level network denial. No listening or speaker-similarity pass is claimed. Proceed to a permissioned listening check and an optional app adapter; do not distribute unresolved-license dependencies yet.

| Measurement | Online provisioning process | Fresh cached, network-denied process |
| --- | --- | --- |
| Kokoro load | 0.34 s | 0.35 s |
| Clone load | 17.45 s including dependency downloads | 2.16 s |
| First short synthesis + conversion | 1.73 s | 1.83 s |
| Warm short total | 1.04–1.05 s | 1.05–1.17 s |
| Medium total, all three iterations | 2.62–2.66 s | 2.64–2.70 s |
| Process peak RSS | 2.79 GB decimal | 2.65 GB decimal |

Short output duration: 2.645 s; medium: 8.096 s. Warm conversion alone took roughly 0.34–0.47 s short and 0.87–0.88 s medium. Timing ends at completed WAV, not audible playback. Three iterations per prompt are a smoke benchmark, not p95 qualification. Peak RSS is the cumulative process high-water mark, including Kokoro, PyTorch, Kanade and vocoder; no GPU allocation is used by the conversion stage. No sustained memory-leak, thermal, power, long-output or lower-memory-Mac test was performed.

The prior Qwen report recorded 6.43 GB MLX allocation and 2.18 GB process RSS. Those counters are not directly equivalent to this CPU-only RSS measurement and must not be added or treated as a precise apples-to-apples RAM ratio. These new results support KokoClone as promising, not a definitive head-to-head win.

## Method and isolation

Environment and artifacts: `/tmp/rr352-kokoclone.7zvIOq`. No installed Relay files, voice environment, settings or existing Kokoro assets were modified. Existing Kokoro files were opened read-only. Synthetic George reference duration: 9.899 s. Source speech used Bella at speed 1.0 and the same short/medium text as RR-268.

This validates the proposed reuse path: existing Kokoro synthesis followed by upstream KokoClone.convert. It does not exercise the stock Gradio application or KokoClone.generate's automatic model-download/G2P path. The harness constructs the converter using Kanade's explicit local config/weights loader to pin its checkpoint, leaving upstream conversion code unchanged. An initial harness attempt incorrectly passed a local snapshot path as a Hub repository ID and failed; this was a harness error, corrected before the measured runs.

CPU-compatible English dependencies were installed instead of the GPU-extra/Gradio distribution. Python 3.13.13; torch/torchaudio 2.10.0; kokoro-onnx 0.5.0; misaki 0.9.4. Full resolution and raw metrics are in the adjacent evidence file.

Upstream emits warnings about missing FlashAttention, SDPA quality equivalence and CUDA autocast being disabled on CPU. Successful generation does not resolve their audio-quality implications.

Offline invocation used HF_HUB_OFFLINE=1, HF_DATASETS_OFFLINE=1 and macOS sandbox-exec policy `(version 1) (allow default) (deny network*)`; process exited zero. This proves cached generation with network denied, not offline first installation.

## Source and asset inventory

- KokoClone: dd6bd3acd3010dc223978839761db74957195f98.
- Kanade runtime: 961f20bf892c59f391d0b6c5f7b88e70ed919b99.
- Kanade weights/config: bfc4a8a753ea71394cf98e752ca68c7fbc847f0d, safetensors format.
- Vocos snapshot resolved during loading: 0feb3fdd929bcd6649e0e7c5a688cf7dd012ef21. Unlike Kanade, it was observed after resolution, not pre-pinned by the loader.
- WavLM downloaded by TorchAudio from download.pytorch.org; SHA-256: 136a3e720c04f2c77bf7a4dc6a3868b14d5a2c145a988114b733cb1a8428be98.
- Approximate allocated disk: HF cache 509 MiB; Torch cache 368 MiB; isolated environment 766 MiB. These exclude existing Kokoro assets, package download/build cache, source checkout and outputs. They are not a production installer size.

## Reproduction and remaining gates

Harness: `scripts/experiments/kokoclone_benchmark.py --root /tmp/rr352-kokoclone.7zvIOq --kokoro-dir ~/.local/share/kokoro`, run with that environment's Python. It requires the pinned upstream checkout in root/upstream. Downloads are allowed unless the caller enables offline mode/network denial. All generated assets remain beneath root, outside Git. The temporary environment may be removed by the OS and is not a shipping runtime.

Before app integration: obtain an owned/permissioned reference and listening approval. Build lazy optional conversion below shared SpeechCoordinator, preserving standard Kokoro and exact intent identity for Codex and Claude. Test cancellation, replay, timeouts/crashes, exactly-once George fallback and bounded Preparing speech cleanup. Test long utterances, offline restarts and asset deletion. Resolve Kanade runtime licensing and all transitive model provenance before redistribution. No automatic follow-up dispatch or app rebuild/install occurred.
