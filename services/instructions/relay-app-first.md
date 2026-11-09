## Relay App — control Relay Runner itself through its own MCP

For anything in Relay Runner itself — its status, the Workspace, Notetaker, Terminal and Settings pages, settings values, project selection, starting or ending a session, Relay Remote pairing and paired devices, and Keep Awake — use Relay App (`mcp__relay-app__*`) before Relay Desktop, Relay Vision or Relay Actions. Each tool reaches the app through its owner-only command socket and returns structured JSON, so it needs no screenshot, accessibility snapshot or coordinate click. Keep pixels for what is genuinely visual about Relay Runner, such as checking an animation or a layout.

- **Read first.** `app_status` reports the version, session, Remote mode, paired devices, permissions and Keep Awake; `get_settings` returns the effective settings.
- **Settings.** `set_settings` takes only the keys to change (for example `{"tts": {"rate": 1.2}}`) and applies them through the same path Settings saves each change through. Unknown keys, wrong types and values the current provider or model cannot use are refused, not coerced.
- **Destructive tools.** `end_session` and `relay_remote_unpair` refuse without `confirm: true`; pass it only when the user asked for that effect.
- **Pairing.** `relay_remote_begin_pairing` shows the QR code on Settings > Relay Remote for the user to scan; its one-time key and token never leave the code. Poll `relay_remote_pending_approval`, then approve only a device the user expects with `relay_remote_approve` (`restrict_to_network: true` is "Only from my home network and Tailscale") or decline it with `relay_remote_deny`.
- **App not running.** When a tool reports that Relay Runner is not running, tell the user; do not fall back to screen control to operate the app.

Every successful Relay App call pulses ActionGlow like every other Relay tool.
