# Third-party notices

Relay Runner's original source, documentation, project artwork, and public product screenshots are distributed under the repository's [MIT License](LICENSE). Third-party components and downloaded models retain the terms below.

This inventory reflects `Package.resolved`, `rust/Cargo.lock`, `services/requirements.txt`, `services/requirements-python-speech.txt`, and the first-run download paths on 2026-08-06, updated for the Rust speech service on 2026-11-13. A release artifact includes this file, Relay Runner's license, and the license files shipped by the resolved Swift packages. Python wheels retain their package metadata in the local venv created after installation.

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

The app bundle ships `relay-rs` and `relay-speech`, Relay Runner's own Rust helper and speech service, in `Contents/MacOS`. The block below is generated from `rust/Cargo.lock` by `scripts/rust-licenses`, which also refuses any crate whose license is outside its allow list; GPL-family licenses are never on that list.

<!-- BEGIN GENERATED: Rust crates — run scripts/rust-licenses, do not edit here -->

`relay-rs` and `relay-speech` are built from the Cargo workspace in `rust/` with Rust 1.94.1 and statically link the Rust standard library, which is licensed under the Apache License 2.0 or the MIT License at the user's option; the Rust project's [COPYRIGHT](https://github.com/rust-lang/rust/blob/1.94.1/COPYRIGHT) file describes the third-party material it includes.

`rust/Cargo.lock` resolves these crates for `aarch64-apple-darwin`:

| Crate | Version | License (SPDX) |
| --- | --- | --- |
| [aho-corasick](https://crates.io/crates/aho-corasick/1.1.5) | 1.1.5 | Unlicense OR MIT |
| [autocfg](https://crates.io/crates/autocfg/1.5.1) | 1.5.1 | Apache-2.0 OR MIT |
| [base64](https://crates.io/crates/base64/0.23.1) | 0.23.1 | MIT OR Apache-2.0 |
| [base64ct](https://crates.io/crates/base64ct/1.8.3) | 1.8.3 | Apache-2.0 OR MIT |
| [bit-set](https://crates.io/crates/bit-set/0.8.0) | 0.8.0 | Apache-2.0 OR MIT |
| [bit-vec](https://crates.io/crates/bit-vec/0.8.0) | 0.8.0 | Apache-2.0 OR MIT |
| [bitflags](https://crates.io/crates/bitflags/2.13.2) | 2.13.2 | MIT OR Apache-2.0 |
| [bytes](https://crates.io/crates/bytes/1.12.1) | 1.12.1 | MIT |
| [cc](https://crates.io/crates/cc/1.11.1) | 1.11.1 | MIT OR Apache-2.0 |
| [cfg-if](https://crates.io/crates/cfg-if/1.0.5) | 1.0.5 | MIT OR Apache-2.0 |
| [core-foundation](https://crates.io/crates/core-foundation/0.10.1) | 0.10.1 | MIT OR Apache-2.0 |
| [core-foundation-sys](https://crates.io/crates/core-foundation-sys/0.8.7) | 0.8.7 | MIT OR Apache-2.0 |
| [crc32fast](https://crates.io/crates/crc32fast/1.5.5) | 1.5.5 | MIT OR Apache-2.0 |
| [der](https://crates.io/crates/der/0.8.3) | 0.8.3 | Apache-2.0 OR MIT |
| [displaydoc](https://crates.io/crates/displaydoc/0.2.7) | 0.2.7 | MIT OR Apache-2.0 |
| [equivalent](https://crates.io/crates/equivalent/1.0.3) | 1.0.3 | Apache-2.0 OR MIT |
| [errno](https://crates.io/crates/errno/0.3.15) | 0.3.15 | MIT OR Apache-2.0 |
| [fallible-iterator](https://crates.io/crates/fallible-iterator/0.3.0) | 0.3.0 | MIT/Apache-2.0 |
| [fallible-streaming-iterator](https://crates.io/crates/fallible-streaming-iterator/0.1.9) | 0.1.9 | MIT/Apache-2.0 |
| [fancy-regex](https://crates.io/crates/fancy-regex/0.14.0) | 0.14.0 | MIT |
| [fancy-regex](https://crates.io/crates/fancy-regex/0.20.2) | 0.20.2 | MIT |
| [fastrand](https://crates.io/crates/fastrand/2.5.0) | 2.5.0 | Apache-2.0 OR MIT |
| [find-msvc-tools](https://crates.io/crates/find-msvc-tools/0.1.15) | 0.1.15 | MIT OR Apache-2.0 |
| [getrandom](https://crates.io/crates/getrandom/0.4.3) | 0.4.3 | MIT OR Apache-2.0 |
| [hashbrown](https://crates.io/crates/hashbrown/0.17.1) | 0.17.1 | MIT OR Apache-2.0 |
| [hmac-sha256](https://crates.io/crates/hmac-sha256/1.1.15) | 1.1.15 | ISC |
| [http](https://crates.io/crates/http/1.5.0) | 1.5.0 | MIT OR Apache-2.0 |
| [httparse](https://crates.io/crates/httparse/1.10.1) | 1.10.1 | MIT OR Apache-2.0 |
| [indexmap](https://crates.io/crates/indexmap/2.14.2) | 2.14.2 | Apache-2.0 OR MIT |
| [itoa](https://crates.io/crates/itoa/1.0.19) | 1.0.19 | MIT OR Apache-2.0 |
| [libc](https://crates.io/crates/libc/0.2.191) | 0.2.191 | MIT OR Apache-2.0 |
| [libm](https://crates.io/crates/libm/0.2.16) | 0.2.16 | MIT |
| [libsqlite3-sys](https://crates.io/crates/libsqlite3-sys/0.40.0) | 0.40.0 | MIT |
| [log](https://crates.io/crates/log/0.4.35) | 0.4.35 | MIT OR Apache-2.0 |
| [loqui-g2p](https://crates.io/crates/loqui-g2p/0.4.0) | 0.4.0 | MIT |
| [lzma-rust2](https://crates.io/crates/lzma-rust2/0.15.8) | 0.15.8 | Apache-2.0 |
| [matrixmultiply](https://crates.io/crates/matrixmultiply/0.3.11) | 0.3.11 | MIT/Apache-2.0 |
| [memchr](https://crates.io/crates/memchr/2.8.3) | 2.8.3 | Unlicense OR MIT |
| [native-tls](https://crates.io/crates/native-tls/0.2.18) | 0.2.18 | MIT OR Apache-2.0 |
| [ndarray](https://crates.io/crates/ndarray/0.17.2) | 0.17.2 | MIT OR Apache-2.0 |
| [num-complex](https://crates.io/crates/num-complex/0.4.6) | 0.4.6 | MIT OR Apache-2.0 |
| [num-integer](https://crates.io/crates/num-integer/0.1.47) | 0.1.47 | MIT OR Apache-2.0 |
| [num-traits](https://crates.io/crates/num-traits/0.2.19) | 0.2.19 | MIT OR Apache-2.0 |
| [once_cell](https://crates.io/crates/once_cell/1.21.4) | 1.21.4 | MIT OR Apache-2.0 |
| [ort](https://crates.io/crates/ort/2.0.0-rc.15) | 2.0.0-rc.15 | MIT OR Apache-2.0 |
| [ort-sys](https://crates.io/crates/ort-sys/2.0.0-rc.15) | 2.0.0-rc.15 | MIT OR Apache-2.0 |
| [pem-rfc7468](https://crates.io/crates/pem-rfc7468/1.0.0) | 1.0.0 | Apache-2.0 OR MIT |
| [percent-encoding](https://crates.io/crates/percent-encoding/2.3.2) | 2.3.2 | MIT OR Apache-2.0 |
| [pin-project-lite](https://crates.io/crates/pin-project-lite/0.2.17) | 0.2.17 | Apache-2.0 OR MIT |
| [pkg-config](https://crates.io/crates/pkg-config/0.3.34) | 0.3.34 | MIT OR Apache-2.0 |
| [proc-macro2](https://crates.io/crates/proc-macro2/1.0.107) | 1.0.107 | MIT OR Apache-2.0 |
| [quote](https://crates.io/crates/quote/1.0.47) | 1.0.47 | MIT OR Apache-2.0 |
| [rawpointer](https://crates.io/crates/rawpointer/0.2.1) | 0.2.1 | MIT/Apache-2.0 |
| [regex-automata](https://crates.io/crates/regex-automata/0.4.18) | 0.4.18 | MIT OR Apache-2.0 |
| [regex-syntax](https://crates.io/crates/regex-syntax/0.8.11) | 0.8.11 | MIT OR Apache-2.0 |
| [rusqlite](https://crates.io/crates/rusqlite/0.42.0) | 0.42.0 | MIT |
| [rustix](https://crates.io/crates/rustix/1.1.6) | 1.1.6 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| [rustls-pki-types](https://crates.io/crates/rustls-pki-types/1.16.0) | 1.16.0 | MIT OR Apache-2.0 |
| [security-framework](https://crates.io/crates/security-framework/3.7.0) | 3.7.0 | MIT OR Apache-2.0 |
| [security-framework-sys](https://crates.io/crates/security-framework-sys/2.17.0) | 2.17.0 | MIT OR Apache-2.0 |
| [serde](https://crates.io/crates/serde/1.0.229) | 1.0.229 | MIT OR Apache-2.0 |
| [serde_core](https://crates.io/crates/serde_core/1.0.229) | 1.0.229 | MIT OR Apache-2.0 |
| [serde_derive](https://crates.io/crates/serde_derive/1.0.229) | 1.0.229 | MIT OR Apache-2.0 |
| [serde_json](https://crates.io/crates/serde_json/1.0.154) | 1.0.154 | MIT OR Apache-2.0 |
| [shlex](https://crates.io/crates/shlex/2.0.1) | 2.0.1 | MIT OR Apache-2.0 |
| [smallvec](https://crates.io/crates/smallvec/1.16.5) | 1.16.5 | MIT OR Apache-2.0 |
| [syn](https://crates.io/crates/syn/3.0.10) | 3.0.10 | MIT OR Apache-2.0 |
| [tempfile](https://crates.io/crates/tempfile/3.27.0) | 3.27.0 | MIT OR Apache-2.0 |
| [thiserror](https://crates.io/crates/thiserror/2.0.21) | 2.0.21 | MIT OR Apache-2.0 |
| [thiserror-impl](https://crates.io/crates/thiserror-impl/2.0.21) | 2.0.21 | MIT OR Apache-2.0 |
| [tinyvec](https://crates.io/crates/tinyvec/1.13.3) | 1.13.3 | Zlib OR Apache-2.0 OR MIT |
| [tracing](https://crates.io/crates/tracing/0.1.44) | 0.1.44 | MIT |
| [tracing-core](https://crates.io/crates/tracing-core/0.1.36) | 0.1.36 | MIT |
| [unicode-ident](https://crates.io/crates/unicode-ident/1.0.27) | 1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| [unicode-normalization](https://crates.io/crates/unicode-normalization/0.1.26) | 0.1.26 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| [ureq](https://crates.io/crates/ureq/3.5.2) | 3.5.2 | MIT OR Apache-2.0 |
| [ureq-proto](https://crates.io/crates/ureq-proto/0.7.1) | 0.7.1 | MIT OR Apache-2.0 |
| [utf8-zero](https://crates.io/crates/utf8-zero/0.8.1) | 0.8.1 | MIT OR Apache-2.0 |
| [vcpkg](https://crates.io/crates/vcpkg/0.2.15) | 0.2.15 | MIT/Apache-2.0 |
| [webpki-root-certs](https://crates.io/crates/webpki-root-certs/1.0.12) | 1.0.12 | CDLA-Permissive-2.0 |
| [zeroize](https://crates.io/crates/zeroize/1.9.1) | 1.9.1 | Apache-2.0 OR MIT |
| [zip](https://crates.io/crates/zip/2.4.2) | 2.4.2 | MIT |
| [zmij](https://crates.io/crates/zmij/1.0.23) | 1.0.23 | MIT |

<!-- END GENERATED: Rust crates -->

`libsqlite3-sys` compiles in the [SQLite](https://sqlite.org/copyright.html) amalgamation, which is in the public domain.

`webpki-root-certs` is used only by the `ort-sys` build script, which downloads ONNX Runtime while `relay-speech` is compiled; nothing of it is linked into or shipped with the app. `scripts/rust-licenses` allows its CDLA-Permissive-2.0 licence for that use only.

`relay-speech` also links or embeds material that is not a Rust crate. None of it is GPL-licensed; the espeak-ng phonemiser the Python speech service uses is not part of it.

| Component | Version | Use | License |
| --- | --- | --- | --- |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | 1.31.0, the static library `ort-sys` 2.0.0-rc.15 downloads from the `ort` maintainers' build (`cdn.pyke.io`) and checks against the SHA-256 recorded in the crate | Runs the Kokoro model on the CPU | MIT License; Microsoft's `ThirdPartyNotices.txt` for ONNX Runtime lists the libraries compiled into it |
| misaki G2P lexicons and English rules, embedded in `loqui-g2p` 0.4.0 ([Awakened-Labs/loqui@717691a](https://github.com/Awakened-Labs/loqui/tree/717691aadf67408c85d87dc33e5d1d77b2ea4b4d/crates/loqui-g2p)) | misaki 0.9.4 | Turns text into phonemes | Apache License 2.0 ([hexgrad/misaki](https://github.com/hexgrad/misaki)) |
| spaCy English tokenizer rules, embedded in `loqui-g2p` | spaCy 3.8.16 | Splits text into tokens before phonemisation | MIT License ([explosion/spaCy](https://github.com/explosion/spaCy)) |
| English grapheme-to-phoneme models, embedded in `loqui-g2p` | [PeterReid/graphemes_to_phonemes_en_us](https://huggingface.co/PeterReid/graphemes_to_phonemes_en_us) and `_en_gb` | Pronounces words outside the lexicon | Apache License 2.0 |

`loqui-g2p`'s `NOTICE` at that commit is authoritative for its embedded data; its part-of-speech tagger weights are the crate authors' own, under the crate's MIT License. The Kokoro model `relay-speech` runs is downloaded to user storage and listed under [Downloaded speech models](#downloaded-speech-models).

## Installed into the local voice environment

These packages are not committed to the repository or pre-bundled in the signed app. First-run setup installs the ranges in `services/requirements.txt` into `~/Library/Application Support/relay-runner/services/.venv/`. Since RR-481 that is only `tomli` on Python 3.10. The speech packages below are the Python speech service's, which `relay-speech` replaced; setup installs them from `services/requirements-python-speech.txt` only when `RELAY_SPEECH_RUNTIME=python` selects that service as the fallback (see [Speech runtime](docs/fresh-install.md#speech-runtime)):

| Direct package | Declared range | License |
| --- | --- | --- |
| [NumPy](https://github.com/numpy/numpy) | `>=1.26,<3` | BSD 3-Clause |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | `>=1.20,<2` | MIT License |
| [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) | `>=0.4.9,<0.6` | MIT License; its Kokoro model is Apache License 2.0 |
| [huggingface_hub](https://github.com/huggingface/huggingface_hub) | `>=0.20,<1` | Apache License 2.0 |

Those packages install transitive dependencies. Their wheel metadata and license files remain authoritative for the concrete environment; use `python -m pip show <package>` and the installed `.dist-info` directories when auditing a release machine.

### Copyleft-licensed transitive packages

Resolving the Python speech packages (then in `services/requirements.txt`, now `services/requirements-python-speech.txt`) on Python 3.13 (macOS arm64) on 2026-11-11 installed 41 packages. The ones below carry a copyleft license; the rest declare MIT, BSD, Apache 2.0, PSF 2.0 or similar permissive terms. pip downloads all of them from PyPI into the services venv named above, at first run before RR-481 and now only for the fallback. None of them is committed to this repository, compiled into the app or included in the signed app bundle or DMG.

| Package | Resolved version | Required by | License |
| --- | --- | --- | --- |
| [phonemizer-fork](https://pypi.org/project/phonemizer-fork/) (fork of [bootphon/phonemizer](https://github.com/bootphon/phonemizer)) | 3.3.2 | kokoro-onnx (`>=3.3.2`) | GNU General Public License v3 or later |
| [espeak-ng](https://github.com/espeak-ng/espeak-ng) (`libespeak-ng.dylib` and `espeak-ng-data`) | 1.52.0, prebuilt inside the `espeakng-loader` wheel | espeakng-loader | GNU General Public License v3 or later |
| [espeakng-loader](https://github.com/thewh1teagle/espeakng-loader) | 0.2.4 | kokoro-onnx (`>=0.2.4`) | MIT License for the loader code in its upstream repository; the wheel declares no license metadata and carries the GPL-licensed espeak-ng library and data above |
| [certifi](https://github.com/certifi/python-certifi) | 2026.10.23 | requests, through huggingface_hub | Mozilla Public License 2.0 |
| [tqdm](https://github.com/tqdm/tqdm) | 4.70.1 | huggingface_hub | Mozilla Public License 2.0 and MIT License |

kokoro-onnx imports `phonemizer` and `espeakng_loader` to convert text to phonemes, so the Python speech services (`tts_worker.py`, `preview_voice.py`) load the espeak-ng shared library from the venv whenever Kokoro speech is generated. Later installs can resolve newer versions within the declared ranges.

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
