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

- **Model** — Phonon 2 (English, requires macOS 15 or later), Parakeet TDT v2 (English), or Parakeet TDT v3 (larger, multilingual). macOS 14 offers only the two Parakeet models; choose v3 for languages other than English.
- **Input device** — system default or a selected microphone.
- **Input mode** — toggle, push-to-talk, or always-on behavior exposed by the current UI.
- **Activation key** — Caps Lock by default; non-modifier global keys can require Input Monitoring.
- **VAD sensitivity** — Low, Medium, or High voice-activity sensitivity.

Models download on first use and are cached locally by FluidAudio; switching models never deletes another model's cache. A model change applies from the next recording: a command still being captured, an active note, and a pending note recovery keep the model they started with.

`[stt] model` accepts `phonon-2`, `parakeet-tdt-v2`, or `parakeet-tdt-v3`. Legacy Whisper names load as Parakeet (`*.en` as v2, `large`/`large-v3` as v3). Any other name is reported as an error instead of being replaced, and Phonon 2 is refused on macOS 14 before anything is downloaded.

### Phonon 2 default and migration

Phonon 2 is planned to become the default on macOS 15 or later. Until that rollout is switched on (RR-416), fresh installs and existing users stay on Parakeet v2 and Phonon 2 is an explicit choice.

Once switched on, a user still on the implicit Parakeet v2 default is migrated once: Phonon 2 downloads, compiles, and passes a smoke test first, then becomes active only when no recording or note is in progress. Settings shows the download and preparation progress. If preparation fails or is cancelled, Parakeet v2 stays active and Settings offers **Retry**. Setup readiness reports the model only; it does not open the microphone.

The decision is recorded in `[stt] phonon_migration` (`completed`, `rolled_back`, or `explicit`) with the previous model in `phonon_migration_previous_model`. Choosing a model in Settings, including Parakeet v3, records it as explicit, and choosing Parakeet after the migration is a rollback. Neither is overridden by a relaunch or a later macOS upgrade.

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
