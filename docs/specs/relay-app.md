# Relay App

**Status:** Implemented (RR-459)

Relay App is Relay Runner's first-party MCP service for controlling Relay Runner itself. An agent can read the app's state, open its surfaces, change settings, pick a project, start or end a session, pair or unpair a Relay Remote phone and switch Keep Awake without a [Relay Vision](relay-vision.md) screenshot, a [Relay Desktop](relay-desktop.md) snapshot or a [Relay Actions](relay-actions.md) coordinate click. Pixels stay for what is genuinely visual about the app, such as an animation or a layout.

## Capability

The `relay-app-mcp` server exposes these tools (namespace `mcp__relay-app__*`). Each forwards one command to the app and returns its result as JSON text.

| Tool | Arguments | What it does |
| --- | --- | --- |
| `app_status` | — | Version and build, the session (`none`, `starting`, `ready`, `failed`, with project), Relay Remote (Remote mode and its label, paired device count, Remote Login, pairing phase), privacy permissions and Keep Awake. |
| `navigate` | `destination` (`workspace`, `notetaker`, `terminal`, `settings`), `settings_page?` (`permissions`, `speech_to_text`, `text_to_speech`, `general`, `awareness`, `relay_remote`) | Shows the surface the way the session wheel does; a settings page is selected in the Settings view. |
| `get_settings` | — | The effective `AppConfig` (`stt`, `tts`, `general`, `awareness`) and the keys Relay Runner records itself. |
| `set_settings` | `settings` (sections mapping setting names to values) | Applies a partial update through `AppState.saveConfig`, the Settings Save path, which writes `config.toml` and hot-reloads running services. |
| `list_projects` | — | Registered projects (id, name, availability) and the session state. |
| `select_project` | `project_id` | Focuses or browses the project as `activate_project` does; never starts or stops a session. |
| `start_session` | `project_id` | `AppState.newSession(workingDirectory:)`, the Workspace Start path, through the RR-456 session handlers. |
| `end_session` | `confirm: true` | `AppState.endSession()`, through the RR-456 handlers. |
| `relay_remote_devices` | — | Paired phones (id, name, key fingerprint, network restriction) and Remote Login. |
| `relay_remote_unpair` | `device_id`, `confirm: true` | `RelayRemoteController.unpair`, as the Settings Unpair button. |
| `relay_remote_begin_pairing` | — | `RelayRemoteController.beginPairing`, then shows Settings > Relay Remote so the phone can scan the QR code. Returns the pairing id, user, hosts, port and expiry. |
| `relay_remote_pending_approval` | — | The phone waiting for approval (name, id, key fingerprint), or how the last attempt ended. |
| `relay_remote_approve` | `restrict_to_network` | Sets the "Only from my home network and Tailscale" option and allows the waiting phone, as the Settings Allow button; `true` writes a `from=` clause into its `authorized_keys` line. |
| `relay_remote_deny` | — | Declines the waiting phone, as the Settings Deny button. |
| `keep_awake` | `on` | `KeepAwakeController.toggle()` only when the request differs from the current state. |

Every client also sees `get_relay_instructions`, which returns the full rules; it is read-only and never pulses ActionGlow.

## Rules

- **Idempotent or explicit.** Reads change nothing. `navigate` only opens or focuses. `set_settings` saves only when the result differs and returns the changed keys. `start_session` for the running project only reports it. `relay_remote_begin_pairing` returns the code already showing. `keep_awake` toggles only when the request differs, reports `enabling`, `disabling` and `awaiting_approval` instead of toggling twice, and refuses `on: true` while sleep still needs restoring. `relay_remote_approve` and `relay_remote_deny` act once, on the phone currently waiting.
- **Destructive tools need `confirm: true`.** `end_session` and `relay_remote_unpair` refuse without it, in the MCP server before anything is sent and again in the app.
- **Settings validation.** Unknown sections or keys, wrong JSON types, clearing a required value and the keys Relay Runner records itself (`stt.phonon_migration`, `stt.phonon_migration_previous_model`) are refused. Choosing `general.provider` first resets the provider's command, model and efforts as the Settings picker does; a model or effort the provider cannot use is refused with the value Relay Runner would use instead, never coerced silently. `AppConfig` holds no credentials. An open Settings page with no unsaved edits shows the saved values at once.
- **Pairing secrets stay in the QR code.** The pairing key and one-time token are rendered into the code on the Settings page and are never returned to the agent, logged or stored; the tool returns only the payload's non-secret fields. The phone still scans the code, and the agent approves it only after `relay_remote_pending_approval` names the device the user expects.
- **ActionGlow.** Every successful call except `get_relay_instructions` sends `tool_fired` to `/tmp/relay_actions.sock`, like every other Relay server. A failed call does not glow.
- **App not running.** When nothing listens on the socket the tool fails with "Relay Runner is not running", and an app that predates Relay App never answers, so the call times out with a message suggesting an update.

## Transport

Relay App reuses the RR-456 session-control socket, `/tmp/relay_session_control.sock`, rather than opening another one. The app creates it mode 600 while it runs and checks every peer's uid with `getpeereid`.

- **Request.** `{"type":"app_command","id":"<uuid>","command":"<tool name>","arguments":{…}}` on one line. The MCP server opens one connection per call.
- **Reply.** `{"type":"app_result","id":"<uuid>","ok":true,"result":{…}}` or `{"type":"app_result","id":"<uuid>","ok":false,"error":"…"}`. The client skips any other line, such as a pushed `session_state`.
- **Roles.** A connection's first line decides its role. A connection that opens with `app_command` is a Relay App client and receives no `session_state` pushes. Any other first line, such as the `identify` every `relay-remote-shell` connection sends, makes it a phone connection, and an `app_command` on it is refused. The phone's `session_command` contract is unchanged.
- **Execution.** `RelayAppCommands` runs on the main actor with injected `AppState` closures and shares the `RelaySessionControl` instance and `RelayRemoteController.shared` with the phone and the Settings page, so the app has one source of truth for sessions and pairing. Pairing steps wait up to 10 seconds for the controller to settle.

## Provider parity

`scripts/relay-bridge` registers the bundled `relay-app-mcp` binary with every available supported provider, Claude and Codex, beside Relay Actions, Relay Vision and Relay Desktop, and `scripts/build-dmg.sh` embeds, signs and archives its symbols. Both providers get the same tools. Codex and other clients receive the full rules as `initialize` instructions; `claude-code` receives the compact payload in `services/instructions/compact/relay-app.md` and fetches the rest with `get_relay_instructions`. The shared rule chunk `services/instructions/relay-app-first.md` is also baked into Relay Actions, Relay Desktop, `CLAUDE.md` and `AGENTS.md`, and the app-session prompt points both providers at `mcp__relay-app__*` for Relay Runner itself.
