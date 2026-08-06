# Third-party notices

Relay Runner's original source, documentation, project artwork, and public product screenshots are distributed under the repository's [MIT License](LICENSE). Third-party components and downloaded models retain the terms below.

This inventory reflects `Package.resolved`, `services/requirements.txt`, and the first-run download paths on 2026-08-06. A release artifact includes this file, Relay Runner's license, and the license files shipped by the resolved Swift packages. Python wheels retain their package metadata in the local venv created after installation.

## Compiled into the macOS app

| Component | Resolved version | Use | License |
| --- | --- | --- | --- |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.13.6 | Local Parakeet speech recognition and audio processing | Apache License 2.0 |
| [Swift Argument Parser](https://github.com/apple/swift-argument-parser) | 1.8.2, transitive through FluidAudio | Command parsing in resolved Swift dependencies | Apache License 2.0 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.9.3 | Signed in-app updates | Permissive MIT-style license in Sparkle's `LICENSE` |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.15.0 | Embedded terminal emulator | MIT License |
| [TOMLKit](https://github.com/LebJe/TOMLKit) | 0.6.0 | TOML configuration parsing | MIT License |

Sparkle and SwiftTerm credit additional upstream contributors in their license files. The packaging script copies the resolved checkout licenses rather than replacing those notices with a summary.

## Installed into the local voice environment

These packages are not committed to the repository or pre-bundled in the signed app. First-run setup installs the ranges in `services/requirements.txt` into `~/Library/Application Support/relay-runner/services/.venv/`:

| Direct package | Declared range | License |
| --- | --- | --- |
| [NumPy](https://github.com/numpy/numpy) | `>=1.26,<3` | BSD 3-Clause |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | `>=1.20,<2` | MIT License |
| [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) | `>=0.4.9,<0.6` | MIT License; its Kokoro model is Apache License 2.0 |
| [huggingface_hub](https://github.com/huggingface/huggingface_hub) | `>=0.20,<1` | Apache License 2.0 |

Those packages can install transitive dependencies. Their wheel metadata and license files remain authoritative for the concrete environment; use `python -m pip show <package>` and the installed `.dist-info` directories when auditing a release machine.

When no compatible system Python exists, setup downloads a checksum-verified [python-build-standalone](https://github.com/astral-sh/python-build-standalone) CPython distribution. Python and the libraries included in that distribution retain their upstream licenses.

## Downloaded speech models

| Model or data | Source | License / attribution |
| --- | --- | --- |
| Parakeet TDT v2 Core ML | [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) | Creative Commons Attribution 4.0; converted by Fluid Inference from NVIDIA Parakeet |
| Parakeet TDT v3 Core ML | [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | Creative Commons Attribution 4.0; converted by Fluid Inference from NVIDIA Parakeet |
| Kokoro v1.0 ONNX and voice data | [fastrtc/kokoro-onnx](https://huggingface.co/fastrtc/kokoro-onnx) and [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) | Preserve the download repository's notice and the upstream Kokoro Apache License 2.0 attribution |

Models download to user storage and are not committed to this repository. Model cards are the authoritative source for use restrictions, attribution wording, and changes made after this inventory date.

## Fonts, icons, and provider products

Relay Runner does not bundle the optional PP Mori or PP Telegraf font binaries. If those PostScript names are already installed under the user's own font license, the app can use them; otherwise it deterministically uses macOS system fonts. Apple system fonts and SF Symbols are referenced through platform APIs and are not redistributed as repository font files.

The app icon, tray artwork, onboarding key illustrations, DMG artwork, and README screenshots have no separate third-party attribution marker in the repository and are covered by the project license. Contributors must not add proprietary artwork or font binaries without an explicit compatible license and notice.

Codex, ChatGPT, Claude, Claude Code, macOS, and Xcode are separate products governed by their vendors' terms. Relay Runner does not redistribute the Codex or Claude model services. Onboarding may invoke an official provider installer when the corresponding local CLI is missing.

## Build-only tooling

`dmgbuild`, GitHub Actions, Xcode, and the macOS command-line tools are used to build or publish artifacts but are not redistributed as Relay Runner application code. Their own licenses and service terms still apply to the build environment.

If an attribution or license is incomplete, open a documentation issue. For a confidential licensing or security concern, use the route in [SECURITY.md](SECURITY.md).
