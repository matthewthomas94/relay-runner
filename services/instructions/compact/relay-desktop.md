# Relay Desktop rules (compact)

Relay Desktop (`mcp__relay-desktop__*`) reads and operates macOS apps through the accessibility tree, backed by the bundled agent-desktop CLI running inside Relay Runner. Full rules: `mcp__relay-desktop__get_relay_instructions` (read-only).

- For Relay Runner itself (status, pages, settings, sessions, Relay Remote pairing, Keep Awake), use `mcp__relay-app__*` first.
- Observe with `snapshot` (or `find`) before `mcp__relay-vision__screenshot`. Screenshot only when pixels matter (rendering, images, canvas, video), the user asks to see the screen, or the tree is empty.
- Act on a ref from the latest snapshot with `act` or `press`. Refs expire when the UI changes: on STALE_REF or AMBIGUOUS_TARGET, snapshot again. Use Relay Actions coordinate clicks only when no ref path exists or the user asked for physical input.
- Verify by observing again; retry only when the result's `disposition.retry` is `safe`. Use `wait` on a condition instead of sleeping. Pass `surface` while a menu, sheet, alert or popover is open.
- Headless only: no double-click, hover, drag, clipboard or quit shortcuts. Never `mcp__computer-use__*`.
- Snapshots can contain private app text and reach the provider; read only what the request needs.
