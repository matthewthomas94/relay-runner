# Relay Runner Orchestrator

The opt-in project artifact writer and exact-ref synchronization contracts are documented in [Project-owned Relay artifact store](architecture/artifact-store.md) and [Relay artifact synchronization](architecture/artifact-sync.md). These are RR-273 phases 3 and 4; the legacy worker-ticket lifecycle described below remains the compatibility path until the later lifecycle and migration gates are enabled.

Symphony-style sub-agent orchestrator. Dispatches tickets from a repo's local kanban board (`<repo>/.orchestrator/<TICKET_ID>.md`) to autonomous Codex or Claude runs in isolated git worktrees, and tracks state in SQLite. Modeled on [openai/symphony](https://github.com/openai/symphony) — the daemon owns "is this ticket claimed / running / done", and each sub-agent owns its own context window for the duration of one run.

The repo is the source of truth: tickets are version-controlled markdown files, the sub-agent edits its ticket's YAML frontmatter and appends a `## Run log` section when it finishes, and everything (code + ticket update) is committed to the worker's branch.

## Quick start

After installing Relay Runner, the bootstrap also sets up the orchestrator (skills, MCP server, launchd plist). To check:

```bash
scripts/relay-orchestrator --status
```

You should see a running daemon, a port file, and an installed plist.

### 1. Open a `/relay-bridge` agent session in a repo or workspace folder

The board is scoped to whichever project or workspace folder your active `/relay-bridge` agent session is rooted in. From a Codex or Claude session whose cwd is the repo or workspace you want to work on:

```
/relay-bridge
```

The bridge records its launching cwd to `/tmp/voice_bridge.cwd` so the menu-bar app can classify the active location. If that cwd is a folder with child git repos, Relay Runner registers the folder as a workspace root, records the child projects, and opens the read-only Program Workspace. It does not create a parent `.orchestrator/`. If the cwd is a single git repo, the project registry stores the repo path, display name, last-seen time, and provider activation metadata, then the Workspace uses the repo root. If the repo has no `.orchestrator/config.toml`, activation initializes it with a repo-derived prefix (`mouse-assist` -> `MA`) and `next_id = 1`. If the cwd is neither a git repo nor a workspace folder containing child repos, activation is refused; run `git init` yourself or select a folder that already contains git repos. Codex and Claude use the same activation model, with provider-specific metadata recorded under the provider label when the caller supplies one. Without a live bridge or explicit activation, Workspace opens as a Terminal/System Settings utility surface so the embedded terminal can start the first session; its Work tab remains unavailable. Switching projects means stopping one bridge (or running `/relay-stop`) and starting another from the new repo or workspace cwd, or using a programmatic activation path by repo path or known alias.

When relay mode starts, the bridge also registers a persistent orchestrator lifecycle row in `orchestrator_sessions.db`, keyed by the resolved cwd. The row stores provider, model, effort, heartbeat, and readable state (`idle`, `planning`, `awaiting_workers`, `reviewing`, `blocked`, `failed`, `stopped`, or `stale`). It is durable daemon state, not a warm model process, so an idle orchestrator session does not spend tokens. Codex and Claude use the same registration and heartbeat path; provider changes on the same project reuse the row and record the change.

The bridge also starts a separate persistent **messenger model process** for the lifetime of the voice session. This process is deliberately tool-free: it cannot plan work, edit tickets, dispatch workers, or take actions. Every user turn is queued to the messenger before the same turn is published to the foreground orchestrator, so model warmup or inference never blocks orchestrator delivery. The foreground session remains authoritative and mirrors provider-visible reasoning summaries, public progress, and worker lifecycle milestones into the messenger context. Hidden chain-of-thought is neither requested nor exposed. Final foreground responses return through an `__ORCHESTRATOR_REPLY__` event; only the messenger normally supplies the spoken wording to Kokoro. If the messenger provider fails, the bridge speaks the authoritative final response directly rather than losing it.

Messenger model choices use stable provider aliases. Codex stores `sol`, `terra`, or `luna` and resolves the newest account-visible concrete model from the local Codex `app-server` catalogue before startup; Claude stores stable aliases such as `best`, `sonnet`, or `haiku`. Codex keeps a warm `app-server` process and ephemeral read-only thread; Claude keeps a warm stream-JSON process. Both disable tools and MCP access. Optional `[general]` keys are `messenger_enabled`, `messenger_model`, and `messenger_effort`. Parakeet STT and Kokoro TTS remain local and unchanged.

### 2. Write a ticket

Open Workspace and create a ticket via the column's `+` button. Choose **Implementation** for code changes or **Spike** for branchless, read-only research; the editor explains the lifecycle before save. The board writes the file to `<repo>/.orchestrator/<TICKET_ID>.md` and bumps `<repo>/.orchestrator/config.toml`'s `next_id`. Existing configs keep their configured prefix; fresh repos derive one from the repo name. Commit both to the working branch — that's the ticket's audit trail going forward.

You can also create the file by hand. The schema is in [docs/specs/orchestrator-tickets.md](specs/orchestrator-tickets.md).

### 3. Promote to `ready` — the board auto-dispatches

Drag the card from `backlog` to `ready` in the menu-bar Board. The moment it lands in the `ready` column, the board calls `mcp__relay-orchestrator__dispatch_ticket(ticket_id, repo_path)` for you — there's no separate "press go" step. This also fires for tickets created directly in the `ready` column (after you fill in the editor and save).

Manual dispatch is still available for edge cases — retries, dispatching out-of-order, or driving from voice without using the board. Either way the agent calls the same MCP tool:

```
/relay-dispatch work on MA-6
```

The daemon:

1. Validates `<repo>/.orchestrator/MA-6.md` exists.
2. Adds a git worktree at `~/Library/Application Support/relay-runner/workspaces/ma-6/` on branch `relay/ma-6`, branched off the repo's default branch (resolved via `git symbolic-ref refs/remotes/origin/HEAD`, falling back to `main`).
3. Renders the workflow prompt (default at `services/orchestrator_workflow.md`, override per-repo at `<repo>/.orchestrator/WORKFLOW.md`).
4. Spawns the configured agent in that worktree, piping the prompt as stdin. New configs default to `codex exec --json --dangerously-bypass-approvals-and-sandbox`; Claude remains available via `[orchestrator].agent = "claude"`.
5. Returns a `run_id` immediately — the worker continues in the background.

The worker reads the ticket file, flips its status to `in_progress`, implements the change, commits the code with a conventional commit referencing the ticket, then flips the ticket's status to `done` (or leaves it `in_progress` if partial) and appends a `## Run log` section before exiting. Both edits land on the worker's branch.

For `execution_mode: spike`, dispatch takes a separate path: the daemon creates a detached read-only clone without a `relay/<id>` branch, gives the provider only local repository/ticket evidence, and requires structured conclusions, evidence, uncertainties, recommendations, and mutation-attempt reporting. Codex uses its read-only sandbox; Claude runs in safe mode with only `Read`, `Glob`, and `Grep`. A valid result is committed directly to the ticket as `## Spike report` and reaches Done without an implementation review or merge. Failure or cancellation cleans the snapshot, records the exact cause, and returns the ticket to Backlog for explicit retry. Backlog dependents are not auto-promoted by spike completion; already-authorized Queued dependents remain eligible.

From a completed spike in Workspace, choose **Follow-ups** to review implementation-ticket proposals derived from its recommended next steps. The foreground PM can use `propose_spike_followups` for the equivalent voice/text flow and supply refined drafts. Each proposal can be edited, accepted, or rejected independently; only acceptance writes to the explicitly selected canonical project board. Accepted tickets include concise spike ticket/run provenance, remain in Backlog, and are not dispatched automatically. Retrying an accepted proposal is idempotent and does not advance the target board counter again.

### Rolling queue drain

When the first ticket enters `ready` or `in_progress`, the daemon creates one durable queue-drain record in `queue_drains.db`. The record has a stable drain id, repo path, target branch, provider, provider-goal state, observed ticket ids, and one status row per observed ticket. New `ready` or `in_progress` tickets join the active drain automatically; unrelated backlog tickets stay out of scope unless they are unresolved predecessors of an observed ticket.

The invariant is that every queued or in-progress ticket must show one of these states:

- `active`: an implementation worker is claimed or running with current activity.
- `scheduled`: a bounded next action exists, such as a ready-sweep retry or a capacity wait.
- `dependency_waiting`: unresolved predecessor tickets are named and will wake after merge/done publication.
- `awaiting_review` or `reviewing`: implementation succeeded and the independent review/merge worker is pending or active.
- `blocked`: automatic progress stopped on a specific ticket/run, with owner and required next step.
- `canceled`: the ticket or drain was canceled.
- `done`: the source ticket is done and accepted work has reached the target branch.
- `completed`: every observed ticket is done or canceled, no observed run remains active/reviewing/retrying/stale/conflicted, and the quiescence window has elapsed.

The daemon reconciles this state from board sweeps, worker completion callbacks, review-worker callbacks, merge decisions, cancellation, startup recovery, and a bounded monitor loop. It does not keep Codex or Claude spending tokens to poll unchanged state. Stale implementation ownership is marked `Stalled` and recovered through the same capped auto-dispatch path; stale review ownership returns to `AwaitingReview` and gets a review worker again. Deterministic failures, exhausted automatic retries, merge conflicts, missing authority, broken dependencies, and capacity waits are visible in the drain record instead of becoming silent loops.

Codex surfaces that support Goals can use their `/goal` lifecycle as the foreground completion contract. Relay Runner still stores the executable drain state locally so it survives daemon restarts and app recovery. The installed Claude CLI does not expose an equivalent documented goal primitive, so Claude sessions use the same Relay Runner durable drain semantics and report the provider difference in the drain's `provider_goal_mode`.

Foreground sessions can inspect the drain through `queue_drain_status` or HTTP `GET /v1/queue-drains`, and can force a bounded reconcile with `POST /v1/queue-drain/reconcile`. Completion stops at reviewed merge/done publication; Relay Runner does not add an automatic release, build, install, push, or deployment.

### 4. Check status / cancel

```
list_runs                          → all recent runs, newest first
list_runs --state=Running          → only active ones
get_run --run_id=17                → details for one run
cancel_run --run_id=17             → SIGTERM the worker, prune the worktree
queue_drain_status reconcile=true  → inspect/reconcile rolling drain state
```

Voice equivalents work too: "what are the agents doing?", "how's MA-6?", "stop MA-6".

## Capture a session review

Use `session_capture` to write end-of-session review notes directly into Graphify Core. The tool accepts a `repo_path`, optional `ticket_id` / `run_id` / `provider`, and structured `entries` whose `kind` can be `shipped`, `started`, `note`, `decision`, `blocker`, `risk`, `idea`, or `status`.

Capture creates ProgramEvent, Decision, Risk, Idea, and Status nodes and links them to project, ticket, and run nodes when the repo, ticket, or run evidence is available. It does not require `.pm/project-id`; that file is legacy metadata, and if the repo has `.orchestrator` ticket files, capture can use that evidence directly. Existing `.pm/` directories in user repos are not deleted automatically and can remain for historical reference unless the user chooses a separate manual cleanup.

Codex and Claude use the same capture schema. The daemon does not scrape either provider's transcript history, so the calling session should pass concise structured entries and any relevant conversation context explicitly.

## The intended workflow

Relay Runner runs as a three-role loop: the fast messenger owns spoken conversation, the foreground orchestrator/PM makes authoritative project decisions and reports public context, and each worker is a one-shot execution agent. Persistent daemon state still records active project sessions and worker dispatch lifecycle, but Relay voice text is not automatically fanned out to a separate ticket-authoring inbox. Codex and Claude follow the same role split; only launch flags, auth flows, model names, and effort rendering differ.

1. **Parallel delivery and classification.** `/relay-bridge` captures the user's voice or typed instruction and immediately queues it to the persistent messenger, then publishes the same command to the foreground orchestrator/PM. The notch shows deterministic visual receipt, while task-like turns can also get a short contextual spoken handoff from the messenger before planning finishes. The messenger speaks in first person (`I` / `me`) on behalf of the foreground orchestrator and names workers directly once authoritative worker context exists. The foreground session clarifies ambiguity, answers general questions, and only creates board work after deciding the command is real project work.
2. **Ticket authoring.** Raw Relay command captures are private metadata, not board cards or ticket body text. The foreground orchestrator/PM writes refined `.orchestrator/<ticket_id>.md` tickets with actionable summaries and acceptance criteria when work should be delegated.
3. **Worker creation.** Once a ticket is refined enough, the foreground orchestrator/PM moves it to `ready` or calls the shared dispatch path. The board auto-dispatches `ready`, and direct dispatch stays available for retries or explicit manual control.
4. **Worker execution.** Implementation mode creates an isolated worktree on `relay/<id>` and follows the commit/review path. Spike mode creates a detached read-only snapshot and returns a structured report through the daemon-owned ticket path.
5. **Review and merge.** Successful implementation runs automatically receive an independent review/merge worker. Accepted work merges through the daemon path, which publishes `done` on the board, prunes the throwaway worktree/branch, records the drain item as done, and triggers dependent auto-promotion.
6. **Status and response synthesis.** The foreground orchestrator/PM mirrors provider-visible progress and worker events to the messenger, then sends its authoritative final response. The messenger uses that bounded public context to speak concise updates and the final outcome while the orchestrator stays frontstage and workers do backstage work.

Codex and Claude share the same voice-turn authorization checks, ticket schema, and dispatch API. Provider-specific differences stay at process launch and sizing rendering: Codex uses `model_reasoning_effort`, Claude uses `--effort`, and both providers use the same `low`, `medium`, `high`, and `xhigh` effort values for provider-neutral work.

Relay voice freshness and mutation authorization are separate. `/tmp/voice_command_state.json` names the newest turn for replies, traces, fallback completions, and TTS; stale output is suppressed when a newer turn exists. Project mutations use the claimed seq/id plus a bounded authorization registered by the bridge. Acknowledgement, inspection/status, and additive turns can become the newest conversation without revoking already-authorized ticket edits or dispatches. Replacement, redirect, interrupt, and cancel turns revoke not-yet-started mutations; if a batched action already started some steps, the daemon reports which later steps were canceled instead of claiming the whole batch succeeded.

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

Drop a `WORKFLOW.md` under the repo's `.orchestrator/` directory and the worker uses that instead of the default. Root-level `WORKFLOW.md` files are ignored because many projects use that name for human process docs. Template variables: `{{ticket_id}}`, `{{repo_path}}`, `{{workspace_path}}`, `{{branch}}`, `{{attempt}}`, `{{run_id}}`, `{{caller_context}}`. The default template at [services/orchestrator_workflow.md](../services/orchestrator_workflow.md) is the starting point.

A repo's `.orchestrator/WORKFLOW.md` is a fine place to encode project conventions: which test command to run, which directories are off-limits, what a "done" run log entry should include, etc.

## How tickets persist

Tickets live as version-controlled markdown under `<repo>/.orchestrator/`. Reads/writes happen via the board UI (in the menu-bar app), the foreground orchestrator/PM, and the sub-agent during a run. The daemon writes ticket files only through structured orchestrator actions or dependency progression, never by pasting raw Relay command text into markdown. That means:

- The audit trail is `git log <repo>/.orchestrator/<ticket_id>.md`. Free, attributable, full diffs.
- Cloning the repo brings the board state with it.
- No external service, no auth, no schema-migration story across machines.

## Which board you see

The active `/relay-bridge` agent session remains the common project picker: when the bridge starts, it writes its launching cwd to `/tmp/voice_bridge.cwd`; the menu-bar Board reads that file (gated on `/tmp/voice_bridge.sock` as liveness check) and classifies it through the active project registry.

If the bridge cwd is a workspace folder with child git repos, the registry stores the workspace root and discovered projects, then the Workspace opens the read-only Program Workspace. The workspace root does not get a parent `.orchestrator/`, and discovered child repos are not initialized just because they were discovered.

If the bridge cwd is a single git repo, the registry activates that repo and renders the repo's `.orchestrator/` board. For a fresh git repo, first activation creates `.orchestrator/config.toml` and renders an empty board. If the cwd is not a git repo and contains no child git repos, activation is refused instead of running `git init`; initialize the folder explicitly first.

The General setting is still stored as `working_directory` in `config.toml` for compatibility, but the UI now treats it as the workspace folder. Existing users migrate through the same resolver on app launch, provider change, or saved setting change: a legacy repo path scopes the Workspace Work tab to that repo, while a legacy parent folder such as `/Users/matthewthomas/dev` becomes a workspace root if it contains child repos. Start Session launches both Codex and Claude from that configured folder and writes the same provider metadata shape (`codex` or `claude`) for Workspace routing.

Programmatic callers can activate a project by repo path or registered alias, and the Relay Actions MCP exposes the same path as `activate_project`, giving Codex, Claude, MCP, and UI code a provider-neutral activation model. With no live bridge or explicit activation, Workspace opens without a Work tab and keeps Terminal/System Settings available; recording still shows the standard "No session running" pill. Switch projects by stopping one bridge (or `/relay-stop`) and starting another from the new repo or workspace cwd, or by explicitly activating another registered repo.

The full file format is documented at [docs/specs/orchestrator-tickets.md](specs/orchestrator-tickets.md).

## Files and locations

| Path | Purpose |
|---|---|
| `services/orchestrator.py` | The daemon (HTTP server + SQLite + worker spawn) |
| `services/messenger.py` | Persistent tool-free Codex/Claude messenger backends and event runtime |
| `services/orchestrator_workflow.md` | Default workflow template |
| `Sources/relay-orchestrator-mcp/` | Swift MCP proxy (HTTP → MCP tools) |
| `scripts/relay-orchestrator` | Launcher / installer |
| `<repo>/.orchestrator/<TICKET_ID>.md` | One ticket per file (board source of truth) |
| `<repo>/.orchestrator/config.toml` | Repo-scoped ticket counter (`prefix`, `next_id`) |
| `~/Library/Application Support/relay-runner/projects/registry-v2.json` | Opt-in schema-2 project registry; see [registry v2 ownership and recovery](architecture/registry-v2.md) |
| `~/Library/Application Support/relay-runner/projects/registry-v2.backup.json` | Registry v2 last-known-good backup |
| `~/Library/Application Support/relay-runner/orchestrator/runs.db` | Run history (SQLite) |
| `~/Library/Application Support/relay-runner/orchestrator/queue_drains.db` | Durable rolling queue-drain goals and observed ticket states |
| `~/Library/Application Support/relay-runner/orchestrator/orchestrator_sessions.db` | Persistent orchestrator lifecycle state |
| `~/Library/Application Support/relay-runner/orchestrator/orchestrator_commands.db` | Legacy/private Relay command store for explicit structured orchestrator actions |
| `~/Library/Application Support/relay-runner/workspaces/<sanitized-id>/` | Per-ticket worktree |
| `~/Library/Application Support/relay-runner/workspaces/<sanitized-id>/.relay/run.log` | Worker stdout (full session trace) |
| `~/Library/LaunchAgents/com.relay.orchestrator.plist` | launchd descriptor |
| `/tmp/relay_orchestrator.port` | Port the daemon bound to |
| `/tmp/relay_orchestrator.log` / `.err` | Daemon stdout / stderr |

When registry v2 is enabled, Workspace and provider sessions use the [explicit project-scope state machine](architecture/project-scope-v2.md): Workspace may be empty and open without a bridge, while project work and Start Session require an explicitly selected available registered repository. The legacy Workspace-folder behavior above remains only as the reversible compatibility path.

Projects that separately opt into artifact storage use the [private-index project artifact writer](architecture/artifact-store.md). Its orphan `refs/heads/relay/artifacts` ref is canonical; repo-root `.orchestrator/` is an excluded, verified materialization. Artifact storage begins local-only and never changes or publishes a source ref.

## Troubleshooting

**MCP tools missing.** Confirm the registration:
```bash
codex mcp list | grep relay-orchestrator
```
Re-run if absent: `scripts/relay-orchestrator --install`. For Claude, use `claude mcp list`.

**Tools error with "Orchestrator daemon is not reachable".** The daemon isn't running. Check:
```bash
scripts/relay-orchestrator --status
launchctl print "gui/$(id -u)/com.relay.orchestrator"   # detailed launchd state
tail /tmp/relay_orchestrator.err
```
Restart with `scripts/relay-orchestrator --start`.

**Installed skills still show older foreground-session guidance.** Re-generate the installed command and skill files from the repo sources:
```bash
scripts/relay-bridge --install-skills
scripts/relay-orchestrator --install-skills
```
If you're validating the bundled app instead of the repo checkout, rebuild or reinstall the app first so the bundled scripts match the updated source.

**Worker hangs.** Cancel and inspect:
```
cancel_run --run_id=N --prune_worktree=false
```
Then read `<workspace>/.relay/run.log`. Implementation and review workers have no wall-clock deadline. The daemon performs an advisory health check every 10 minutes by comparing process liveness, worker-log growth, activity, commits, and worktree changes. A live run with no observable progress raises a visible warning but keeps running; only explicit cancellation, process exit/failure, or a separately identified critical condition stops it. Tune the observation interval via `[orchestrator].worker_health_check_seconds` in `config.toml`.

**Dispatch fails with "ticket not found".** The orchestrator requires `<repo>/.orchestrator/<ticket_id>.md` to exist before dispatching. Either create the ticket via the board UI (or by hand following [the spec](specs/orchestrator-tickets.md)) and commit it, or fix the `ticket_id` argument if it was a typo.

**Worktree branch already exists.** `cancel_run` with `prune_worktree=true` (the default) deletes the local `relay/<id>` ref after pruning, and `dispatch_ticket` recovers from a stale ref by deleting and recreating off the repo's current default branch. If you hit a leftover ref from before this fix, run `git -C <repo> worktree prune` and `git -C <repo> branch -D relay/<id>` once.

## Limits (MVP)

- No cross-machine orchestration.
- No PR opening — worktree is left for human review.
- Concurrency is uncapped by default. Set `[orchestrator].max_concurrent_workers` to make automatic queue drains expose capacity waits and resume when a slot opens.
