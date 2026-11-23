# Agent presence and agent notices

Relay Runner runs up to four named foreground agents at once — Puck, Isabella, George and Sky (see [Named agents](orchestrator.md#named-agents)). All four are general sessions that can reach every registered project, so two of them can end up in the same repository. Agent presence (RR-525) records which repositories each running agent is working in and tells the other agents, one way and silently.

Two later tickets build on this: overlap and action notices between agents that share a repository (RR-526, [Sharing a repository](#sharing-a-repository)) and an enforced claim on a shared checkout (RR-527, [Checkout claims](#checkout-claims)). The interfaces they reuse are listed under [Interfaces](#interfaces).

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

## Sharing a repository

Most work happens in one repository, so two agents in the same one is the normal case. Two running agents **overlap** on a repository while it is in both their presence sets. While they overlap, each hears what the other does there that could collide, so they neither duplicate nor undo each other's work. The notices are tied to actions, never sent on a timer, and stay one-way, silent and delivered at the receiver's next turn like every other agent notice.

### Overlap notices

When a repository enters a second agent's set, each of the two gets one notice naming the other and what is known of its work there: its declared note and the tickets it wrote or dispatched there in this session (else what it was doing). The agents not in the repository get the ordinary started notice.

```text
Agent notice: George started working in relay-runner, where you are working too (tickets: RR-602).
Agent notice: Puck is also working in relay-runner (note: reviewing the hook; tickets: RR-600, RR-601).
```

When the overlap ends the other agent gets one notice:

```text
Agent notice: George stopped and left relay-runner. You no longer share relay-runner with George.
Agent notice: George has had no activity in relay-runner for two hours, so you no longer share it.
```

### Action notices

While they overlap, the daemon tells the other agents sharing the repository about these actions. They come from daemon events and need nothing from the agent that acted; an agent with no overlap in the repository gets none of them, and the acting agent never hears its own.

| Action | Learned from | Notice |
| --- | --- | --- |
| Ticket created | `/v1/artifacts/tickets/write` (a new ticket), a `create_ticket` board action | `George created ticket RR-610 "Bridge fix" in relay-runner.` |
| Ticket edited | `/v1/artifacts/tickets/write` (an existing ticket), `edit_ticket` / `update_dependencies` board actions | `George edited ticket RR-610 "Bridge fix" in relay-runner.` |
| Ticket dispatched or queued | `POST /v1/runs`, a `request_worker` board action | `George dispatched RR-610 in relay-runner.` / `George queued RR-611 in relay-runner to start when its dependencies are done.` |
| Run merged or failed | the run's `run-merged`, `run-verification-blocked` or `run-failed` lifecycle event, for a run whose dispatcher was bound by `dispatcher_session_key` | `George's run of RR-610 in relay-runner merged into the checkout.` |
| Declared direct work | `declare_repository_work` | `George declared direct work in relay-runner: fixing the bridge prompt (paths: rust/relay-rs/src/bridge/relay.rs).` |

A merge matters to the others because it changes the shared branch. A replayed ticket write and a dispatch of an already-active run send nothing. A run's merge notice needs the dispatcher's entry in the repository: once it has expired the agents no longer overlap.

### Declared direct work

`declare_repository_work` takes an optional `paths` list beside its one-line `note`: what the agent is about to change directly in the checkout. The other agents sharing the repository receive it as a notice, and the tool's result returns the caller's own undelivered notices, so an agent learns of a collision at the moment it declares.

### Batching

All of one receiver's notices are delivered together in one block at its next turn. Several edits of the same ticket by the same agent between two deliveries collapse into one line that names the latest title and the count (`… (3 edits).`). RR-525's limits stand: the newest ten notices are delivered with a count of the rest, and at most a hundred wait per receiver.

### What an agent does while sharing a repository

The PM instructions for both providers (the generated instructions and the app-owned startup instructions) add three rules while an agent shares a repository: declare direct work there, with its paths, before starting it; before creating a ticket there, check the other agent's recent tickets (its notices or `agent_presence`, whose repositories list their `tickets`) for the same work; and when a notice shows the same work or the same files, stop that piece of work, tell the user which agent has it and ask what to do. An agent never negotiates with or messages the other agent.

### Providers

Overlap and action notices use RR-525's queue and delivery unchanged, so both providers receive them through the same voice-prompt, prompt-submit-hook and presence-tool paths. No provider lacks a mechanism here. No live Codex session was available for RR-526; its path rests on the shared daemon and hook tests.

## Tools

- `declare_repository_work` — `repo_path`, `note` (one line), optional `paths` (RR-526). Declares the caller's work in a repository; the agents sharing it get the declaration as a notice. Returns `declared` (`entered`, `refreshed` or `ignored` for general-tasks), every agent's presence and the caller's notices.
- `agent_presence` — no arguments. Returns all four agents: `agent`, `name`, `running`, `session_key`, `repositories` (each `repo_path`, `name`, `source`, `detail`, `note`, `tickets`, `first_seen`, `last_seen`, newest first) and `last_activity`, with the caller's notices.

Both identify the caller by its session key.

## Checkout claims

Presence and notices are advice. The checkout claim (RR-527) is the one hard rule: one agent at a time edits files, switches branches or releases in a registered project's checkout, and a second agent is refused and told who holds it. Worker runs are unaffected; each has its own worktree.

### The claim

- **At most one holder per checkout.** A claim records the agent, its session key, the checkout, a one-line purpose and the time of the holder's last write. It lives in the presence record (`agent_presence.json`, `claims`).
- **Taken by writing.** An agent does not have to remember to claim: its first write to a free checkout takes the claim with the write as its purpose (for example `Edit README.md` or `git commit`), and each further write refreshes it. `claim_checkout` takes it explicitly with a purpose, for example before cutting a release, and refreshes it with a new purpose when the caller already holds it.
- **Released** by `release_checkout` (only by its holder), when the holder's session stops (its spool goes, in the presence sweep), and after 30 minutes without a write by the holder.
- **What is claimable.** The checkout is the longest registered repository containing the path. The built-in general-tasks project is never claimable, nor are the daemon's worker workspaces and data root, nor a Claude Code worktree under `.claude/worktrees`. A path outside every registered repository is not enforced.
- **Notices.** Taking and releasing a claim queues one agent notice for every other running agent, for example `Agent notice: Puck took the checkout claim on relay-runner (cutting release v0.7.7); …` and `Agent notice: Puck released the checkout claim on relay-runner (30 minutes without a write).` Claims appear in `agent_presence` (`checkout_claims`), in `checkout_claims`, and in a starting session's startup presence.

### What is enforced

The provider's pre-tool hook (`relay-rs hook` on `PreToolUse`; see the [hook contract](specs/hook-contract.md#the-checkout-claim-before-a-tool-call)) checks the claim before a foreground agent's tool call changes a checkout, and denies the call with the holder's name, purpose and last write and the rule below when another agent holds it:

- **File-writing tools** whose target is inside the checkout: Claude Code's `Write`, `Edit`, `MultiEdit` and `NotebookEdit`; Codex's `apply_patch` (every file its patch adds, updates, deletes or moves to).
- **Shell commands** that change the checkout's git state or its remote, run from inside it, after `cd`, or with `git -C`: `git checkout`, `switch`, `commit`, `merge`, `rebase`, `reset`, `stash`, `cherry-pick`, `revert`, `pull`, `push` and `tag`; `gh release create|edit|delete|upload` and `gh workflow run`; and the project's release scripts (`scripts/build-dmg.sh`, `scripts/generate-appcast.sh`, any `release*` script).

Read-only commands are never refused (`git status`, `git log`, `git diff`, `git stash list`, `git tag -l`, `--dry-run`, …), and neither are reads, searches, tests and builds, ticket writes through the daemon or dispatching. A call that changes none of the above never contacts the daemon, and a daemon that does not answer allows the call.

**Not enforced.** Shell parsing is by name, not a full shell: a git command inside `$(…)` or backticks, `eval`, an alias or shell function, a script that runs git itself, and shell file writes (`>` redirection, `sed -i`, `rm`, `mv`, `cp`, `tee`) are not seen. The PM instructions therefore tell an agent to claim the checkout before changing it any other way. **Known gap:** the daemon's own merges of reviewed worker branches into a checkout neither take nor respect a claim, so a merge can land in a checkout another agent holds.

### The rule for a refused agent

A refused call means another agent holds the checkout. The agent must not work around it: no writing through another tool or the shell, no copying the checkout, no waiting or retrying in a loop. It tells the user which agent holds the claim and why, and asks how to proceed. Both providers' instructions carry this rule (the generated orchestrator rules, the compact Claude Code payload and the app-owned session instructions).

### Claude and Codex

Both providers enforce the claim the same way. Claude Code's `PreToolUse` hook is registered in the app's `--settings` JSON; Codex's with `-c hooks.PreToolUse=[{ matcher = "Bash|apply_patch", … }]` beside its other hooks. Codex's pinned source ([`openai/codex@cf3ff15`](https://github.com/openai/codex/blob/cf3ff1530d821ec2d26452da4971d8e3e7d18d25/codex-rs/hooks/src/events/pre_tool_use.rs)) runs a `PreToolUse` command hook before its shell (`exec_command`, reported as `Bash` with `{"command"}` and the command's working directory as `cwd`) and before `apply_patch` (`{"command": <patch>}`, also matched by `Write|Edit`), and blocks the call on `permissionDecision: "deny"` with a non-empty `permissionDecisionReason` (output schema `codex-rs/hooks/schema/generated/pre-tool-use.command.output.schema.json`), the same output Claude Code reads. Codex rejects a bare `allow`, so an allowed call prints nothing for both. No live Codex session was available when this shipped, so the Codex path rests on that source and the hook's tests; the Claude path was checked against its hooks documentation.

### Tools

- `claim_checkout` — `repo_path`, `purpose` (one line). Takes or refreshes the caller's claim; fails naming the holder when another agent holds it.
- `release_checkout` — optional `repo_path`; without it, releases every claim the caller holds.
- `checkout_claims` — no arguments. Every current claim.

The routes are in the [orchestrator HTTP API](specs/orchestrator-http-api.md#checkout-claims).

## Interfaces

These are the pieces RR-526 and RR-527 build on; keep them stable.

- **Session-to-agent identity:** `Presence::live_sessions` in `rust/relay-orchestrator/src/presence.rs` — key, agent slug and spool generation of every running session.
- **Presence record:** `Daemon::note_presence(session_key, repo_path, Source, detail)` for any new attributed mutation, and `Presence::record(&Activity)` underneath; `Presence::snapshot` for reads.
- **Notice queue:** `Presence::queue_for` (one text to one receiving session, optionally collapsing by key) and `Presence::claim` (once, newest ten plus a count).
- **Action notices (RR-526):** `Daemon::note_action(session_key, repo_path, Source, detail, &Action)` records presence and tells the overlapping agents; `Presence::notify_action` tells them without recording, for daemon events such as `Daemon::note_run_ended`.
- **Delivery:** `POST /v1/agent-notices/claim` and its renderer, `relay_services::agent_notices::notice_block`, used by the bridge (`bridge/notices.rs`), the hook and the presence routes.

The HTTP routes are in the [orchestrator HTTP API](specs/orchestrator-http-api.md#agent-presence) and the hook's output in the [hook contract](specs/hook-contract.md).
