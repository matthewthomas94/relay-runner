# Relay App rules (compact)

Relay App (`mcp__relay-app__*`) is first-party control of Relay Runner itself over the app's owner-only command socket. Full rules: `mcp__relay-app__get_relay_instructions` (read-only).

- For Relay Runner's own status, Workspace, Notetaker, Terminal and Settings pages, settings values, projects, sessions, Relay Remote pairing and Keep Awake, use these tools before Relay Desktop, Relay Vision or Relay Actions. They return structured JSON; keep screenshots for what is genuinely visual.
- Read with `app_status` and `get_settings`. `set_settings` takes only the keys to change and saves through the same path as Settings; unknown keys and invalid values are refused.
- `end_session` and `relay_remote_unpair` need `confirm: true`; pass it only when the user asked for that effect.
- Pairing: `relay_remote_begin_pairing` shows the QR code on Settings > Relay Remote (its key and token stay in the code), `relay_remote_pending_approval` reports the phone, then `relay_remote_approve` (`restrict_to_network: true` = home network and Tailscale only) or `relay_remote_deny`. Approve only a device the user expects.
- If Relay Runner is not running, say so instead of falling back to screen control. Never `mcp__computer-use__*`.
