## Naming notes

- **Relay Actions** = the screen-*manipulation* feature and its MCP tool family (`mcp__relay-actions__*`): click, type, scroll, key, list_windows, frontmost_app.
- **Relay Vision** = the screen-*observation* feature and its MCP tool family (`mcp__relay-vision__*`): screenshot (initially). Split out of Relay Actions in RR-10.
- **ActionGlow** = the perimeter-glow overlay that pulses whenever a RelayActions *or* RelayVision tool runs. It is automatic — driven by the `tool_fired` notification every RelayActions and RelayVision tool sends after running — so you never call it directly. It is a **visual signal**, not a confirmation gate. (`OverlayState.actionGlow` in code.)
- Together: **the Relay stack**. Don't conflate any of these with native "computer-use" or "computer-vision" — those are different MCPs from a different vendor.
