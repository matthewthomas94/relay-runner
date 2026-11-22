# Agent presence and agent notices

Relay Runner runs up to four named foreground agents at once — Puck, Isabella, George and Sky (see [Named agents](orchestrator.md#named-agents)). All four are general sessions that can reach every registered project, so two of them can end up in the same repository. Agent presence (RR-525) records which repositories each running agent is working in and tells the other agents, one way and silently.

Two later tickets build on this unchanged: action notices between agents that share a repository (RR-526) and an enforced claim on a shared checkout (RR-527). The interfaces they reuse are listed under [Interfaces](#interfaces).

## What is recorded

For each running agent, the daemon keeps the set of repositories it is working in. An entry holds the agent, its session key, the repository path, how it was learned, when it was first and last seen, and an optional one-line note.

- **The system records presence wherever it can.** Every daemon mutation that names a repository and carries a session key updates it:

  | Activity | Request | Session key field |
  | --- | --- | --- |
  | Dispatch (`dispatch_ticket`) | `POST /v1/runs` | `dispatcher_session_key`, else `relay_session_key` |
  | Ticket id claim | `POST /v1/artifacts/tickets/claim-next-id` | `relay_session_key` (optional) |
  | Ticket write | `POST /v1/artifacts/tickets/write` | `relay_session_key` (optional) |
  | Board actions | `POST /v1/orchestrator-actions` | `relay_session_key` |
  | Session capture (`session_capture`) | `POST /v1/program/capture` | `relay_session_key` |

  A request without a session key works exactly as before and records nothing; the board UI's own ticket writes are the user's, not an agent's. The orchestrator MCP sends `RELAY_SESSION_KEY` on dispatches and captures, and the PM instructions tell an agent to add it to the ticket-writer bodies it posts.
- **Declared presence** covers what the daemon cannot see: reading or editing a repository's files directly, or research in a checkout. The agent calls `declare_repository_work` with the path and a one-line note before it starts.
- **General-tasks is never recorded.** Every agent lives there; a path inside `~/Library/Application Support/relay-runner/general-tasks` is ignored.
- **Expiry.** A repository leaves an agent's set after two hours without activity there. All of an agent's entries go when its session stops.

## Who is running

A session is running while the app keeps its spool, `/tmp/relay-sessions/<session key>/`, and its agent is the slug in that spool's `session_agent` file. This is the bridge's own liveness rule (`_session_spool_is_live`): the app creates the spool before the provider starts and removes it when the agent stops, and at launch it removes spools no live session owns. A spool recreated under the same key is a new session.

The daemon sweeps the record against the spools whenever presence is read or written and when it starts. A session whose spool is gone has stopped: its entries are removed and every other running agent receives one notice. So the entries of a session that no longer exists are gone after a daemon or app restart. The record lives in `<data root>/agent_presence.json`, rewritten atomically on each change.

## Agent notices

When a repository enters an agent's set, every other running agent gets one notice, for example:

```text
Agent notice: George started working in relay-runner (dispatched RR-530).
```

When an agent stops, the others get one notice naming the repositories it left:

```text
Agent notice: George stopped and left relay-runner, docs-site.
```

Repeated activity in a repository already in the set sends nothing. A notice for an agent that is not running is dropped, not stored for later.

Notices are **one-way and silent**. An agent never replies to, acknowledges or answers one, and nothing in this feature lets one agent start a turn in another. A notice is text for the receiving agent: it is never spoken, never passed to the messenger or the speech path, never shown to the user as a reply and never typed into a terminal by itself.

### Delivery at the receiver's next turn

The daemon queues notices per receiving session and delivers each once, at the receiver's next turn. A notice never interrupts a running turn and never wakes an idle agent. When more than ten are pending, the newest ten are delivered with a count of the rest (`- 3 older agent notices not shown.`).

| Path | How |
| --- | --- |
| Voice turn | The bridge claims the target session's notices and appends an `Agent notices` block to the first item it publishes for that turn, after the work-intent disposition and intent qualification blocks. The messenger has already been given the user's words; it never sees the block. |
| Typed turn | The prompt-submit hook (`relay-rs hook`, `UserPromptSubmit`) claims the session's notices and prints them as `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"…"}}`. A voice turn's notices were already claimed by the bridge, so the hook finds none for it. |
| Presence tools | `agent_presence` and `declare_repository_work` return the caller's undelivered notices in `notices`, `omitted_notices` and `notice_block`. |
| Session start | A starting session's instructions list the other agents' current presence (`GET /v1/agent-presence?exclude_agent=<slug>`), after the agent-notice rules. |

### Claude and Codex

Both providers get the same notices, through the same paths:

- **Claude Code** adds a `UserPromptSubmit` hook's `hookSpecificOutput.additionalContext` to the turn as context the model reads (up to 10,000 characters; [hooks reference](https://code.claude.com/docs/en/hooks)).
- **Codex** does the same for its `UserPromptSubmit` command hook, which the app registers with `-c hooks.UserPromptSubmit=…`: `additionalContext` becomes extra developer context for the turn, about 2,500 tokens by default before it is spilled to a file (source pinned at [`openai/codex@cf3ff15`](https://github.com/openai/codex/blob/cf3ff1530d821ec2d26452da4971d8e3e7d18d25/codex-rs/hooks/src/events/user_prompt_submit.rs); output schema in `codex-rs/hooks/schema/generated/user-prompt-submit.command.output.schema.json`). Its schema allows no keys beyond those the hook prints. A ten-notice block is well inside both limits.
- The orchestrator MCP identifies the caller by `RELAY_SESSION_KEY`. Claude inherits it; Codex receives it through the per-launch `mcp_servers.relay-orchestrator.env_vars` allowlist that already forwards the spool variables.
- Startup presence reaches Claude through `--append-system-prompt` and Codex through `developer_instructions`, beside the rest of the app-owned instructions.

No live Codex session was available when this shipped, so the Codex hook behaviour rests on the pinned source above; the Claude path was checked the same way against its documentation, and both are covered by the hook's unit and contract tests.

## Tools

- `declare_repository_work` — `repo_path`, `note` (one line). Declares the caller's work in a repository. Returns `declared` (`entered`, `refreshed` or `ignored` for general-tasks), every agent's presence and the caller's notices.
- `agent_presence` — no arguments. Returns all four agents: `agent`, `name`, `running`, `session_key`, `repositories` (each `repo_path`, `name`, `source`, `detail`, `note`, `first_seen`, `last_seen`, newest first) and `last_activity`, with the caller's notices.

Both identify the caller by its session key.

## Interfaces

These are the pieces RR-526 and RR-527 reuse; keep them stable.

- **Session-to-agent identity:** `Presence::live_sessions` in `rust/relay-orchestrator/src/presence.rs` — key, agent slug and spool generation of every running session.
- **Presence record:** `Daemon::note_presence(session_key, repo_path, Source, detail)` for any new attributed mutation, and `Presence::record(&Activity)` underneath; `Presence::snapshot` for reads.
- **Notice queue:** `Presence::queue_notice` (one text to every other running session) and `Presence::claim` (once, newest ten plus a count).
- **Delivery:** `POST /v1/agent-notices/claim` and its renderer, `relay_services::agent_notices::notice_block`, used by the bridge (`bridge/notices.rs`), the hook and the presence routes.

The HTTP routes are in the [orchestrator HTTP API](specs/orchestrator-http-api.md#agent-presence) and the hook's output in the [hook contract](specs/hook-contract.md).
