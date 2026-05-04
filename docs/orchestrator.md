# Relay Runner Orchestrator

Symphony-style sub-agent orchestrator. Links Linear projects to local git repos, dispatches Linear issues to autonomous `claude -p` runs in isolated git worktrees, and tracks state in SQLite. Modeled on [openai/symphony](https://github.com/openai/symphony) — the daemon owns "is this issue claimed / running / done", and each sub-agent owns its own context window for the duration of one run.

## Quick start

After installing Relay Runner, the bootstrap also sets up the orchestrator (skills, MCP server, launchd plist). To check:

```bash
scripts/relay-orchestrator --status
```

You should see a running daemon, a port file, and an installed plist.

### 1. Link a Linear project to a local repo

From any Claude Code session (in any directory — the orchestrator MCP is registered globally):

```
/relay-link-project
```

The slash command will:
- Read the current local repo's path and remote URL via `git`.
- List Linear projects via the Linear MCP and ask which one to link.
- Call `mcp__relay-orchestrator__link_project` to persist the link.

The link lands in `~/Library/Application Support/relay-runner/orchestrator/projects.toml`. Edit only via the MCP tools — it's regenerated on each write.

### 2. Dispatch an issue

```
/relay-orchestrate work on REL-42
```

Or just say it via voice in a `/relay-bridge` session. Claude calls `mcp__relay-orchestrator__dispatch_issue(identifier="REL-42")`. The daemon:

1. Adds a git worktree at `~/Library/Application Support/relay-runner/workspaces/rel-42/` on branch `relay/rel-42`.
2. Renders the workflow prompt (default at `services/orchestrator_workflow.md`, override per-repo at `<repo>/WORKFLOW.md`).
3. Spawns `claude -p --dangerously-skip-permissions` in that worktree, piping the prompt as stdin.
4. Returns a `run_id` immediately — the worker continues in the background.

The worker reads the issue's title/description/labels via the Linear MCP, implements the change, commits with conventional commits referencing the identifier, and posts a status comment back to Linear when done.

### 3. Check status / cancel

```
list_runs                          → all recent runs, newest first
list_runs --state=Running          → only active ones
get_run --run_id=17                → details for one run
cancel_run --run_id=17             → SIGTERM the worker, prune the worktree
```

Voice equivalents work too: "what are the agents doing?", "how's REL-42?", "stop REL-42".

## The intended workflow

The orchestrator is designed around a four-step loop. The main Claude Code session is the *orchestrator* — it's the one talking to you and routing work — and each `claude -p` worker is a one-shot *sub-agent*.

1. **Discuss.** You and the main session talk through what needs to happen. Voice via `/relay-bridge`, or just typed chat. The main session has full context of the conversation, the codebase, and the project state.
2. **Write tickets.** When the discussion settles on concrete work, the main session writes Linear issues for the team's project — title, description with acceptance criteria, priority. Each issue should be small enough that a sub-agent can complete it in one pass without further clarification.
3. **Dispatch.** The main session calls `mcp__relay-orchestrator__dispatch_issue(identifier="MEN-N")` for each ticket it should hand off. Multiple dispatches in parallel are supported (no concurrency cap by design — bound by your Anthropic rate limit). Pass a `context` argument when there's relevant background that doesn't fit cleanly in the issue body — sub-agents have no memory of the conversation otherwise.
4. **Integrate.** Each sub-agent commits to its `relay/<id>` branch and posts a status comment on the Linear issue. The main session merges those branches into the working branch (resolving conflicts when sub-agents touched overlapping code), marks the Linear issue Done, and prunes the worktree + branch.

The main session is *not* a passive router. It's the same session that holds the discussion, so it owns: drafting issue acceptance criteria, deciding which issues to dispatch in parallel, picking the merge order when conflicts are likely, and reviewing the sub-agents' work for quality.

You can still write tickets directly in Linear if you prefer — the orchestrator just needs the identifier. And the main session won't autonomously pick issues off the backlog (no Linear polling in MVP); every dispatch is an explicit decision.

## What the worker is allowed to do

The default `WORKFLOW.md` constrains the worker to:

- **Read** anything in the worktree (and via Linear MCP).
- **Write** anything in the worktree.
- **Commit** to the local `relay/<id>` branch — never `main`, never the linked repo's primary working copy.
- **Comment** on the Linear issue — never modify state, assignee, priority, or labels.
- **Not push.** The branch stays local; a human reviews the worktree and decides.

The worktree is isolated: changes don't leak into the linked repo's primary working copy or any other worktrees. Because the worker runs with `--dangerously-skip-permissions`, it can `rm -rf` everything in the worktree if instructed to — that's why the branch is local-only and the worktree is throwaway.

## Customizing the workflow per repo

Drop a `WORKFLOW.md` at the linked repo's root and the worker uses that instead of the default. Variables: `{{identifier}}`, `{{repo_path}}`, `{{branch}}`, `{{attempt}}`. The default template at [services/orchestrator_workflow.md](../services/orchestrator_workflow.md) is the starting point.

A repo's `WORKFLOW.md` is a fine place to encode project conventions: which test command to run, which directories are off-limits, what a "done" comment should include, etc.

## How runs map to Linear

The orchestrator does **not** modify Linear state directly. The daemon's job is local: claim an identifier, isolate a workspace, run the worker, record the outcome.

The worker writes to Linear via the user's existing Linear MCP (already installed via the global plugin). That means:
- The auth path is unchanged (the same OAuth Linear MCP you use day to day).
- All Linear writes go through the worker's tool-use trace — auditable in the per-run log.
- If the Linear MCP isn't reachable, the worker's first action will fail and the run terminates cleanly.

Autonomous polling (orchestrator pulls "Todo" issues from Linear without a human dispatch) is not in MVP. It lands in a follow-up gated on `[orchestrator].linear_api_key` in `config.toml`.

## Files and locations

| Path | Purpose |
|---|---|
| `services/orchestrator.py` | The daemon (HTTP server + SQLite + worker spawn) |
| `services/orchestrator_workflow.md` | Default workflow template |
| `Sources/relay-orchestrator-mcp/` | Swift MCP proxy (HTTP → MCP tools) |
| `scripts/relay-orchestrator` | Launcher / installer |
| `~/Library/Application Support/relay-runner/orchestrator/projects.toml` | Project links |
| `~/Library/Application Support/relay-runner/orchestrator/runs.db` | Run history (SQLite) |
| `~/Library/Application Support/relay-runner/workspaces/<sanitized-id>/` | Per-issue worktree |
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

**Worker can't see the Linear MCP.** The worker inherits the user's `~/.claude.json`. If `claude mcp list` (run as your user) doesn't show Linear, fix that first — the worker can't see what your shell can't.

**Worktree branch already exists.** `cancel_run` with `prune_worktree=true` (the default) now deletes the local `relay/<id>` ref after pruning, and `dispatch_issue` recovers from a stale ref by deleting and recreating off the project's current `default_branch`. If you hit a leftover ref from before this fix, run `git -C <repo> worktree prune` and `git -C <repo> branch -D relay/<id>` once.

## Limits (MVP)

- One Linear project linked per local repo.
- No autonomous Linear polling — every dispatch is voice or MCP-driven.
- No retry / backoff — failed runs stay failed; redispatch manually.
- No cross-machine orchestration.
- No PR opening — worktree is left for human review.
- Concurrency is uncapped at the daemon level (workers all spawn in parallel); rate-limiting against Anthropic happens at their tier. Add a `max_concurrent` config knob if you need to clamp.
