# Third-party notices

Relay Runner's original source, documentation, project artwork, and public product screenshots are distributed under the repository's [MIT License](LICENSE). Third-party components and downloaded models retain the terms below.

This inventory reflects `Package.resolved`, `services/requirements.txt`, and the first-run download paths on 2026-08-06. A release artifact includes this file, Relay Runner's license, and the license files shipped by the resolved Swift packages. Python wheels retain their package metadata in the local venv created after installation.

## Compiled into the macOS app

| Component | Resolved version | Use | License |
| --- | --- | --- | --- |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.17.5 (revision `0b1f462`) | Local Phonon and Parakeet speech recognition and audio processing | Apache License 2.0 |
| [text-processing-rs](https://github.com/FluidInference/text-processing-rs) (`NemoTextProcessing.xcframework`) | 0.3.1, prebuilt static library linked through FluidAudio | Inverse text normalization for transcripts (FST engine) | Apache License 2.0; bundled crates are MIT and/or Apache License 2.0 |
| [Swift Argument Parser](https://github.com/apple/swift-argument-parser) | 1.8.2, transitive through FluidAudio | Command parsing in resolved Swift dependencies | Apache License 2.0 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.9.3 | Signed in-app updates | Permissive MIT-style license in Sparkle's `LICENSE` |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.15.0 | Embedded terminal emulator | MIT License |
| [TOMLKit](https://github.com/LebJe/TOMLKit) | 0.6.0 | TOML configuration parsing | MIT License |

Sparkle and SwiftTerm credit additional upstream contributors in their license files. The packaging script copies the resolved checkout licenses rather than replacing those notices with a summary.

text-processing-rs is copyright 2026 FluidInference. It is a Rust port of [NVIDIA NeMo Text Processing](https://github.com/NVIDIA/NeMo-text-processing) (Apache License 2.0), and its FST engine includes compiled grammars derived from NeMo Text Processing. It statically links rustfst, flate2 and other MIT- and/or Apache-2.0-licensed crates; its upstream `NOTICE` and `THIRD-PARTY-LICENSES.md` are authoritative. Because SwiftPM keeps this binary artifact outside `.build/checkouts`, the packaging script's copied license files do not include it; the Apache License 2.0 text shipped for FluidAudio applies.

## Bundled native executables

| Component | Pinned release | Use | License |
| --- | --- | --- | --- |
| [agent-desktop](https://github.com/vercel-labs/agent-desktop) (`agent-desktop`, `agent-desktop-macos-helper`) | 1.0.2, downloaded from the GitHub release and verified against SHA-256 pins in `scripts/fetch-agent-desktop.sh` | Relay Desktop accessibility-tree observation and headless actions, run by Relay Runner.app as its own child | Apache License 2.0 |

agent-desktop is copyright Vercel, Inc. Its binaries are re-signed with Relay Runner's Developer ID so the bundle notarises; the packaging script ships its verified `LICENSE` as `ThirdPartyLicenses/agent-desktop.txt`. Relay Runner exposes only the headless subset of its commands (see [Relay Desktop](docs/specs/relay-desktop.md)).

## Rust crates

The app bundle ships `relay-rs`, Relay Runner's own Rust helper, in `Contents/MacOS`. The block below is generated from `rust/Cargo.lock` by `scripts/rust-licenses`, which also refuses any crate whose license is outside its allow list; GPL-family licenses are never on that list.

<!-- BEGIN GENERATED: Rust crates — run scripts/rust-licenses, do not edit here -->

`relay-rs` is built from the Cargo workspace in `rust/` with Rust 1.94.1 and statically links the Rust standard library, which is licensed under the Apache License 2.0 or the MIT License at the user's option; the Rust project's [COPYRIGHT](https://github.com/rust-lang/rust/blob/1.94.1/COPYRIGHT) file describes the third-party material it includes.

`rust/Cargo.lock` resolves no third-party crates for `aarch64-apple-darwin`.

<!-- END GENERATED: Rust crates -->

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
| Phonon 2 Core ML | [FluidInference/phonon-2-coreml](https://huggingface.co/FluidInference/phonon-2-coreml), pinned to revision `a812a0df` | Creative Commons Attribution 4.0; Fluid Inference |
| Parakeet TDT v2 Core ML | [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) | Creative Commons Attribution 4.0; converted by Fluid Inference from NVIDIA Parakeet |
| Parakeet TDT v3 Core ML | [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | Creative Commons Attribution 4.0; converted by Fluid Inference from NVIDIA Parakeet |
| Kokoro v1.0 ONNX and voice data | [fastrtc/kokoro-onnx](https://huggingface.co/fastrtc/kokoro-onnx) and [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) | Preserve the download repository's notice and the upstream Kokoro Apache License 2.0 attribution |

Models download to user storage and are not committed to this repository. Model cards are the authoritative source for use restrictions, attribution wording, and changes made after this inventory date.

## Fonts, icons, and provider products

The app bundles the Regular and SemiBold weights of [Bai Jamjuree](https://github.com/cadsondemak/Bai-Jamjuree) (Copyright 2018 Bai Jamjuree), obtained from [Google Fonts](https://github.com/google/fonts/tree/main/ofl/baijamjuree) and licensed under the SIL Open Font License 1.1. The license ships beside the fonts as `BaiJamjuree-OFL.txt` in the app's resource bundle. If the bundled fonts cannot be registered, the app deterministically uses macOS system fonts. Apple system fonts and SF Symbols are referenced through platform APIs and are not redistributed as repository font files.

The app icon, tray artwork, onboarding key illustrations, DMG artwork, and README screenshots have no separate third-party attribution marker in the repository and are covered by the project license. Contributors must not add proprietary artwork or font binaries without an explicit compatible license and notice.

Codex, ChatGPT, Claude, Claude Code, macOS, and Xcode are separate products governed by their vendors' terms. Relay Runner does not redistribute the Codex or Claude model services. Onboarding may invoke an official provider installer when the corresponding local CLI is missing.

## Lucide icons

| Component | Pinned release | Use | License |
| --- | --- | --- | --- |
| [Lucide](https://github.com/lucide-icons/lucide) | 1.70.0 (commit `b826f0c`), the SVG source of the icons listed in `scripts/generate-lucide-icons.py` | Interface icons, compiled into the app as path data in `Sources/relay-runner/Board/LucideIcons.generated.swift` | ISC License; icons derived from Feather are also under the MIT License |

The generator copies each icon's SVG element data without changing its geometry, and `LucideIcon.swift` draws it with a 1.5 stroke instead of Lucide's default 2. Several icons in the set, such as `x`, `check` and `search`, derive from [Feather](https://github.com/feathericons/feather); Lucide's license lists them by their original names. Lucide's `LICENSE` at that release follows in full:

```text
ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

---

The following Lucide icons are derived from the Feather project:

airplay, alert-circle, alert-octagon, alert-triangle, aperture, arrow-down-circle, arrow-down-left, arrow-down-right, arrow-down, arrow-left-circle, arrow-left, arrow-right-circle, arrow-right, arrow-up-circle, arrow-up-left, arrow-up-right, arrow-up, at-sign, calendar, cast, check, chevron-down, chevron-left, chevron-right, chevron-up, chevrons-down, chevrons-left, chevrons-right, chevrons-up, circle, clipboard, clock, code, columns, command, compass, corner-down-left, corner-down-right, corner-left-down, corner-left-up, corner-right-down, corner-right-up, corner-up-left, corner-up-right, crosshair, database, divide-circle, divide-square, dollar-sign, download, external-link, feather, frown, hash, headphones, help-circle, info, italic, key, layout, life-buoy, link-2, link, loader, lock, log-in, log-out, maximize, meh, minimize, minimize-2, minus-circle, minus-square, minus, monitor, moon, more-horizontal, more-vertical, move, music, navigation-2, navigation, octagon, pause-circle, percent, plus-circle, plus-square, plus, power, radio, rss, search, server, share, shopping-bag, sidebar, smartphone, smile, square, table-2, tablet, target, terminal, trash-2, trash, triangle, tv, type, upload, x-circle, x-octagon, x-square, x, zoom-in, zoom-out

The MIT License (MIT) (for the icons listed above)

Copyright (c) 2013-present Cole Bemis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Build-only tooling

`dmgbuild`, GitHub Actions, Xcode, and the macOS command-line tools are used to build or publish artifacts but are not redistributed as Relay Runner application code. Their own licenses and service terms still apply to the build environment.

If an attribution or license is incomplete, open a documentation issue. For a confidential licensing or security concern, use the route in [SECURITY.md](SECURITY.md).
