# Relay Runner

A native macOS menu bar app that gives Codex or [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) a voice — speak prompts, hear responses, watch a live transcription overlay.

All speech-to-text and text-to-speech runs **on-device**. No voice data leaves your machine; only the transcribed text reaches your configured agent, the same way typing would.

> **Status:** early release. Codex is the default target; Claude Code remains supported via configuration.

---

## How it works

```
  mic  ──►  STT (Parakeet, on-device)  ──►  codex/claude CLI  ──►  TTS (Kokoro, on-device)  ──►  speakers
                                      │
                                      └──►  overlay pill (live transcript + response)
```

- **Menu bar app** (SwiftUI) handles UI, hotkeys, audio capture, STT, and the on-screen awareness overlay
- **Python bridge** (`voice_bridge.py`) relays transcribed text into the active agent session and reads spoken summaries back out to the TTS engine

---

## Requirements

- **macOS 14 (Sonoma) or later**, Apple Silicon recommended (Parakeet uses the ANE)
- **Codex** installed and authenticated (default) or **[Claude Code](https://docs.claude.com/en/docs/claude-code/setup)** installed and authenticated
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

### Quickest path

1. Click the Relay Runner menu bar icon → **Start Session…**.
2. A terminal opens, runs the configured agent, and auto-starts a voice session.
3. Tap **Caps Lock** to speak; the agent responds in the terminal and via TTS.

The session is a normal Codex or Claude terminal session. By default, **Start Session…** launches the agent with its permission-bypass flag so voice flow isn't interrupted by per-tool approval prompts. You can turn that off in **Settings → General**.

### From an existing terminal

If you'd rather start from a terminal you already have open, install the commands once via **Settings → General → Install** under *Relay Skills*. This adds:

- `relay-bridge` / `/relay-bridge` — starts a voice session in the current agent window
- `relay-stop` / `/relay-stop` — ends it

Then run `codex` and ask it to use the relay-bridge skill, or run `claude` and type `/relay-bridge`. This path is identical to **Start Session…** except you decide when (and with what flags) to launch the CLI.

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

- **Target command** — defaults to `codex`; set to `claude` if you want Claude Code instead
- **Model** — Default, Opus, Sonnet, or Haiku. *Default* lets the configured agent pick from your account-level setting; the others pass `--model <alias>` to the CLI for this session.
- **Working directory** — where new voice sessions open
- **Terminal** — Warp, iTerm2, Terminal, Kitty, or Alacritty
- **Bypass agent permission prompts** — when on (default), sessions launched from **Start Session…** run with the configured agent's bypass flag so voice flow isn't interrupted. Turn off if you want the agent to ask before each tool use; voice still works, you'll just answer prompts in the terminal.
- **Auto-start services on app launch**
- **Relay Skills** — install/reinstall relay-bridge and relay-stop support for Codex and Claude Code

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
- **Message preview** — show the agent's response in the pill
- **Live captions**
- **Glow intensity** — 0.1 – 1.0

---

## Permissions

Relay Runner uses up to three macOS privacy permissions, all optional with graceful fallback:

- **Microphone** — required to capture speech.
- **Accessibility** — used to pause currently-playing media when you start recording. The app still works without it; you'll just have audio playing over your voice.
- **Input Monitoring** — required only when your activation key is *not* a modifier (Caps Lock / Option / etc.). Caps Lock-based triggering reads `NSEvent` modifier flags directly and doesn't need this permission. If you set the activation key to e.g. `F19`, macOS will ask for Input Monitoring at that point.

First-launch onboarding walks through the ones that are needed and bootstraps the bundled Python environment so voice replies work immediately. If TCC ever resets the grants (a macOS update or app reinstall can do this), the Settings → Status tab surfaces a banner explaining what happened.

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
- **relay-bridge does nothing** — make sure `codex --version` or `claude --version` works in the same terminal, that Relay Skills are installed (Settings → General → Install), and that the Relay Runner app is running (STT happens inside the menu bar app).
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
- Codex by OpenAI
- [Claude Code](https://github.com/anthropics/claude-code) by Anthropic
