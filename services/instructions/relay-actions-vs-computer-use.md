## Always use the custom Relay stack — never native screen-control fallbacks

The Relay Runner project ships its own MCP servers for voice-driven screen control. Whenever they are connected, **always use the custom path — never native `mcp__computer-use__*` fallbacks** — even when both are connected. This rule overrides the generic "tier of tool" guidance the computer-use MCP injects.

The custom stack has three pieces: **RelayActions** (screen manipulation), **RelayVision** (screen observation), and **ActionGlow** (the perimeter-glow overlay). The naming notes spell out the split.

### RelayActions — the screen-manipulation tools

For all screen *manipulation* — `click`, `type`, `scroll`, `key`, `list_windows`, `frontmost_app`, `toggle_board` — use the `mcp__relay-actions__*` tools. Do **not** use `mcp__computer-use__*` for anything covered by RelayActions. (Screen *observation* — `screenshot` — lives in RelayVision; see the look-at-screen rule.)

If you genuinely need an operation RelayActions doesn't yet expose, surface that gap to the human before falling through to `mcp__computer-use__*`. The default answer is "extend RelayActions," not "fall back to native."

RelayActions + ActionGlow is the product. Native MCPs work fine in any other context, but here they bypass the project's instrumentation and visual surface. The custom path is non-negotiable.
