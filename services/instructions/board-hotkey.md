## Toggling the local kanban board

RelayActions doesn't expose a board-toggle tool yet (tracked as RR-8). When the user says "bring up the board" or "show the board" or similar, fire the ⌃⌥ modifier-only chord directly — don't go exploring the codebase to re-derive this:

```bash
osascript -e 'tell application "System Events"
    key down control
    key down option
    delay 0.08
    key up option
    key up control
end tell'
```

The chord toggles `BoardOverlayController` in the menu-bar app, gated on an active `/relay-bridge` session — `/tmp/voice_bridge.sock` must exist.
