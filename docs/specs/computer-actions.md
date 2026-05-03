# Computer Actions — Specification

**Created:** 2026-05-03
**Status:** Draft (pre-implementation)
**Owner:** matthewthomas94

## Goal

Voice-driven Claude can drive the macOS UI for two specific use cases — UAT of in-development software and configuring dense dashboards that lack CLI/MCP interfaces (e.g. Apple Developer site, Xcode preferences) — gated by hardware double-tap confirmation, with a purple perimeter overlay while computer-vision tools are active. The existing voice → STT → `claude -p` → TTS loop is unchanged when no computer-action tools are invoked.

## Background

Today, voice prompts go through `voice_bridge.py` to `claude -p --dangerously-skip-permissions` ([services/voice_bridge.py:81](../../services/voice_bridge.py)). That gives Claude all default Code tools (Bash, Edit, Read, etc.) but no way to see the screen, click, or type into other apps.

Anthropic's Claude Cowork solves the same problem via MCP servers (`mcp__computer-use__*`, `mcp__Claude_in_Chrome__*`) bundled with the Claude Desktop app. Those servers are not publicly distributed, so we build our own narrow equivalent — a Swift-native MCP server scoped to UAT and dashboard config — and register it into the bundled `claude` CLI's MCP config.

Existing project assets we will reuse:
- Full-screen transparent overlay panel at `screenSaver` level ([Sources/relay-runner/Overlay/OverlayPanel.swift:15](../../Sources/relay-runner/Overlay/OverlayPanel.swift))
- Particle-field renderer with `.tts` purple theme ([Sources/relay-runner/Overlay/ParticleFieldRenderer.swift:12](../../Sources/relay-runner/Overlay/ParticleFieldRenderer.swift))
- Central state machine ([Sources/relay-runner/Overlay/StateMachine.swift](../../Sources/relay-runner/Overlay/StateMachine.swift))
- Modifier double-tap monitoring for Option (play) and Control (cancel) ([Sources/relay-runner/STT/CapsLockGesture.swift:189-212](../../Sources/relay-runner/STT/CapsLockGesture.swift))
- Accessibility permission already requested ([Sources/relay-runner/Permissions/PermissionsManager.swift:30](../../Sources/relay-runner/Permissions/PermissionsManager.swift))
- Bundled-CLI installer with extension points ([scripts/relay-bridge:567](../../scripts/relay-bridge))
- Unix datagram state-event socket pattern at `/tmp/voice_state.sock`

## Architecture (locked decisions)

These were resolved during the feasibility discussion and are not open for re-litigation in implementation:

| Decision                      | Choice                                                                                |
|-------------------------------|---------------------------------------------------------------------------------------|
| Implementation path           | Native Swift MCP server in this repo (not community MCP, not direct Anthropic API)    |
| Confirmation modality         | Hardware double-tap, modal: Option = yes, Control = no                                |
| Overlay color                 | Reuse existing `.tts` purple — no new theme                                           |
| State ownership               | Single source of truth in `StateMachine` (new `.computerVision(...)` state)           |
| MCP transport                 | stdio between `RelayActionsMCP` ↔ `claude` CLI                                        |
| Cross-process state           | New Unix socket between `RelayActionsMCP` ↔ menu-bar app for events + confirm replies |
| MCP server lifecycle          | Spawned per-session by `claude`; menu-bar app does not own it                         |
| Existing tool permissions     | `--dangerously-skip-permissions` stays on for Bash/Edit/Read                          |
| New tool permissions          | Computer-action tools gated by `propose_action`, not Claude Code's permission system  |
| Confirmation timeout          | 30s; default to "no" / aborted on timeout                                             |
| Perimeter glow scope          | All connected screens (user may not be looking at the screen Claude is acting on)     |
| Vision-active decay           | 10s after last MCP tool call; immediate clear on `/relay-stop` or session end         |
| Confirmation surface          | Reuse the existing pill for proposal text                                             |
| Risk tiering                  | `propose_action` accepts `risk: low | medium | high`; `low` auto-confirms with brief visual flash (no double-tap); `medium`/`high` require double-tap |

## Requirements

1. **MCP server target & bundling**: A new Swift executable target speaks MCP over stdio.
   - Current: No MCP server target exists in `Package.swift`. Only the `relay-runner` executable target is built.
   - Target: New `RelayActionsMCP` SPM executable target. Built binary is bundled inside `Relay Runner.app/Contents/MacOS/relay-actions-mcp` (or equivalent path). DMG produced by `scripts/build-dmg.sh` includes the binary.
   - Acceptance: `swift build` produces a `relay-actions-mcp` binary; running `Relay\ Runner.app/Contents/MacOS/relay-actions-mcp` returns a valid MCP server initialization response over stdio (verified with a mock MCP client).

2. **Screenshot tool**: Claude can capture the screen.
   - Current: Claude has no way to see what's on screen.
   - Target: MCP tool `screenshot(display?: string, region?: rect)` returns a base64 PNG. Uses ScreenCaptureKit. Default = primary display, full frame. Returns error string (not crash) when Screen Recording permission is missing or target is DRM-protected.
   - Acceptance: Tool call returns valid PNG bytes for primary display; returns descriptive error (not crash) when permission denied; image dimensions match the requested display's pixel resolution.

3. **Input event tools**: Claude can click, type, press keys, and scroll.
   - Current: No mechanism for Claude to drive UI input.
   - Target: MCP tools `click(x, y, button?, modifiers?)`, `type(text)`, `key(combo)`, `scroll(x, y, dx, dy)` post CGEvents to the system event stream. Coordinates are in screen-space pixels matching the most recent screenshot.
   - Acceptance: For each tool, a recorded test (e.g. click on a known menu-bar coordinate, type into TextEdit, press cmd+a, scroll in a Safari window) produces the expected observable system change.

4. **Window introspection tools**: Claude can identify what's on screen without a screenshot.
   - Current: No structured way to enumerate apps/windows.
   - Target: MCP tools `frontmost_app()` (returns `{name, bundle_id, pid}`) and `list_windows()` (returns array of `{app_name, window_title, frame, on_screen}`) using NSWorkspace + AX APIs.
   - Acceptance: `frontmost_app()` matches the user's currently focused app; `list_windows()` returns at least the windows visible in a screenshot taken at the same instant.

5. **`propose_action` confirmation tool**: Computer-action tools that touch state are gated by an explicit user confirmation step.
   - Current: No confirmation mechanism exists. Claude Code's permission system is bypassed by `--dangerously-skip-permissions`.
   - Target: MCP tool `propose_action(summary: string, risk: "low"|"medium"|"high")`. Behavior: `low` returns `{confirmed: true}` after sending a brief visual flash event to the menu-bar app (~300ms); `medium` and `high` block waiting on user double-tap, returning `{confirmed: true}` on Option-double-tap, `{confirmed: false, reason: "user_rejected"}` on Control-double-tap, `{confirmed: false, reason: "timeout"}` after 30s of no input.
   - Acceptance: Calling with `risk: "low"` returns within 500ms with `confirmed: true`; calling with `risk: "high"`, then double-tapping Option, returns `confirmed: true`; double-tapping Control returns `confirmed: false, reason: "user_rejected"`; no input for 30s returns `confirmed: false, reason: "timeout"`.

6. **MCP auto-registration**: The bundled CLI install flow registers the MCP server.
   - Current: `scripts/relay-bridge` installs the `claude` CLI and the `/relay-bridge` skill, but no MCP servers are configured for it.
   - Target: After CLI install, the script writes an MCP server entry pointing to the absolute path of `relay-actions-mcp` inside the `.app`. Idempotent (does not duplicate on re-run). User-editable file (does not clobber unrelated MCP entries).
   - Acceptance: Fresh install on a clean machine produces a `claude` CLI configured to launch `relay-actions-mcp` on session start. Running `claude` and asking "what tools do you have?" lists the new MCP tools. Re-running the installer does not duplicate the entry.

7. **Modal double-tap confirmation gestures**: When a confirmation is pending, Option/Control double-tap means yes/no instead of play/cancel.
   - Current: Option double-tap = `__PLAY__`; Control double-tap = `__CANCEL__` ([CapsLockGesture.swift:189-212](../../Sources/relay-runner/STT/CapsLockGesture.swift)). No notion of confirmation state.
   - Target: `CapsLockGesture` consults `StateMachine`. If `state == .computerVision(awaitingConfirmation: prompt)` is set, double-tap Option resolves the pending prompt with `confirmed: true` and double-tap Control resolves it with `confirmed: false`. Neither emits the existing `__PLAY__`/`__CANCEL__` while a confirmation is pending. When no confirmation is pending, gestures behave exactly as today.
   - Acceptance: With no confirmation pending, double-tap Option still triggers TTS playback (verified by existing `__PLAY__` path); with a confirmation pending, double-tap Option resolves the prompt and does NOT trigger playback; same for Control double-tap respectively.

8. **Perimeter overlay**: Purple particle band around all connected screens while computer vision is active.
   - Current: `OverlayPanel` is a full-screen `screenSaver`-level panel, but renders only the centered transcription pill ([OverlayPanel.swift:5-26](../../Sources/relay-runner/Overlay/OverlayPanel.swift)).
   - Target: A new `PerimeterOverlay` view renders a ~24pt-thick band along the perimeter of every connected screen, using the existing `.tts` purple particle theme ([ParticleFieldRenderer.swift:12](../../Sources/relay-runner/Overlay/ParticleFieldRenderer.swift)). Visible whenever `state == .computerVision(...)`. Brightness/intensity pulses higher when `awaitingConfirmation` is non-nil. Click-through (does not intercept input).
   - Acceptance: After Claude calls any computer-action MCP tool, the perimeter band appears on every connected screen within 100ms and uses the `.tts` purple. Mouse clicks pass through it to underlying apps. Band intensity visibly pulses while a confirmation is pending. Band clears within 100ms of the 10s decay window expiring or `/relay-stop` running.

9. **Screen Recording permission flow**: First-run UX explains and routes the user to grant Screen Recording.
   - Current: `PermissionsManager` manages microphone, accessibility, and input-monitoring ([PermissionsManager.swift:30-44](../../Sources/relay-runner/Permissions/PermissionsManager.swift)). Screen Recording is not requested.
   - Target: New `PermissionKind.screenRecording` case. `Info.plist` includes `NSScreenCaptureDescription`. PermissionsManager polls Screen Recording status via the same pattern. Onboarding view explains why it's needed (computer-action features only). The app degrades gracefully if denied — `screenshot` tool returns a clear error string and the user is notified once via the existing `PermissionNotifier`.
   - Acceptance: On a fresh install, denying Screen Recording does not crash the app or block voice features; the perimeter overlay does not appear; calling the `screenshot` tool from voice returns a TTS message explaining the permission is missing and routing the user to Settings.

10. **Risk-tiered confirmation**: Read-only or low-blast-radius actions auto-confirm; state-changing actions require double-tap.
    - Current: N/A (no actions exist yet).
    - Target: `propose_action` requires Claude to classify each action. The system prompt or tool description guides classification: `low` = reversible/read-only (taking a screenshot, scrolling, hovering, reading window titles); `medium` = single-step state changes (clicking a button, typing into a field, pressing a key combo); `high` = irreversible or destructive (pressing Enter on a confirmation dialog, clicking buttons whose label includes Delete/Submit/Send/Pay/Confirm, sending keystrokes that would bypass a system dialog).
    - Acceptance: A test session that has Claude take 5 screenshots and 5 scrolls produces zero double-tap requirements. A test session that has Claude click a non-destructive button produces a medium-risk prompt resolvable by double-tap. A test session that has Claude click a destructive-labeled button produces a high-risk prompt.

11. **Existing voice loop unchanged in absence of computer-action tools**: Adding computer actions does not regress the existing experience.
    - Current: Voice → STT → `claude -p` → TTS works as documented in [README.md](../../README.md).
    - Target: A voice session that does not invoke any computer-action MCP tool has identical perceived latency, identical pill behavior, identical gestures, and no perimeter overlay.
    - Acceptance: Running a regression script of 10 prompts that don't touch computer-action tools (e.g. "what time is it", "summarize the last commit", "what files changed today") shows: no perimeter overlay, double-tap Option still plays TTS, double-tap Control still cancels, end-to-end latency within ±10% of baseline.

## Boundaries

**In scope:**
- New `RelayActionsMCP` Swift SPM executable bundled in the `.app`.
- The 8 MCP tools listed: `screenshot`, `click`, `type`, `key`, `scroll`, `frontmost_app`, `list_windows`, `propose_action`.
- Pixel-based interaction with browser windows (treats Safari/Chrome as another macOS app).
- Auto-registration of the MCP server during bundled-CLI install.
- Modal hardware double-tap confirmation reusing existing Option/Control gestures.
- Purple perimeter overlay on all connected screens, reusing the existing `.tts` particle theme.
- Screen Recording permission added to PermissionsManager + Info.plist.
- Risk-tiered confirmation (low/medium/high) with `low` auto-confirming.
- Graceful failure modes (errors returned to Claude, no crashes).
- Compatibility with both menu-bar mode and `/relay-bridge` slash-command mode.

**Out of scope** (reason in italics):
- DOM-aware browser automation via Chrome extension MCP — *pixel-based works for v1; defer until pixel approach proves insufficient for the stated use cases.*
- App-specific MCP integrations (Mail, Slack, Calendar, Granola) — *Cowork's value-add; not needed for UAT or dashboard config.*
- Cross-app multi-step workflow orchestration in Relay Runner — *Claude can chain tool calls itself; orchestration belongs in the model, not the host.*
- Per-app tier restrictions ("browsers read-only, terminals click-only") — *defer until a real safety incident motivates the complexity.*
- Recorded UAT scripts / replay — *future feature; out of v1 scope.*
- Screenshot history / diff / annotate tools — *start without; add only if Claude Code session memory loses earlier screenshots in practice.*
- Per-app permission gating UI — *the global Screen Recording + Accessibility grants cover all apps; per-app TCC enforcement is macOS's job.*
- Voice-spoken confirmation as an alternative to double-tap — *spoofable by TTS audio; intentionally avoided.*
- Headless / unattended mode — *the whole point is interactive confirmation; no value in unattended.*

## Constraints

- **Coordinates must match screenshot pixels.** Whatever coordinate space `screenshot` returns must be the same space `click(x, y)` consumes. On Retina displays this means clarifying logical-points vs. backing-pixels and picking one consistently. Documented in the MCP tool descriptions.
- **No new heavyweight dependencies.** ScreenCaptureKit, CGEvent, NSWorkspace, AX, and JSON-over-stdio are sufficient. No SwiftPM additions for an MCP framework — we write the protocol layer ourselves (it's small) or vendor the smallest viable Swift MCP package after evaluating size and maintenance.
- **Latency budget for `propose_action(low)`.** ≤ 500ms round-trip including the visual flash; otherwise UAT becomes painful.
- **Latency budget for `screenshot`.** ≤ 1s round-trip on 5K display, ideally ≤ 500ms. Using ScreenCaptureKit's stream-frame API rather than full-frame capture if needed.
- **Compatibility with existing `--dangerously-skip-permissions`.** The Swift MCP server must work when the host CLI is run with that flag. Confirmation is enforced inside `propose_action`, not by Claude Code's permission system.
- **No leak of voice content.** Pixel data from screenshots stays on-device; the on-device promise from [README.md](../../README.md) extends to vision.

## Acceptance Criteria

- [ ] `swift build` succeeds with new `RelayActionsMCP` target.
- [ ] DMG built by `scripts/build-dmg.sh` contains `relay-actions-mcp` binary inside the `.app`.
- [ ] Running `relay-actions-mcp` standalone returns a valid MCP `initialize` response over stdio.
- [ ] Fresh install on a clean machine (or `RELAY_FORCE_RELOCATABLE_PYTHON=1` test path) registers the MCP server with the bundled `claude` CLI; re-running the installer does not duplicate the entry.
- [ ] All 8 MCP tools (`screenshot`, `click`, `type`, `key`, `scroll`, `frontmost_app`, `list_windows`, `propose_action`) are discoverable by `claude` and behave per Acceptance lines in Requirements §1–5.
- [ ] Voice prompt: *"Take a screenshot of the front window."* → screenshot tool fires, image returned, TTS confirms.
- [ ] Voice prompt: *"Click the Apple menu in the top-left."* → `propose_action(risk: medium)` fires, perimeter pulses, double-tap Option resolves it, `click` fires, the Apple menu opens.
- [ ] Voice prompt: *"Walk through the new checkout flow in my staging app and tell me if anything looks broken."* → multi-step screenshot/click loop, each state-changing step gated by double-tap, TTS reports findings at the end.
- [ ] Voice prompt: *"Open Apple Developer and turn off all certificate-expiry email notifications except for production."* → multi-step pixel/click flow on `developer.apple.com`, destructive toggles gated by double-tap, completes without manual intervention beyond confirmations.
- [ ] Perimeter overlay on every connected screen appears within 100ms of the first MCP tool call; pulses while `awaitingConfirmation` is set; clears within 100ms after 10s of inactivity OR `/relay-stop`.
- [ ] Click-through verified: a click anywhere on the perimeter band reaches the underlying app.
- [ ] With no confirmation pending, double-tap Option still triggers TTS playback; with confirmation pending, it resolves the prompt and does NOT trigger playback.
- [ ] Screen Recording permission flow: denying it on first run produces a clear in-app explanation, `screenshot` tool returns a descriptive error string when called, app does not crash, voice features remain functional.
- [ ] Regression: 10-prompt non-vision script shows no perimeter overlay, identical gesture behavior, end-to-end latency within ±10% of baseline.
- [ ] Confirmation timeout: no input for 30s after a `medium`/`high` `propose_action` returns `confirmed: false, reason: "timeout"`.
- [ ] DRM-protected content (e.g. a fullscreen Netflix tab) returns a descriptive error from `screenshot`, not a crash and not a black image silently.

## Risks & open questions for implementation

These are **not** spec ambiguities — they're known unknowns to flag during planning, not before:

- **Coordinate system on multi-monitor with mixed scale factors.** Screen-pixel coordinates from `screenshot` need to map cleanly to CGEvent coordinates across e.g. one Retina + one external 1× display. Need to verify ScreenCaptureKit + CGEvent agree on origin and scale.
- **Swift MCP protocol implementation.** No first-party Swift MCP SDK. Choices: vendor a small community Swift MCP package, or hand-roll the JSON-RPC-over-stdio layer (likely under 300 lines). Decide during plan-phase.
- **CGEvent posting reliability.** Some apps (e.g. games, secure input fields) reject CGEvents. Document the known restrictions; expect Apple's secure-input mode to silently drop typed text into password fields. Acceptable for v1.
- **Risk classification accuracy.** Claude classifies risk via the tool's `risk` parameter — we trust the model. If classification proves unreliable in practice (e.g. it marks a delete button as `medium`), we add a server-side keyword guard (escalates `medium` → `high` if action summary contains Delete/Send/Submit/Pay/Confirm). Treat as a v1.1 hardening if needed.
- **Bridge socket contention.** The existing `/tmp/voice_state.sock` is one-way (datagram). The confirmation flow needs request/reply. Likely a separate socket; design during plan-phase.

## Glossary

- **MCP**: Model Context Protocol — Anthropic's open standard for letting Claude clients use external tools via JSON-RPC over stdio (or other transports).
- **CGEvent**: Quartz Event Services API for posting synthetic mouse/keyboard events on macOS.
- **ScreenCaptureKit**: Apple's modern screen-capture framework (replaces deprecated CGDisplayStream).
- **AX**: Accessibility API — used for reading window structure and (optionally) UI element trees.
- **TCC**: Transparency, Consent, and Control — macOS's privacy permission database.
- **`/relay-bridge`**: Slash command (defined in [scripts/relay-bridge](../../scripts/relay-bridge)) that runs the voice bridge inside an existing Claude Code session.

---

*Spec drafted: 2026-05-03*
*Next step: Review and refine with the user, then begin implementation. No GSD discuss/plan phase scaffolding — this is a single-feature plain spec.*
