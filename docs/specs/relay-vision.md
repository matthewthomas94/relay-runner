# Relay Vision

**Status:** Implemented

Relay Vision is Relay Runner's screen-observation MCP service. It is intentionally separate from [Relay Actions](relay-actions.md), which owns screen manipulation and window introspection.

## Capability

The current `relay-vision-mcp` server exposes two tools:

- `screenshot(display_index?: int)` captures a connected display as a base64 PNG. Display `0` is the default primary display. The response includes the native pixel dimensions used by Relay Actions click and scroll coordinates.
- `record(duration_seconds?: number, fps?: int, display_index?: int, output_path?: string)` records a connected display to an H.264 mp4 and returns a text result naming the file path, duration, frame rate, frame count and pixel size. The video is never returned inline. Duration defaults to 4 s and is clamped to 0.5–30 s; the frame rate defaults to 15 and is capped at 30; the file defaults to a timestamped `relay-vision-*.mp4` in the app's temporary directory, and any `output_path` without an `.mp4` extension gets one. Frames are scaled so the long edge is at most 2000 px, the same ceiling Claude's screenshot uses, so a frame pulled from the video lines up with a screenshot of the same display.

ScreenCaptureKit only emits a frame when pixels change, so the recorder samples the latest frame on a timer at the requested rate. The file therefore always runs for the full duration at a constant frame rate, even across a static screen. The recorder fails with a descriptive error when no frame arrives within five seconds, when the stream stops early, or when nothing could be written.

Claude Code re-encodes MCP images larger than 2000 px on either edge, which would make coordinates read off a native Retina capture drift. For `claude-code` clients, `relay-vision-mcp` therefore downscales the capture so its long edge is at most 2000 px and states a `screenshot_scale` (image pixels per native pixel, `1.000000` when no downscale is needed). Claude passes that scale to Relay Actions `click` and `scroll`, which map the image coordinate back to native pixels. Other clients, including Codex, receive the unchanged native-pixel image and text.

Relay Vision excludes Relay Runner overlay windows from the capture policy where the app can identify them, hides the pointer in the returned frame, and returns a descriptive MCP error when the display index is invalid or capture fails.

## Permission and process boundary

The MCP executable forwards the request through a local socket to Relay Runner.app. The app performs ScreenCaptureKit capture so macOS attributes Screen Recording to **Relay Runner**, not Codex, Claude, Terminal, or an editor.

If Screen Recording is absent, Relay Runner requests the grant and returns recovery instructions when it remains unavailable. macOS can require Relay Runner to quit and relaunch after the permission changes. Microphone transcription, local speech, and non-visual Relay Actions do not require Screen Recording.

A screenshot is local until the tool is invoked. Its image result is returned to the requesting Codex or Claude session and can therefore reach that provider. A recording stays on disk at the returned path until the agent reads or sends it. Do not capture private or unrelated applications when they are not needed for the request.

Agents must not run `screencapture` from a shell as a substitute: macOS then prompts the agent's host application (Claude, Codex, Terminal) for Screen Recording, while the Relay Vision tools capture through Relay Runner's existing grant.

## ActionGlow

Every successful screenshot sends the same local `tool_fired` notification used by Relay Actions. ActionGlow pulses around the screen edge and then decays. `record` additionally sends `tool_fired` as the take begins, so the glow marks the whole recording rather than only its end; Relay Runner's overlay windows are excluded from the capture, so the glow does not appear in the file. The glow is a visible signal that observation occurred, not a confirmation gate or proof of the requested higher-level outcome.

## Registration and packaging

`scripts/relay-bridge` idempotently registers the bundled `relay-vision-mcp` binary with every available supported provider. `scripts/build-dmg.sh` builds, embeds, and signs it alongside the Relay Actions and orchestrator helpers.

Codex and Claude receive the same screenshot and record schemas, app-hosted permission ownership, errors, and ActionGlow behavior. Provider differences are limited to MCP registration commands, the surrounding provider CLI data policies, and Claude's downscaled image with its stated `screenshot_scale` described above.

Region capture, OCR, screenshot history, annotation, audio in recordings, recordings longer than 30 seconds, and automatic background observation are not current capabilities.
