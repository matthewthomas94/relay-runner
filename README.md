# Relay Runner

A native macOS menu bar app that gives [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) a voice — speak prompts, hear responses, watch a live transcription overlay.

All speech-to-text and text-to-speech runs **on-device**. No voice data leaves your machine; only the transcribed text reaches Claude, the same way typing would.

> **Status:** early release. Claude Code is the only supported target for now.

---

## How it works

```
  mic  ──►  STT (Parakeet, on-device)  ──►  claude CLI  ──►  TTS (Kokoro, on-device)  ──►  speakers
                                      │
                                      └──►  overlay pill (live transcript + response)
```

- **Menu bar app** (SwiftUI) handles UI, hotkeys, audio capture, STT, and the on-screen awareness overlay
- **Python bridge** (`voice_bridge.py`) pipes transcribed text into the `claude` CLI and reads its JSON responses back out to the TTS engine

---

## Requirements

- **macOS 14 (Sonoma) or later**, Apple Silicon recommended (Parakeet uses the ANE)
- **[Claude Code](https://docs.claude.com/en/docs/claude-code/setup)** installed and authenticated — the `claude` CLI must be on your `$PATH`
- **Python 3.10+** (usually already present on macOS via Homebrew or Xcode). Used for the TTS worker and bridge; a virtualenv is created on first launch

---

## Install

1. Download the latest `RelayRunner.dmg` from [Releases](../../releases) (or build from source — see below).
2. Open the DMG and drag **Relay Runner.app** to **Applications**.
3. Launch it. It appears in the menu bar (top-right).
4. Grant **microphone access** when prompted.
5. First-run downloads:
    - Parakeet STT model (~600 MB) — on first transcription
    - Kokoro TTS model (~60 MB) — on first playback
    - Python venv with dependencies — on first `/relay-bridge` invocation

---

## Use it

### From Claude Code

In the Relay Runner menu, click **Settings → General → Install** under *Claude Code Skills*. This adds two slash commands to Claude Code:

- `/relay-bridge` — starts a voice session in the current Claude Code window
- `/relay-stop` — ends it

Once installed, run `claude` in your terminal and type `/relay-bridge`.

### Controls

| Action | Default |
| --- | --- |
| Toggle recording | **Caps Lock** (tap to start, tap again to stop + send) |
| Change activation key | Settings → STT |
| Open settings | Menu bar → Settings, or `⌘,` |
| Quit | Menu bar → Quit |

Tray icon states:

- Outline R/ — idle
- Orange R/ — voice session active

---

## Configuration

All settings live in the Settings window. Config is persisted to:

```
~/Library/Application Support/relay-runner/config.toml
```

### General

- **Target command** — defaults to `claude`; change if Claude Code is aliased
- **Working directory** — where new voice sessions open
- **Terminal** — Warp, iTerm2, Terminal, Kitty, or Alacritty
- **Auto-start services on app launch**
- **Claude Code Skills** — install/reinstall `/relay-bridge` and `/relay-stop`

### STT

- **Model** — Parakeet TDT v2 / v3 (FluidAudio, ANE-accelerated)
- **Input device** — system default or a specific mic
- **Input mode** — Caps Lock toggle, push-to-talk, or always-on
- **Activation key** — Caps Lock by default; any single key or modifier combo
- **VAD sensitivity** — low / medium / high

### TTS

- **Voice** — 11 Kokoro voices (US / UK, male / female)
- **Auto-play** — speak responses immediately, or queue for replay
- **Rate** — 0.5× – 2.0×
- **Chime** — plays before responses (any system sound in `/System/Library/Sounds`)
- **Show macOS notification**

### Awareness (on-screen overlay)

- **Screen glow** — ambient particle field during active sessions
- **Live transcription** — show your words as you speak
- **Message preview** — show Claude's response in the pill
- **Live captions**
- **Glow intensity** — 0.1 – 1.0

---

## Permissions

Relay Runner only requests **Microphone** access. It does **not** require Accessibility or Input Monitoring — hotkey handling uses standard `NSEvent` global monitors.

---

## Build from source

```bash
git clone https://github.com/matthewthomas94/relay-runner.git
cd relay-runner
./scripts/build-dmg.sh          # Release build + DMG in ./dist/
./scripts/build-dmg.sh --debug  # Debug build
```

The build script:

- Compiles the Swift target via SPM
- Bundles the app (`dist/Relay Runner.app`) with the asset catalog compiled by `actool`
- Copies Python services into `Contents/SharedSupport/services/`
- Ad-hoc code-signs the bundle
- Packages a DMG and refreshes `/Applications/Relay Runner.app` if present

For local iteration on the Swift side, `swift build` / `swift run` works, but SwiftUI asset loading requires the full `.app` bundle — run the DMG script when testing UI assets.

### Dependencies

Swift (via SPM):

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet STT on the Apple Neural Engine
- [TOMLKit](https://github.com/LebJe/TOMLKit) — config file parsing

Python (installed into a local venv on first run):

- `kokoro-onnx` — TTS inference
- `onnxruntime`
- `numpy`

---

## Project layout

```
Sources/relay-runner/     Swift app
  App/                    Entry point, AppState
  STT/                    Audio capture, Parakeet engine, hotkey gesture
  Overlay/                Awareness pill, particle renderer, state machine
  Settings/               SwiftUI settings window (tabs)
  Config/                 TOML config I/O
  Resources/              Asset catalog (app icon, tray icons)
services/                 Python voice bridge + Kokoro TTS worker
scripts/                  build-dmg.sh, relay-bridge entry point
Info.plist                Bundle metadata
```

---

## Troubleshooting

- **Tray icon blank** — quit the app fully (menu → Quit) and relaunch after a rebuild; macOS caches menu bar items.
- **`/relay-bridge` does nothing** — make sure `claude --version` works in the same terminal, and that the Relay Runner app is running (STT happens inside the menu bar app).
- **First launch is slow** — model downloads and venv setup happen lazily. Subsequent launches are instant.
- **No audio output** — check Settings → TTS → Auto-play. If off, press the replay hotkey to flush the queue.

---

## License

MIT License

Copyright (c) 2026 Matthew Thomas

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

---

## Acknowledgments

- [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference for Parakeet on the ANE
- [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) for the TTS voices
- [Claude Code](https://github.com/anthropics/claude-code) by Anthropic
