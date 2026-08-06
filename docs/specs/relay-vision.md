# Relay Vision

**Status:** Implemented

Relay Vision is Relay Runner's screen-observation MCP service. It is intentionally separate from [Relay Actions](relay-actions.md), which owns screen manipulation and window introspection.

## Capability

The current `relay-vision-mcp` server exposes one tool:

- `screenshot(display_index?: int)` captures a connected display as a base64 PNG. Display `0` is the default primary display. The response includes the native pixel dimensions used by Relay Actions click and scroll coordinates.

Relay Vision excludes Relay Runner overlay windows from the capture policy where the app can identify them, hides the pointer in the returned frame, and returns a descriptive MCP error when the display index is invalid or capture fails.

## Permission and process boundary

The MCP executable forwards the request through a local socket to Relay Runner.app. The app performs ScreenCaptureKit capture so macOS attributes Screen Recording to **Relay Runner**, not Codex, Claude, Terminal, or an editor.

If Screen Recording is absent, Relay Runner requests the grant and returns recovery instructions when it remains unavailable. macOS can require Relay Runner to quit and relaunch after the permission changes. Microphone transcription, local speech, and non-visual Relay Actions do not require Screen Recording.

A screenshot is local until the tool is invoked. Its image result is returned to the requesting Codex or Claude session and can therefore reach that provider. Do not capture private or unrelated applications when they are not needed for the request.

## ActionGlow

Every successful screenshot sends the same local `tool_fired` notification used by Relay Actions. ActionGlow pulses around the screen edge and then decays. The glow is a visible signal that observation occurred, not a confirmation gate or proof of the requested higher-level outcome.

## Registration and packaging

`scripts/relay-bridge` idempotently registers the bundled `relay-vision-mcp` binary with every available supported provider. `scripts/build-dmg.sh` builds, embeds, and signs it alongside the Relay Actions and orchestrator helpers.

Codex and Claude receive the same screenshot schema, app-hosted permission ownership, coordinate space, errors, and ActionGlow behavior. Provider differences are limited to MCP registration commands and the surrounding provider CLI data policies.

Region capture, OCR, screenshot history, annotation, and automatic background observation are not current capabilities.
