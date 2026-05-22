# Relay Runner Orchestrator

Symphony-style sub-agent orchestrator. Dispatches tickets from a repo's local kanban board (`<repo>/.orchestrator/<TICKET_ID>.md`) to autonomous `claude` runs in isolated git worktrees, and tracks state in SQLite. Modeled on [openai/symphony](https://github.com/openai/symphony) — the daemon owns "is this ticket claimed / running / done", and each sub-agent owns its own context window for the duration of one run.

The repo is the source of truth: tickets are version-controlled markdown files, the sub-agent edits its ticket's YAML frontmatter and appends a `## Run log` section when it finishes, and everything (code + ticket update) is committed to the worker's branch.

## Quick start

After installing Relay Runner, the bootstrap also sets up the orchestrator (skills, MCP server, launchd plist). To check:

```bash
scripts/relay-orchestrator --status
```

You should see a running daemon, a port file, and an installed plist.

### 1. Write a ticket

Open the menu-bar Board (`⌃⌥` to toggle) and create a ticket via the column's `+` button. The board writes the file to `<repo>/.orchestrator/<TICKET_ID>.md` and bumps `<repo>/.orchestrator/config.toml`'s `next_id`. Commit both to the working branch — that's the ticket's audit trail going forward.

You can also create the file by hand. The schema is in [docs/specs/orchestrator-tickets.md](specs/orchestrator-tickets.md).

### 2. Promote to `ready` — the board auto-dispatches

Drag the card from `backlog` to `ready` in the menu-bar Board. The moment it lands in the `ready` column, the board calls `mcp__relay-orchestrator__dispatch_ticket(ticket_id, repo_path)` for you — there's no separate "press go" step. This also fires for tickets created directly in the `ready` column (after you fill in the editor and save).

Manual dispatch is still available for edge cases — retries, dispatching out-of-order, or driving from voice without using the board. Either way Claude calls the same MCP tool:

```
/relay-dispatch work on RR-6
```

The daemon:

1. Validates `<repo>/.orchestrator/RR-6.md` exists.
2. Adds a git worktree at `~/Library/Application Support/relay-runner/workspaces/rr-6/` on branch `relay/rr-6`, branched off the repo's default branch (resolved via `git symbolic-ref refs/remotes/origin/HEAD`, falling back to `main`).
3. Renders the workflow prompt (default at `services/orchestrator_workflow.md`, override per-repo at `<repo>/WORKFLOW.md`).
4. Spawns `claude --dangerously-skip-permissions` in that worktree, piping the prompt as stdin.
5. Returns a `run_id` immediately — the worker continues in the background.

The worker reads the ticket file, flips its status to `in_progress`, implements the change, commits the code with a conventional commit referencing the ticket, then flips the ticket's status to `done` (or leaves it `in_progress` if partial) and appends a `## Run log` section before exiting. Both edits land on the worker's branch.

### 3. Check status / cancel

```
list_runs                          → all recent runs, newest first
list_runs --state=Running          → only active ones
get_run --run_id=17                → details for one run
cancel_run --run_id=17             → SIGTERM the worker, prune the worktree
```

Voice equivalents work too: "what are the agents doing?", "how's RR-6?", "stop RR-6".

## The intended workflow

The orchestrator is designed around a four-step loop. The main Claude Code session is the *orchestrator* — it's the one talking to you and routing work — and each `claude` worker is a one-shot *sub-agent*.

1. **Discuss.** You and the main session talk through what needs to happen. Voice via `/relay-bridge`, or just typed chat. The main session has full context of the conversation, the codebase, and the project state.
2. **Write tickets in `backlog`.** When the discussion settles on concrete work, the main session creates a ticket file under `<repo>/.orchestrator/` — title, description with acceptance criteria, priority, `depends_on` if it needs another ticket to land first. Default `status: backlog`. Each ticket should be small enough that a sub-agent can complete it in one pass without further clarification. Commit the new ticket (and the `next_id` bump) to the working branch.
3. **Promote to `ready` — dispatch fires automatically.** When a ticket is refined enough, drag it from `backlog` to `ready` in the board. The moment it lands, the board calls `dispatch_ticket(ticket_id, repo_path)`; a worker spawns in an isolated worktree. For a chain (tickets with `depends_on`), promote only the first one — when each predecessor lands in `done`, the daemon auto-flips its dependents from `backlog` to `ready` and dispatches them. Multiple dispatches in parallel are supported (no concurrency cap by design — bound by your Anthropic rate limit). For one-off out-of-band dispatches, the MCP tool `mcp__relay-orchestrator__dispatch_ticket` is still callable directly; pass `context="..."` when there's relevant background that doesn't fit cleanly in the ticket body.
4. **Integrate.** Each sub-agent commits to its `relay/<id>` branch — both the code change and the ticket-file update. The main session merges those branches into the working branch (resolving conflicts when sub-agents touched overlapping code), then prunes the worktree + branch. The merge publishes the `done` status to the board, which is what unblocks any dependents and triggers their auto-promotion.

The main session is *not* a passive router. It's the same session that holds the discussion, so it owns: drafting ticket acceptance criteria, deciding which tickets to promote in parallel, picking the merge order when conflicts are likely, and reviewing the sub-agents' work for quality.

There's no scheduler picking tickets off the backlog on its own — the user (or the dependency chain) controls what becomes `ready`. Once it's `ready`, the worker is on its way.

## What the worker is allowed to do

The default `WORKFLOW.md` constrains the worker to:

- **Read** anything in the worktree.
- **Write** anything in the worktree.
- **Commit** to the local `relay/<id>` branch — never `main`, never the repo's primary working copy.
- **Edit** its own ticket file (`.orchestrator/<ticket_id>.md`) — never other tickets, never `.orchestrator/config.toml`.
- **Not push.** The branch stays local; a human reviews the worktree and decides.

The worktree is isolated: changes don't leak into the repo's primary working copy or any other worktrees. Because the worker runs with `--dangerously-skip-permissions`, it can `rm -rf` everything in the worktree if instructed to — that's why the branch is local-only and the worktree is throwaway.

## Customizing the workflow per repo

Drop a `WORKFLOW.md` at the repo's root and the worker uses that instead of the default. Template variables: `{{ticket_id}}`, `{{repo_path}}`, `{{branch}}`, `{{attempt}}`, `{{run_id}}`, `{{caller_context}}`. The default template at [services/orchestrator_workflow.md](../services/orchestrator_workflow.md) is the starting point.

A repo's `WORKFLOW.md` is a fine place to encode project conventions: which test command to run, which directories are off-limits, what a "done" run log entry should include, etc.

## How tickets persist

Tickets live as version-controlled markdown under `<repo>/.orchestrator/`. The daemon never writes there itself; reads/writes happen via the board UI (in the menu-bar app) and the sub-agent (during a run). That means:

- The audit trail is `git log <repo>/.orchestrator/<ticket_id>.md`. Free, attributable, full diffs.
- Cloning the repo brings the board state with it.
- No external service, no auth, no schema-migration story across machines.

The full file format is documented at [docs/specs/orchestrator-tickets.md](specs/orchestrator-tickets.md).

## Files and locations

| Path | Purpose |
|---|---|
| `services/orchestrator.py` | The daemon (HTTP server + SQLite + worker spawn) |
| `services/orchestrator_workflow.md` | Default workflow template |
| `Sources/relay-orchestrator-mcp/` | Swift MCP proxy (HTTP → MCP tools) |
| `scripts/relay-orchestrator` | Launcher / installer |
| `<repo>/.orchestrator/<TICKET_ID>.md` | One ticket per file (board source of truth) |
| `<repo>/.orchestrator/config.toml` | Repo-scoped ticket counter (`prefix`, `next_id`) |
| `~/Library/Application Support/relay-runner/orchestrator/runs.db` | Run history (SQLite) |
| `~/Library/Application Support/relay-runner/workspaces/<sanitized-id>/` | Per-ticket worktree |
| `~/Library/Application Support/relay-runner/workspaces/<sanitized-id>/.relay/run.log` | Worker stdout (full session trace) |
| `~/Library/LaunchAgents/com.relay.orchestrator.plist` | launchd descriptor |
| `/tmp/relay_orchestrator.port` | Port the daemon bound to |
| `/tmp/relay_orchestrator.log` / `.err` | Daemon stdout / stderr |

## Troubleshooting

**MCP tools missing in Claude Code.** Confirm the registration:
```bash
claude mcp list | grep relay-orchestrator
```
Re-run if absent: `scripts/relay-orchestrator --install`.

**Tools error with "Orchestrator daemon is not reachable".** The daemon isn't running. Check:
```bash
scripts/relay-orchestrator --status
launchctl print "gui/$(id -u)/com.relay.orchestrator"   # detailed launchd state
tail /tmp/relay_orchestrator.err
```
Restart with `scripts/relay-orchestrator --start`.

**Worker hangs.** Cancel and inspect:
```
cancel_run --run_id=N --prune_worktree=false
```
Then read `<workspace>/.relay/run.log`. The default timeout is 30 minutes; tune via `[orchestrator].worker_timeout_seconds` in `config.toml`.

**Dispatch fails with "ticket not found".** The orchestrator requires `<repo>/.orchestrator/<ticket_id>.md` to exist before dispatching. Either create the ticket via the board UI (or by hand following [the spec](specs/orchestrator-tickets.md)) and commit it, or fix the `ticket_id` argument if it was a typo.

**Worktree branch already exists.** `cancel_run` with `prune_worktree=true` (the default) deletes the local `relay/<id>` ref after pruning, and `dispatch_ticket` recovers from a stale ref by deleting and recreating off the repo's current default branch. If you hit a leftover ref from before this fix, run `git -C <repo> worktree prune` and `git -C <repo> branch -D relay/<id>` once.

## Limits (MVP)

- No retry / backoff — failed runs stay failed; redispatch manually.
- No cross-machine orchestration.
- No PR opening — worktree is left for human review.
- Concurrency is uncapped at the daemon level (workers all spawn in parallel); rate-limiting against Anthropic happens at their tier. Add a `max_concurrent` config knob if you need to clamp.
