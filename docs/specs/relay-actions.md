# Relay Actions

**Status:** Implemented

Relay Actions is Relay Runner's screen-manipulation and window-introspection MCP service. Relay Vision owns screenshot observation in a separate namespace. Both are registered for available Codex and Claude CLIs and forward privileged work to Relay Runner.app.

## Capabilities

The current `relay-actions-mcp` server exposes:

- `click` — click or double-click a screen coordinate with an optional button and modifiers;
- `type` — type text into the focused application;
- `key` — send a key or modifier combination;
- `scroll` — send horizontal or vertical scroll input;
- `frontmost_app` — identify the focused application;
- `list_windows` — list visible application windows and frames;
- `activate_project` — select a known registered project through the app-owned project route;
- `toggle_board` — open or close the project Work surface.

`propose_action` remains registered for protocol compatibility with older clients, but current Relay instructions explicitly tell agents not to call it. Its abandoned modifier-double-tap confirmation flow conflicts with the same gestures used for voice playback. It is not part of the supported user workflow.

## Permission and process boundary

The MCP executable is a JSON-RPC adapter. Accessibility-gated operations run in Relay Runner.app through its local hosted-tool socket so macOS attributes the grant to **Relay Runner**, not to Codex, Claude, Terminal, or an editor.

Without Accessibility, manipulation and accessibility-based introspection return a descriptive error. Voice recording and speech still work from the app's available controls. Input Monitoring can provide listen-only global-shortcut behavior but does not grant Relay Actions control.

Relay Actions does not capture screenshots. That requires the separately registered [Relay Vision](relay-vision.md) service and Screen Recording permission.

## ActionGlow and confirmation behavior

Every successful Relay Actions call sends a local `tool_fired` notification to the app. ActionGlow pulses around the screen edge and decays after the activity window. It is a visible signal that the tool ran, not proof that the target application accepted the input and not a confirmation gate.

Starting a Relay session authorizes ordinary use of the tools within the user's request and the provider's configured permissions. For an irreversible, externally visible, financial, destructive, or otherwise consequential action whose intent is unclear, the foreground agent asks in normal conversation and waits for an explicit answer. Confirmation must not be routed through `propose_action` or an unrelated native computer-control prompt.

## Coordinate and error behavior

Click coordinates use the same native-pixel display space returned by Relay Vision. Window frames are derived from macOS workspace and accessibility APIs. Tool errors are returned as MCP error content rather than crashing the server. A successful transport response does not prove the requested higher-level outcome; callers should inspect the target state when that outcome matters.

## Registration and packaging

`scripts/relay-bridge` idempotently registers the bundled `relay-actions-mcp` binary for every available supported provider. `scripts/build-dmg.sh` builds, embeds, and signs the helper alongside `relay-vision-mcp` and `relay-orchestrator-mcp`.

Codex and Claude receive the same tool schema, app-hosted permission boundary, ActionGlow behavior, and user-confirmation rule. Provider differences are limited to MCP registration commands and the surrounding provider CLI permission model.
