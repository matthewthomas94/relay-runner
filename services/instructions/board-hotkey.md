## Toggling the local kanban board

When the user says "bring up the board", "show the board", or similar, call `mcp__relay-actions__toggle_board`. The tool routes through `/tmp/relay_actions.sock` into the menu-bar app and toggles `AppState.toggleBoard()`, including the standard "No session running" pill when no active `/relay-bridge` session exists.
