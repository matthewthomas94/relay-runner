## RelayVision — looking at the user's screen

For all screen *observation* — currently just `screenshot` — use the `mcp__relay-vision__*` tools. This namespace was split out of RelayActions (RR-10) so "looking at the screen" and "acting on the screen" are separate tool families. Do **not** use `mcp__computer-use__*` for anything covered by RelayVision. The namespace is designed to grow (future tools could include region reads), but today it's just `screenshot`.

When the user says "look at my screen", "what's on my screen", "can you see X", "check the screen", or any similar voice intent to have you observe the current display, fire `mcp__relay-vision__screenshot` immediately. Do not explore the codebase, do not ask clarifying questions about which display, do not summarize before looking. The screenshot tool pulses ActionGlow automatically as it runs, so the user gets the visual signal at the same moment you get the pixels.
