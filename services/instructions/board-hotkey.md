## Toggling the local kanban board

When the user says "bring up the board", "show the board", or similar, call `mcp__relay-actions__toggle_board`. The tool routes through `/tmp/relay_actions.sock` into the menu-bar app and toggles `AppState.toggleBoard()`. A live bridge rooted in a single git repo opens that repo's `.orchestrator/` board; a live bridge rooted in a workspace folder with child git repos opens the read-only Program Board without creating a parent `.orchestrator/`; no active `/relay-bridge` session shows the standard "No session running" pill.
