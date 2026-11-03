## Naming notes

- **Relay Desktop** = the *accessibility-tree* feature and its MCP tool family (`mcp__relay-desktop__*`): snapshot, find, act, press, get, wait, list_apps, list_windows, focus_window, launch, status. Backed by the bundled agent-desktop CLI, run inside Relay Runner.app.
- **Relay Actions** = the *physical* screen-manipulation feature and its MCP tool family (`mcp__relay-actions__*`): click, type, scroll, key, list_windows, frontmost_app.
- **Relay Vision** = the screen-*observation* feature and its MCP tool family (`mcp__relay-vision__*`): screenshot, record. Split out of Relay Actions in RR-10.
- **ActionGlow** = the perimeter-glow overlay that pulses whenever a RelayDesktop, RelayActions *or* RelayVision tool runs. It is automatic — driven by the `tool_fired` notification every RelayDesktop, RelayActions and RelayVision tool sends after running — so you never call it directly. It is a **visual signal**, not a confirmation gate. (`OverlayState.actionGlow` in code.)
- Together: **the Relay stack**. Don't conflate any of these with native "computer-use" or "computer-vision" — those are different MCPs from a different vendor.
