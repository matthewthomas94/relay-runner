---
id: RR-9
title: Rename RelayVision overlay to ActionGlow
status: in_progress
priority: medium
depends_on: []
run_id: 3
canceled: false
order: 30
---

## Description

The perimeter-glow overlay that pulses whenever any RelayActions tool fires is currently called **RelayVision** (`OverlayState.relayVision` case and `RelayVision*` Swift types in `Sources/relay-runner/Overlay/`). This sub-brand collides with the planned `mcp__relay-vision__*` namespace for screen-*observation* tools (RR-10), and it gives users the misleading intuition that "RelayVision = looking at the screen" — when in fact it's purely a visual feedback overlay tied to RelayActions.

Rename the overlay to **ActionGlow** throughout the codebase and docs. After this ticket, "RelayVision" is a free name that RR-10 will reuse for the new observation-tool family. ActionGlow makes the overlay's relationship to RelayActions obvious without introducing a third Relay-prefixed brand.

This is a pure rename: no behavior changes. The overlay still listens for the same `tool_fired` notification, pulses the same way, has the same colors and animation.

## Acceptance criteria

- Every Swift identifier `relayVision` (lowerCamelCase) renamed to `actionGlow`. Every Swift type / file / class `RelayVision*` (UpperCamelCase) renamed to `ActionGlow*`. Build clean (`swift build`) with no warnings introduced by the rename.
- `OverlayState` enum case `.relayVision` renamed to `.actionGlow`. All call sites updated.
- All files under `Sources/relay-runner/Overlay/` updated consistently: `StateMachine.swift`, `PerimeterOverlay.swift`, `PerimeterParticleField.swift`, `ActionsConfirmBus.swift`. Other Swift files that reference the symbol (`Sources/relay-runner/App/AppState.swift`, `Sources/relay-actions-mcp/ProposeActionTool.swift`) updated.
- Docs updated:
  - `CLAUDE.md` — "### 2. RelayVision — the perimeter-glow overlay" section retitled to "### 2. ActionGlow — the perimeter-glow overlay". Body rewritten to use ActionGlow consistently. "Naming notes" section updated (RelayVision bullet → ActionGlow bullet).
  - `AGENTS.md` — all RelayVision references → ActionGlow.
  - `docs/specs/relay-actions.md` — all RelayVision references → ActionGlow.
- Manual verification: with the app running, calling any relay-actions tool (e.g. `screenshot`) still triggers the perimeter pulse — identical visual behavior to before the rename.
- No regression in `PerimeterOverlay` or `PerimeterParticleField` animation, colors, or timing.
- Don't touch the bundled `.app`'s scripts — DMG-build action is the source of truth (per `CLAUDE.md`).
- Commit message references RR-9.

## Notes

- Be careful with case-sensitive global replace: do `RelayVision` → `ActionGlow` *and* `relayVision` → `actionGlow` as separate passes. Don't blindly s/// the lowercase string `relayvision` since some compound identifiers may not exist.
- `.orchestrator/RR-8.md` mentions RelayVision in its description and acceptance criteria. Leave it alone — that's frozen prose about the prior naming.
- `.orchestrator/RR-10.md` (vision split) depends on this ticket completing first, so the auto-promotion will dispatch it after RR-9 lands.
