---
id: RR-8
title: Expose board toggle as a relay-actions MCP tool
status: backlog
priority: medium
depends_on: []
run_id: null
canceled: false
order: 20
---

## Description

The local kanban board (`Sources/relay-runner/Board/BoardOverlayController.swift`) can currently only be toggled via the ⌃⌥ modifier-only global hotkey or the menu-bar "Show Board" button. There is no IPC entry point, so Claude sessions that want to summon it via voice (e.g. "bring up the board") fall back to synthesizing the chord through `osascript`, which is brittle (requires Accessibility for `Terminal`/`Claude.app`) and bypasses the project's RelayActions instrumentation.

Add a first-class RelayActions tool — `mcp__relay-actions__toggle_board` (or split into `show_board` / `hide_board` if simpler) — that proxies through the existing `/tmp/relay_actions.sock` IPC channel into `AppState.toggleBoard()`. Once shipped, remove the osascript fallback from `CLAUDE.md` and route voice "bring up the board" intents through the new tool.

## Acceptance criteria

- New tool `toggle_board` (or `show_board` + `hide_board`) registered in `Sources/relay-actions-mcp/` and surfaced via the MCP server's tool list.
- Tool dispatches into the relay-runner app over `/tmp/relay_actions.sock` and calls `AppState.toggleBoard()` (or the equivalent show/hide entry points on `BoardOverlayController`).
- Tool fires the same `tool_fired` notification every other RelayActions tool sends, so RelayVision pulses on invocation.
- Round-trip latency from MCP call → board visible: well under 500 ms on a warm app (no exploration step).
- `CLAUDE.md` updated: the osascript snippet under "RelayActions — the screen-control tools" is replaced with a one-liner directing future Claude sessions to call the new tool. Mention of RR-8 removed.
- Manual verification: with the menu-bar app running and an active `/relay-bridge` session, the new tool toggles the board overlay on/off consistently.
- No regression: the existing ⌃⌥ global hotkey and the menu-bar "Show Board" button continue to work.

## Notes

- Reference implementations for "Swift action → relay-actions tool" already exist for `screenshot`, `click`, `type`, etc. in `Sources/relay-actions-mcp/`. Mirror that structure.
- The board is gated on `/tmp/voice_bridge.sock` (see `BoardOverlayController` / `ProjectResolver`). If the bridge is down, the tool should surface the same "No session running" pill rather than silently no-op.
- Don't ad-hoc-fix the bundled `.app`'s copy — DMG-build action is the source of truth; commit the Swift changes upstream and let CI rebuild.
