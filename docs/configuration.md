# Configuration reference

Most settings belong in Relay Runner's Settings window. The app writes TOML to:

```text
~/Library/Application Support/relay-runner/config.toml
```

Prefer the UI: it validates provider/model combinations, permissions, audio devices, and project state. Manual edits should be made while Relay Runner is not rewriting Settings.

## General

- **LLM Provider** — Codex or Claude.
- **Orchestrator Model / Effort** — provider-specific choices described in [Provider setup](providers.md).
- **Sub-agent sizing** — let the orchestrator choose per ticket, or use the configured default policy.
- **Registered projects** — Add, Create, Locate/Regrant, or safely remove project registry entries. A project may live anywhere on the Mac.
- **Auto-start services on app launch** — start Relay background services with the app.
- **Prevent sleep while running** — keep macOS awake during active work.
- **Bypass agent permission prompts** — pass the selected provider's permission-bypass flag. Enabled by default.
- **Relay Skills** — install or refresh Codex and Claude bridge/stop skills and Relay MCP registration.

The legacy `working_directory` key can still be read for migration, but registry v2 uses an explicitly selected project for session mutation authority.

## Speech to text

- **Model** — Parakeet TDT v2 (English, recommended) or v3 (larger, multilingual transcription).
- **Input device** — system default or a selected microphone.
- **Input mode** — toggle, push-to-talk, or always-on behavior exposed by the current UI.
- **Activation key** — Caps Lock by default; non-modifier global keys can require Input Monitoring.
- **VAD sensitivity** — Low, Medium, or High voice-activity sensitivity.

Parakeet models download on first use and are cached locally by FluidAudio.

## Text to speech

- **Voice** — installed Kokoro English voice.
- **Auto-play** — speak completed responses immediately or retain them for replay.
- **Rate** — playback speed.
- **Chime** — optional system sound before speech.
- **Notification** — optional macOS notification.

Kokoro model and voice files download during setup to `~/.local/share/kokoro/`. The Python venv lives under Relay Runner's Application Support directory, outside the signed app bundle.

## Awareness

- Screen glow and particle intensity
- Live transcription
- Response preview and captions
- On-screen session state

Relay Runner honors reduced-motion behavior where the relevant animation supports it. Visible state is informational; ActionGlow signals that a Relay Actions or Relay Vision tool succeeded and is not a confirmation prompt.

## Advanced keys

The `[general]` table also persists provider command paths, messenger enable/model/effort, sub-agent policy/model/effort, and compatibility values. Unknown or unsupported provider/model/effort combinations are normalized by the app. Do not copy a config between accounts and assume the same provider catalog is available.

Project registry, ticket, artifact, and daemon configuration have separate ownership. See [Registry v2](architecture/registry-v2.md), [Project scope](architecture/project-scope-v2.md), and [Orchestrator tickets](specs/orchestrator-tickets.md) before changing those files by hand.

Continuity recovery uses the configured foreground provider by default. Cross-provider fallback is disabled unless `[continuity]` explicitly provides all four values: `fallback_provider`, `fallback_command`, `fallback_model`, and `fallback_effort`. An incomplete policy fails closed on the original provider; Relay Runner never infers a different authentication, model, effort, or billing path.
