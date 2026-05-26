# Relay Vision — Specification

**Created:** 2026-05-26
**Status:** Implemented
**Owner:** matthewthomas94

> Relay Vision is the **screen-observation** half of the Relay stack, split out of [Relay Actions](relay-actions.md) in RR-10. Relay Actions keeps *manipulation* (`click`, `type`, `scroll`, `key`, `list_windows`, `frontmost_app`); Relay Vision owns *observation*. The split keeps "looking at the screen" and "acting on the screen" as separate tool families so prompts and CLAUDE.md guidance can address each cleanly.

## Goal

Give voice-driven Claude a clean, separately-namespaced way to *see* the screen — without bundling observation into the manipulation tool family. The user-facing voice intent "look at my screen" routes to `mcp__relay-vision__screenshot`.

## Scope

Initial scope is exactly one tool, moved verbatim from Relay Actions with behavioral parity:

- **`screenshot(display_index?: int)`** — Capture a connected display and return a base64-encoded PNG plus a sibling text block with the captured pixel dimensions. Defaults to the primary display (`display_index: 0`). Pixel dimensions match `NSScreen.frame × backingScaleFactor` (native pixels), the same coordinate space the Relay Actions `click`/`scroll` tools consume. Returns a descriptive error string (not a crash) when Screen Recording permission is missing or capture fails.

The namespace is designed to grow — future observation tools could include region reads or text extraction — but those are **out of scope** for the initial split.

## Architecture

- **`Sources/relay-vision-mcp/`** — a standalone Swift executable MCP target, mirroring `Sources/relay-actions-mcp/`. Hand-rolled JSON-RPC 2.0 over stdio (initialize / tools/list / tools/call), single-threaded. Server name `relay-vision`.
- Reuses the same permission-preflight, parent-process detection, and menu-bar-notification helpers as Relay Actions (the same `PermissionPreflight`, `ParentProcess`, and `ConfirmationClient` patterns).
- **ActionGlow parity:** the server fires the same `tool_fired` notification (same name and payload shape, same `/tmp/relay_actions.sock`) after every successful tool call, so the ActionGlow perimeter overlay pulses on screenshot calls with no overlay changes.

## Registration & packaging

- Registered with the bundled `claude` CLI at user scope by `scripts/relay-bridge` (`claude mcp add -s user relay-vision -- <binary>`), gated on a `claude mcp get relay-vision` probe — mirroring the `relay-actions` registration.
- Bundled into the `.app` and codesigned by `scripts/build-dmg.sh`, alongside `relay-actions-mcp` and `relay-orchestrator-mcp`. TCC attribution falls on the bundle (Screen Recording prompts read "Relay Runner").

## Acceptance

- [ ] `mcp__relay-vision__screenshot` is discoverable by `claude` and returns an image + dimensions block identical to the pre-split `mcp__relay-actions__screenshot`.
- [ ] ActionGlow pulses on a `relay-vision` screenshot, identically to before the split.
- [ ] The old `mcp__relay-actions__screenshot` tool no longer exists; the remaining Relay Actions tools still pulse ActionGlow.
- [ ] Screen Recording denial returns a descriptive error string naming the terminal/IDE to grant, not a crash.

## Non-goals

- Region reads, text extraction, screenshot history/diff/annotate — deferred until a concrete need appears.
- Any change to the ActionGlow overlay itself.
