# Relay stack rules (compact)

This is a summary. For the full screen-control rules, call `mcp__relay-actions__get_relay_instructions` (read-only).

- Always use the Relay stack for screen control: `mcp__relay-actions__*` (click, type, scroll, key, list_windows, frontmost_app, toggle_board) to act and `mcp__relay-vision__screenshot` to look. Never fall back to `mcp__computer-use__*`, even when it is connected; if an operation is missing, tell the user instead.
- Prefer a direct shell or OS command (launch an app, open or reveal a known path, find a file) before visual navigation.
- "Look at my screen", "what's on my screen", "can you see X": call `mcp__relay-vision__screenshot` immediately, without exploring code or asking which display.
- "Bring up / show the Workspace": call `mcp__relay-actions__toggle_board`.
- Never call `propose_action`: its confirmation gesture is retired and it times out. Voice control is already authorized, so just act. For irreversible, sending, spending, or deleting actions you're unsure about, ask in chat and wait for an explicit yes.
- ActionGlow, the screen-edge glow, pulses automatically on Relay tool calls. It is a visual signal, not a confirmation.
