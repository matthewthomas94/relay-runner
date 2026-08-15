# RR-326 MCP lifecycle compatibility probe

## Decision

**Stay on the legacy `2024-11-05` lifecycle.** Do not advertise `2026-07-28` and do not change production adapter behavior in this release.

The three adapters can parse a direct request carrying 2026 metadata, but they do
not validate that metadata or implement the new lifecycle. Treating that
accidental tolerance as compatibility would cause a new client to believe it
negotiated a protocol the server cannot actually provide. A dual-speaking
migration is appropriate only after a shared protocol layer can preserve the
legacy handshake while adding the stateless surface behind an explicit switch.

## Reproducible probe

Build the helpers and exercise their stdout JSON-RPC boundary:

```sh
swift build --product relay-actions-mcp
swift build --product relay-vision-mcp
swift build --product relay-orchestrator-mcp
BIN_DIR="$(swift build --show-bin-path)"
python3 scripts/mcp-lifecycle-probe.py --bin-dir "$BIN_DIR"
python3 -m unittest tests/test_mcp_lifecycle_probe.py
```

The probe starts each helper without calling an app-hosted tool and checks:

- legacy `initialize` / `notifications/initialized` and `tools/list`;
- direct metadata-bearing `tools/list` without initialization;
- `server/discover`, including the new per-request metadata shape;
- a synthetic request handle carried in `_meta`;
- `notifications/cancelled`, followed by a normal request; and
- a malformed `tools/call` error.

To inspect the installed registration and helpers instead of the build output:

```sh
codex --version
claude --version
codex mcp list
claude mcp list
python3 scripts/mcp-lifecycle-probe.py \
  --bin-dir '/Applications/Relay Runner.app/Contents/MacOS'
```

Expected legacy results are `2024-11-05` from `initialize`, `-32601` for
`server/discover`, no response to cancellation, `-32602` for a missing tool
name, and no returned `_meta` or explicit application-handle surface.

## Evidence recorded 2026-08-15

| Adapter | Legacy initialization | Direct 2026 metadata request | Discovery | Handle and cancellation |
| --- | --- | --- | --- | --- |
| Relay Actions | Accepted `2024-11-05` | Accepted as an unvalidated legacy request | `-32601` | Handle ignored; cancellation notification is a no-op |
| Relay Vision | Accepted `2024-11-05` | Accepted as an unvalidated legacy request | `-32601` | Handle ignored; cancellation notification is a no-op |
| Relay Orchestrator | Accepted `2024-11-05` | Accepted as an unvalidated legacy request | `-32601` | Handle ignored; cancellation notification is a no-op |

The source-built helpers and the installed helpers produced the same matrix.
Each still responds to the malformed `tools/call` with `-32602`.

Installed client observations:

| Client | Version | Registration/health probe | Negotiated capability evidence |
| --- | --- | --- | --- |
| Codex | `codex-cli 0.145.0` | `codex mcp list` exits 0 and lists all three Relay helpers. | The CLI exposes registration only; it does not display a live health check, selected protocol revision, or negotiated capabilities. |
| Claude Code | `2.1.220` | `claude mcp list` exits 0 and reports all three Relay helpers `Connected`. | The health check output does not display a selected protocol revision or negotiated capabilities. |

The direct helper fixtures are therefore the wire-level compatibility evidence;
the installed-client commands establish that both supported providers still use
the registered legacy helpers. Neither command supports a claim that the client
negotiated `2026-07-28`.

## Protocol boundary and risks

MCP `2026-07-28` makes requests self-describing: the protocol version, client
identity, and client capabilities are supplied on every request in `_meta`.
It removes the initialization lifecycle, makes `server/discover` mandatory,
and requires application state spanning requests to use explicit handles. On
stdio, cancellation remains a `notifications/cancelled` message referencing an
in-flight request and the server should stop work without emitting a later
response. The current helpers implement none of those lifecycle guarantees.

This is intentionally separate from Relay voice delivery. Voice turns travel
through the bridge, durable inbox, provider-turn lifecycle records, and the
embedded terminal. The persistent Messenger runs with MCP disabled. A stateless
MCP adapter can improve tool reconnects, request correlation, and explicit app
handles, but cannot safely inject an unsolicited voice turn or resolve the
foreground ownership issue by itself.

Relevant primary references:

- [MCP 2026-07-28 base protocol](https://modelcontextprotocol.io/specification/2026-07-28/basic)
- [MCP 2026-07-28 announcement](https://blog.modelcontextprotocol.io/posts/2026-07-28/)
- [SEP-2575: Make MCP Stateless](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/seps/2575-stateless-mcp.md)

## Migration gate and rollback

Before dual-speaking, add a shared adapter protocol layer and demonstrate with
mounted Codex and Claude sessions that it:

1. answers legacy `initialize` for existing clients and `server/discover` for
   new clients;
2. validates per-request `_meta`, emits supported-version errors, and returns
   response metadata without inferring identity from the stdio process;
3. passes explicit application handles only to adapters that actually own
   cross-request work, and implements cancellation for cancellable work; and
4. records the selected path without prompts, transcripts, credentials, or
   filesystem paths.

Roll out one adapter at a time behind an explicit legacy/default switch. A
rollback returns that adapter to the existing legacy path while preserving
request diagnostics; it must not clear voice-delivery, provider-turn, or
application state. Do not couple this migration to the urgent voice ownership
repair from RR-321.

## Scope

RR-326 adds only the probe fixture, its test, and this report. No production
MCP adapter, registration command, voice transport, or app-hosted tool behavior
changed.
