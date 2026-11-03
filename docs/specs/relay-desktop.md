# Relay Desktop

**Status:** Implemented

Relay Desktop is Relay Runner's accessibility-tree MCP service. It lets the active Codex or Claude session read what an app's window contains and operate its controls through macOS accessibility, so most desktop work needs neither a [Relay Vision](relay-vision.md) screenshot nor a [Relay Actions](relay-actions.md) coordinate click. It is backed by the [vercel-labs/agent-desktop](https://github.com/vercel-labs/agent-desktop) CLI (Apache License 2.0), which Relay Runner bundles at a pinned release.

## Capability

The `relay-desktop-mcp` server exposes these tools. Each one maps to one `agent-desktop` command and returns the CLI's JSON envelope verbatim: `ok`, then `data` or an `error` with a `code`, a `disposition` (`delivery` and `retry`) and usually a `suggestion`.

| Tool | agent-desktop command | Purpose |
| --- | --- | --- |
| `snapshot(app?, window_id?, root?, surface?, skeleton?, interactive_only?, compact?, max_depth?, include_bounds?, timeout_ms?)` | `snapshot` | The app's accessibility tree with a ref (`@<snapshot_id>:eN`) for every element that can be acted on. Interactive-only and compacted by default; `skeleton` maps a dense app, `root` drills into one region, `surface` reads an open menu, sheet, alert or popover. |
| `find(app?, window_id?, root?, surface?, role?, name?, text?, value?, description?, exact?, first?, limit?, timeout_ms?)` | `find` | Elements matching a role, name, text, value or description, with refs. |
| `act(action, ref, text?, direction?, amount?, wait_for?, wait_for_gone?, wait_timeout_ms?, timeout_ms?)` | `click`, `right-click`, `type`, `set-value`, `clear`, `focus`, `select`, `toggle`, `check`, `uncheck`, `expand`, `collapse`, `scroll`, `scroll-to` | A headless semantic action on a ref. |
| `press(combo, app?, window_id?, wait_for?, wait_for_gone?, wait_timeout_ms?)` | `press` | A keyboard shortcut delivered to an app without focusing it. Quit shortcuts are refused. |
| `get(ref, property?)` | `get`, `is` | One property (`text`, `value`, `title`, `bounds`, `role`, `states`) or one state (`visible`, `enabled`, `checked`, `focused`, `expanded`, `selected`). |
| `wait(ms?, app?, text?, window?, element?, predicate?, value?, event?, menu?, menu_closed?, timeout_ms?)` | `wait` | Blocks on a condition instead of a fixed sleep. |
| `list_apps(app?)`, `list_windows(app?)` | `list-apps`, `list-windows` | Running GUI apps and visible windows with ids. |
| `focus_window(window_id? \| app? \| title?)` | `focus-window` | Brings a window forward and confirms focus. |
| `launch(app, activate?, timeout_ms?)` | `launch` | Launches or attaches to an app by display name or bundle id. |
| `status()` | `status` | Bundled version, platform, permission state and supported surfaces. |
| `get_relay_instructions()` | — | The full Relay Desktop rules (read-only). |

Refs belong to the snapshot that produced them. After any UI change the agent snapshots again; `STALE_REF` and `AMBIGUOUS_TARGET` errors say so explicitly. Action results carry `disposition.retry`; the rules tell the agent to repeat an action only when it is `safe`, and otherwise to observe the live state first, because a repeat can click, type or submit twice.

The behavioral rules shipped with the server (`services/instructions/desktop-accessibility-first.md`) make Relay Desktop the first read for text, control state, forms and dialogs, and reserve Relay Vision for pixels (rendering, layout, images, canvas, video, or a request to *see* the screen) and Relay Actions for physical input the user asked for.

## Headless policy

Relay Desktop runs agent-desktop in its default headless mode only: ref actions go through semantic accessibility calls and do not move the pointer, take focus, synthesize keys or use the clipboard. Relay Runner.app refuses any request outside this policy before it runs, independently of what the MCP helper sends:

- Only observation, ref-action, keyboard, app/window, wait and status subcommands are accepted. Raw mouse input, double-click, hover, drag, screenshot, clipboard, session, trace and cursor-overlay commands are not exposed.
- `--headed`, `--force`, `--screenshot`, `--debug`, `--trace`, `--trace-strict`, `--session` and `--agent-id` are refused, so dangerous shortcuts such as `cmd+q` stay blocked and no local debug artefacts are written.
- A single request is at most 6 KB (Relay Runner's socket reads one 8 KB line); long text is split across calls.

Relay Actions remains the path for double-click, hover, drag and coordinate input, and Relay Vision for pixels.

## Permission and process boundary

The MCP executable forwards each argv through the local `/tmp/relay_actions.sock` listener to Relay Runner.app, which validates it and runs the bundled `agent-desktop` binary as its own child process. macOS therefore attributes the CLI's Accessibility check to **Relay Runner**, not to Codex, Claude, Terminal, or an editor, and the one Accessibility grant that already hosts Relay Actions covers Relay Desktop. Nothing in Relay Desktop needs Screen Recording.

If Accessibility is absent, Relay Runner requests the grant and returns the same recovery instructions as Relay Actions. The app stops a command that outlives its timeout (60 s by default, extended for explicit waits, at most 180 s) and reports that a wait or action may already have been delivered. Output above 16 MB is refused with advice to narrow the snapshot.

A snapshot is local until the tool is invoked. Its text result is returned to the requesting Codex or Claude session and can therefore reach that provider, and it can contain private text from the user's apps, exactly like a screenshot. Agents read only the app and region the request needs. So that refs resolve across separate CLI processes, agent-desktop keeps its recent snapshot ref maps under `~/.agent-desktop/` (owner-only permissions); those files can contain element names from snapshotted apps and are not uploaded by Relay Runner.

## ActionGlow

Every successful Relay Desktop call sends the same local `tool_fired` notification as Relay Actions and Relay Vision, so ActionGlow pulses around the screen edge. `get_relay_instructions` only reads rules and does not glow. The glow is a visible signal that observation or action occurred, not a confirmation gate.

## Registration and packaging

`scripts/relay-bridge` idempotently registers the bundled `relay-desktop-mcp` binary with every available supported provider, beside Relay Actions and Relay Vision. `scripts/build-dmg.sh` builds, embeds and signs the helper, and `scripts/fetch-agent-desktop.sh` downloads the pinned agent-desktop release for the host architecture, verifies the archive and its Apache-2.0 LICENSE against SHA-256 pins before extracting anything, and caches the result under `.build/agent-desktop/`. The `agent-desktop` CLI and its `agent-desktop-macos-helper` ship in `Contents/MacOS` beside the Relay helpers, re-signed with the release Developer ID and hardened runtime so the bundle notarises; the license ships in `Contents/Resources/ThirdPartyLicenses/agent-desktop.txt`.

Upgrading agent-desktop means changing the version and the three checksums in `scripts/fetch-agent-desktop.sh` and re-checking the tool list against the CLI's `--help`.

Codex and Claude receive the same tools, schemas, headless policy, app-hosted permission ownership, errors and ActionGlow behavior. Provider differences are limited to MCP registration commands and to Claude Code receiving the compact initialize instructions plus `get_relay_instructions`, while other clients receive the full rules at initialize.

Headed (physical) delivery, double-click, hover, drag, clipboard access, window screenshots through agent-desktop, agent-desktop sessions and traces, Windows and Linux are not current capabilities.
