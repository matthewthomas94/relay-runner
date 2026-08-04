# Orchestrator tickets: file format & lifecycle

This document defines the on-disk schema for orchestrator-managed work. Files that travel with the repo are the system of record — the orchestrator pattern works against any clone with no external service required.

## Why files, not a service

- The repo is self-contained. Clone it and the board state, history, and audit trail come with it.
- Git is the access layer — no auth, no roles, no permissions API. Want gated changes? Branch protection. Want to contribute? Open a PR.
- The history of any ticket is `git log` on its file. Free, full diffs, attributable.
- AI agents (this one included) can read, write, and grep tickets like any other source file.

## Layout

Example layout for this `relay-runner` repo:

```
<repo>/
  .orchestrator/
    config.toml          # project-level settings (id prefix, default branch)
    attachments/         # optional ticket-owned image inputs
      RR-1/
        design.png
    RR-1.md              # one file per ticket; filename matches `id`
    RR-2.md
    RR-3.md
    ...
```

Everything lives under `.orchestrator/` at the repo root. No nesting.

### `config.toml`

```toml
prefix = "RR"            # example ticket ID prefix for relay-runner
next_id = 14             # monotonic counter; incremented on each new ticket
```

The ticket writer reads `next_id`, mints `<prefix>-<next_id>`, then increments. Manual edits are fine but discouraged — gaps are harmless, collisions are not.

**First-time init.** If `.orchestrator/config.toml` is missing when the board resolves a live bridge rooted in a git repo, it creates one with:

- `prefix = "<PREFIX>"` — a repo-derived uppercase prefix. Hyphenated or underscored repo names use word initials (`relay-runner` -> `RR`, `mouse-assist` -> `MA`, `client_dashboard` -> `CD`); single-word names use the first two alphanumeric characters. If no alphanumeric characters remain, the board uses `T` as a documented safe fallback.
- `next_id = 1`.

No tickets are created — the user authors the first one via the board UI or by writing the file by hand. The user can still edit `config.toml` before creating tickets to override the prefix.

**Concurrent ID minting across branches.** Two users on two branches can both mint the same next ticket, such as `MA-14.md` in a `mouse-assist` repo. Merge conflicts surface this: the second one to merge gets a textual conflict on `.orchestrator/config.toml` (both bumped `next_id`) and a duplicate-filename conflict on the ticket file. Resolution: bump the loser's `id` to the next free integer, rename their file, fix any `depends_on` references. This is rare in practice (mint-then-merge usually happens fast) but the spec is explicit that conflict resolution is a human step, not magic.

## Ticket file format

A ticket is a markdown file with YAML frontmatter and a body.

```markdown
---
id: RR-1
title: Read-only kanban board view in menu bar
status: ready
priority: high
execution_mode: implementation
depends_on: []
run_id: null
canceled: false
worker_model: balanced
worker_effort: medium
worker_sizing_rationale: "Small, well-scoped UI change with limited blast radius."
worker_provider_notes: "Codex uses model_reasoning_effort; Claude uses --effort. No provider-specific limitation."
---

## Description

Free-form prose explaining the work.

## Acceptance criteria

- [ ] Falsifiable check 1
- [ ] Falsifiable check 2
```

### Frontmatter fields

| Field         | Type           | Required | Notes                                                                                       |
|---------------|----------------|----------|---------------------------------------------------------------------------------------------|
| `id`          | string         | yes      | Must match the filename (without `.md`). Format: `<PREFIX>-<N>`.                            |
| `title`       | string         | yes      | One-line human-readable summary.                                                            |
| `status`      | enum           | yes      | `backlog` \| `ready` \| `in_progress` \| `verification_blocked` \| `done`.                   |
| `priority`    | enum           | yes      | `urgent` \| `high` \| `medium` \| `low`. Default `medium`.                                  |
| `execution_mode` | enum       | no       | `implementation` \| `spike`. Missing values default to `implementation` for legacy compatibility. |
| `depends_on`  | list of `id`s  | yes      | May be `[]`. Cycles are invalid (validated at parse time).                                  |
| `run_id`      | integer / null | yes      | Set by the daemon when dispatched. Persists after completion as an audit-trail back-link.   |
| `canceled`    | boolean        | yes      | A flag, not a column. Default `false`. Canceled tickets stay in their existing column.      |
| `draft`       | boolean        | no       | Temporary board-created editor state. `ready` drafts are visible but not auto-dispatched until saved. Omitted when false. |
| `worker_model` | string       | for `ready` | Provider-neutral worker tier (`fast`, `balanced`, `strong`) or a provider-scoped model override (`codex:<model-slug>` or `claude:<model-alias>`). |
| `worker_effort` | enum        | for `ready` | Reasoning-effort decision. Shared values: `low`, `medium`, `high`, `xhigh`. `max` is valid only for an explicitly Claude-scoped ticket with `worker_provider_notes` documenting the Codex limitation. |
| `worker_sizing_rationale` | string | for `ready` | Short non-empty explanation of why the ticket needs the selected model/tier and effort. |
| `worker_provider_notes` | string | for `ready` | Provider-parity note. Use `none` only when the selected model/tier and effort are intentionally provider-neutral with no caveats. Otherwise name the Codex/Claude difference or limitation. |
| `verification_blocker` | string | for `verification_blocked` | Exact external condition that prevented required verification. |
| `verification_resume` | string | for `verification_blocked` | Explicit condition/action that permits the daemon to resume the ticket. |

Anything else under `---` is ignored, leaving room for future fields without breaking old parsers.

### Worker sizing

Every `ready` ticket is expected to carry an explicit worker-sizing decision before it can be dispatched. The foreground orchestrator makes this decision while it still has the full project context; a cold worker should not infer whether the job belongs on a fast/cheap worker, a balanced worker, or a high-effort configuration.

Use `worker_model` as the model/tier choice and `worker_effort` as the reasoning-effort choice:

- `fast` + `low` fits documentation, test-only, or very localized code changes with low ambiguity and cheap verification.
- `balanced` + `medium` fits ordinary features, bug fixes, and refactors with a known implementation shape.
- `strong` with `high` or `xhigh` fits cross-module work, ambiguous design choices, security-sensitive changes, high blast radius, or expensive build/test loops.

Provider-scoped model values are allowed when the ticket intentionally requires one provider's stable model surface, such as `codex:luna` or `claude:sonnet`. Keep effort separate from the model field.

Provider parity is part of the sizing decision. RR-102 verified that Codex workers accept `low`, `medium`, `high`, and `xhigh` through `model_reasoning_effort`, while Claude workers accept `low`, `medium`, `high`, `xhigh`, and `max` through `--effort`. Do not use `max` for provider-neutral or Codex-dispatchable tickets until a future Codex release exposes it. If a ticket is intentionally Claude-only, write that limitation in `worker_provider_notes` instead of leaving the cold worker to discover it.

### Execution modes

`implementation` is the default and retains the isolated `relay/<id>` branch, source commit, independent review, and merge lifecycle.

Use `spike` for a bounded research question whose output is evidence rather than code. A spike:

- runs in an isolated detached clone made read-only before the provider starts;
- creates no `relay/<id>` branch and never enters implementation review/merge;
- limits Codex to its read-only sandbox and Claude to `Read`, `Glob`, and `Grep`, with custom tools, MCP servers, network, desktop control, and external side effects unavailable;
- returns structured conclusions, evidence, uncertainties, recommended next steps, and mutation-attempt reporting;
- is completed by a daemon-owned ticket-only commit that writes a concise `## Spike report` with run provenance and moves the ticket to `done`;
- returns to `backlog` with the exact cause when canceled, incomplete, or failed, so retry requires renewed user authorization.

Spike completion does not auto-promote backlog dependents. A downstream ticket already refined and explicitly placed in `ready` may dispatch once its spike dependency is done; otherwise the foreground PM uses the findings to author or refine a separate implementation ticket.

### Body

Two recommended sections, both freeform:

- `## Description` — the *why* and *what*.
- `## Acceptance criteria` — checkbox list of falsifiable checks. The sub-agent verifies against these. For provider-facing work, include checks for each supported provider (currently Codex and Claude), or state the intentional provider-specific limitation or difference in the ticket.

Neither is enforced by the schema. Tickets in `backlog` often have only a description; tickets in `ready` are expected to have acceptance criteria.

A `ready` ticket for provider-facing work should make provider parity explicit: Codex-specific work should say what happens for Claude, Claude-specific work should say what happens for Codex, and any deliberate difference should be visible before dispatch.

### Image attachments

Ticket design images live under `.orchestrator/attachments/<TICKET_ID>/` and are referenced from an optional `## Attachments` body section with paths relative to `.orchestrator/`, for example:

```markdown
## Attachments

- ![settings-layout.png](attachments/RR-1/settings-layout.png)
```

The Workspace ticket editor copies selected image files into this directory and appends the Markdown references without changing ticket frontmatter. Dispatch snapshots materialize the ticket-owned attachment directory into the worker worktree even when the files are not committed yet. Workers must inspect referenced images before planning and treat them as ticket requirements. Unsupported non-image files are rejected by the editor.

## Statuses & lifecycle

Four columns, fixed:

```
Backlog → Queued → In Progress → Done
```

| Status        | Meaning                                                                                     |
|---------------|---------------------------------------------------------------------------------------------|
| `backlog`     | Idea captured. Not yet refined or estimated. Often no acceptance criteria.                  |
| `ready`       | Refined queued work. The on-disk value stays `ready`; board UI labels this lane "Queued".   |
| `in_progress` | Daemon has dispatched it and stamped `run_id`. Implementations use a `relay/<id>` worktree; spikes use a detached read-only snapshot. |
| `verification_blocked` | Implementation has been reviewed, but a named external condition prevents required verification. Rendered in the In Progress lane. |
| `done`        | Implementation branch was merged, or a spike report was committed through the daemon-owned ticket-only path. |

### Who flips status

| Transition                    | Actor                       | Trigger                                  |
|-------------------------------|-----------------------------|------------------------------------------|
| `backlog → ready`             | Human via board drag/edit, OR daemon auto-progression | Promoting a card into the Queued lane writes `status: ready`. The board asks the daemon to sweep queued work; dependency-gated queued tickets remain visible and waiting until all predecessors are `done`. The daemon also flips `backlog → ready` on dependents when a predecessor reaches `done` (then dispatches eligible queued tickets in turn). |
| `ready → in_progress`         | Sub-agent                   | Worker's first step after `dispatch_ticket` claims the run; the worker stamps `run_id` and commits the frontmatter change. |
| `in_progress → done`          | Sub-agent                   | Worker flips status and appends `## Run log` before exiting; commit lands on the worker's branch and reaches the board when the branch is merged. |
| spike `ready → in_progress → done` | Daemon | Daemon claims the branchless run, validates structured findings, commits `## Spike report`, and cleans the snapshot without review/merge. |
| `in_progress → verification_blocked` | Sub-agent + reviewer | Worker commits the exact external blocker and resume condition; review merges useful work without closing the ticket or progressing dependents. |
| `verification_blocked → ready` | Daemon via explicit resume action | `resume_verification_blocked` appends what changed to the run log, commits the canonical transition, clears blocker fields, and optionally dispatches a fresh attempt. |
| any → `canceled: true`        | Daemon or human             | `cancel_run` called, or manual cancel.      |

Cancellation does **not** move the ticket to a new column. It flips `canceled: true` and the card renders with a strikethrough or muted treatment in whatever column it sat in. Re-opening clears the flag.

### Invalid transitions

The daemon refuses to dispatch a ticket that:

- Is not in `ready`.
- Has `draft: true` because the board editor has not saved it yet.
- Has unsatisfied `depends_on` (any predecessor not `done`).
- Already has a non-null `run_id` whose run is `Claimed | Running`.
- Is `verification_blocked`; use the explicit resume action rather than dispatching it directly.
- Declares a historical terminal `run_id` whose local ledger row was lost; use `reconcile_preserved_run` against the clean, committed canonical ticket before review or resume. Reconciliation restores only the `Merged` or `VerificationBlocked` record and never edits the ticket, progresses dependencies, or dispatches work.

## Validation rules

A ticket file is valid iff:

1. The filename matches `<id>.md`.
2. All required frontmatter fields are present and well-typed.
3. `status` and `priority` use known enum values.
4. `depends_on` references resolve to existing ticket files (no dangling pointers).
5. No dependency cycles in the project-wide graph.
6. If `status == in_progress`, `run_id` is non-null and points to a known orchestrator run.
7. If `status == verification_blocked`, `run_id`, `verification_blocker`, and `verification_resume` are present and the run is retained as a non-failure lifecycle record.
8. If `status == done`, the file has at least one commit on the working branch referencing the `id` (audit hint, not strictly enforced).

Validation is a one-shot pass over `.orchestrator/`; the daemon runs it on startup and after every write.

## Multi-project model

Each repo owns its own `.orchestrator/` directory, its own prefix, and its own ID space. Boards are per-repo by construction; there is no cross-repo ticket model, no aggregated "everything" view, no shared dependency graph.

**Project resolution at view time.** Resolution runs through the active project registry. The active `/relay-bridge` agent session remains one activation path: when the bridge starts, the bridge script writes its launching cwd to `/tmp/voice_bridge.cwd`. The menu-bar Workspace reads that file (gated on `/tmp/voice_bridge.sock` existing as a liveness check) and classifies it through the workspace-folder resolver. A folder with child git repos is registered as a workspace root, records its discovered child projects, and opens the read-only Program Workspace without creating a parent `.orchestrator/`. A single git repo is registered and activated as a project, and if that repo has no `.orchestrator/config.toml` yet, activation initializes it before rendering an empty project work tab. If the bridge cwd is neither a git repo nor a workspace folder containing child git repos, activation is refused instead of running `git init`; the user must initialize git explicitly or choose a folder containing git repos. Programmatic callers can activate a project by repo path or registered alias, and Relay Actions MCP exposes that path as `activate_project`, giving Codex, Claude, MCP, and UI code the same provider-neutral activation model.

**Workspace-folder migration.** The app-level config key remains `general.working_directory` for compatibility with existing installs, but the UI and resolver interpret it as a workspace folder. On app launch, provider change, and saved setting change, the configured path is refreshed through the same classifier used by Start Session and bridge cwd routing. A legacy single-repo value migrates to an active project and may initialize that repo's `.orchestrator/config.toml`; a legacy parent folder value migrates to a workspace root if it contains child git repos and must not create a parent `.orchestrator/`.

Without a live bridge or registry route, Workspace can still open its embedded Terminal and System Settings tabs so the user can start a session. The Work tab remains unavailable until a project or workspace is resolved, and Relay Runner must not silently create a board for a non-git folder. Recording without a session continues to use the standard "No session running" pill.

If the user switches projects (kills the bridge in repo A, launches a new one in repo B), the next toggle reflects repo B's `.orchestrator/`. A menu-bar-driven picker for browsing other repos' boards is a later enhancement, not part of the current implementation.

## Concurrency model

Because each ticket is a separate file, parallel sub-agents working on different tickets cannot collide on metadata edits — git merges trivially. The two real conflict cases:

- **Two agents claim the same ticket.** The daemon's `dispatch_ticket` is the single chokepoint; it refuses to dispatch a ticket already `in_progress`.
- **An agent edits its own ticket while the orchestrator also edits it.** Sub-agents are conventionally read-only on their own ticket file (they emit progress as commit messages and status comments instead). The schema permits writes, but the workflow discourages them.

## Example tickets

These examples use this repo's `RR` prefix.

A backlog idea:

```markdown
---
id: RR-7
title: Drag-and-drop between columns in board view
status: backlog
priority: low
depends_on: [RR-1]
run_id: null
canceled: false
worker_model: strong
worker_effort: high
worker_sizing_rationale: "Touches board rendering, ticket parsing, and daemon dispatch wiring."
worker_provider_notes: "Codex and Claude both support high effort; dispatch renders provider-specific flags."
---

## Description

After the read-only board lands, users should be able to drag cards between columns to flip status. Probably needs an "undo" affordance since dragging is easy to fat-finger.
```

A ticket mid-dispatch:

```markdown
---
id: RR-1
title: Read-only kanban board view in menu bar
status: in_progress
priority: high
depends_on: []
run_id: 14
canceled: false
---

## Description

Render `.orchestrator/*.md` as a four-column board…

## Acceptance criteria

- [ ] Menu bar exposes "Show Workspace" item.
- [ ] Board window reads `.orchestrator/*.md` and parses frontmatter.
- [ ] Cards render in correct column based on `status`.
- [ ] Cards display `id`, `title`, and priority badge.
- [ ] Empty columns show a placeholder.
- [ ] No write actions yet — read-only first.
```

## Implementation status

Shipped:

1. **Schema** *(this doc)* — file format and lifecycle.
2. **Board UI** — SwiftUI overlay in the menu bar app reads `.orchestrator/`, renders four-column board, supports new/edit/delete and drag-between-columns.
3. **Dispatch wiring** — `mcp__relay-orchestrator__dispatch_ticket(ticket_id, repo_path)` reads `<repo>/.orchestrator/<ticket_id>.md` and spawns a sub-agent. The worker flips `status` to `in_progress` (stamping `run_id`) at the start of the run and to `done` (with an appended `## Run log` section) before exiting; both changes are committed to the worker's branch.
4. **Auto-dispatch on queued work** — the board asks the daemon to sweep queued work whenever a card lands in the `ready` schema lane (via drag, or new-in-queued followed by editor save). The sweeper dispatches only tickets whose dependencies are done; dependency-gated queued tickets remain in the lane with a waiting marker.
5. **Review/merge and dependency auto-progression** — when an implementation worker finishes, the daemon dispatches a follow-up review/merge worker instead of asking the foreground orchestrator to review and merge the branch directly. The reviewer inspects the worker branch, runs verification, and accepts or retries through the daemon. Only an accepted merge publishes the ticket's `done` state into the source repo; worker success awaiting review is not enough to place a ticket in Done or progress dependents. After that accepted merge, the daemon scans `.orchestrator/` for tickets whose `depends_on` includes the merged ticket. Any dependent in `backlog` with all of its other deps also `done` gets its frontmatter flipped to `ready`; dependents already in `ready` stay queued. Eligible queued dependents are then dispatched. This is the only path where the daemon writes ticket files — sub-agents own their own ticket; the daemon owns inter-ticket gating.
