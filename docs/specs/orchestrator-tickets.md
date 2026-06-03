# Orchestrator tickets: file format & lifecycle

This document defines the on-disk schema for orchestrator-managed work. Files that travel with the repo are the system of record — the orchestrator pattern works against any clone with no external service required.

## Why files, not a service

- The repo is self-contained. Clone it and the board state, history, and audit trail come with it.
- Git is the access layer — no auth, no roles, no permissions API. Want gated changes? Branch protection. Want to contribute? Open a PR.
- The history of any ticket is `git log` on its file. Free, full diffs, attributable.
- AI agents (this one included) can read, write, and grep tickets like any other source file.

## Layout

```
<repo>/
  .orchestrator/
    config.toml          # project-level settings (id prefix, default branch)
    RR-1.md              # one file per ticket; filename matches `id`
    RR-2.md
    RR-3.md
    ...
```

Everything lives under `.orchestrator/` at the repo root. No nesting.

### `config.toml`

```toml
prefix = "RR"            # ticket ID prefix; used when generating new ticket IDs
next_id = 14             # monotonic counter; incremented on each new ticket
```

The ticket writer reads `next_id`, mints `<prefix>-<next_id>`, then increments. Manual edits are fine but discouraged — gaps are harmless, collisions are not.

**First-time init.** If `.orchestrator/config.toml` is missing when the board resolves a live bridge rooted in a git repo, it creates one with:

- `prefix = "<PREFIX>"` — a repo-derived uppercase prefix. Hyphenated or underscored repo names use word initials (`relay-runner` -> `RR`, `mouse-assist` -> `MA`); single-word names use the first two alphanumeric characters.
- `next_id = 1`.

No tickets are created — the user authors the first one via the board UI or by writing the file by hand. The user can still edit `config.toml` before creating tickets to override the prefix.

**Concurrent ID minting across branches.** Two users on two branches can both mint `RR-14.md` independently. Merge conflicts surface this: the second one to merge gets a textual conflict on `.orchestrator/config.toml` (both bumped `next_id`) and a duplicate-filename conflict on `RR-14.md`. Resolution: bump the loser's `id` to the next free integer, rename their file, fix any `depends_on` references. This is rare in practice (mint-then-merge usually happens fast) but the spec is explicit that conflict resolution is a human step, not magic.

## Ticket file format

A ticket is a markdown file with YAML frontmatter and a body.

```markdown
---
id: RR-1
title: Read-only kanban board view in menu bar
status: ready
priority: high
depends_on: []
run_id: null
canceled: false
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
| `status`      | enum           | yes      | `backlog` \| `ready` \| `in_progress` \| `done`.                                            |
| `priority`    | enum           | yes      | `urgent` \| `high` \| `medium` \| `low`. Default `medium`.                                  |
| `depends_on`  | list of `id`s  | yes      | May be `[]`. Cycles are invalid (validated at parse time).                                  |
| `run_id`      | integer / null | yes      | Set by the daemon when dispatched. Persists after completion as an audit-trail back-link.   |
| `canceled`    | boolean        | yes      | A flag, not a column. Default `false`. Canceled tickets stay in their existing column.      |

Anything else under `---` is ignored, leaving room for future fields without breaking old parsers.

### Body

Two recommended sections, both freeform:

- `## Description` — the *why* and *what*.
- `## Acceptance criteria` — checkbox list of falsifiable checks. The sub-agent verifies against these.

Neither is enforced by the schema. Tickets in `backlog` often have only a description; tickets in `ready` are expected to have acceptance criteria.

## Statuses & lifecycle

Four columns, fixed:

```
Backlog → Ready → In Progress → Done
```

| Status        | Meaning                                                                                     |
|---------------|---------------------------------------------------------------------------------------------|
| `backlog`     | Idea captured. Not yet refined or estimated. Often no acceptance criteria.                  |
| `ready`       | Refined. Has acceptance criteria. Ready to be dispatched.                                   |
| `in_progress` | Daemon has dispatched it; a `relay/<id>` worktree exists; `run_id` is stamped.              |
| `done`        | Sub-agent's branch was merged into the working branch.                                      |

### Who flips status

| Transition                    | Actor                       | Trigger                                  |
|-------------------------------|-----------------------------|------------------------------------------|
| `backlog → ready`             | Human via board drag/edit, OR daemon auto-progression | Promoting a card to `ready` is the auto-dispatch trigger — the board calls `dispatch_ticket` the moment a card lands there (drag, or new-in-ready + save). The daemon also flips `backlog → ready` on dependents when a predecessor reaches `done` (then dispatches them in turn). |
| `ready → in_progress`         | Sub-agent                   | Worker's first step after `dispatch_ticket` claims the run; the worker stamps `run_id` and commits the frontmatter change. |
| `in_progress → done`          | Sub-agent                   | Worker flips status and appends `## Run log` before exiting; commit lands on the worker's branch and reaches the board when the branch is merged. |
| any → `canceled: true`        | Daemon or human             | `cancel_run` called, or manual cancel.      |

Cancellation does **not** move the ticket to a new column. It flips `canceled: true` and the card renders with a strikethrough or muted treatment in whatever column it sat in. Re-opening clears the flag.

### Invalid transitions

The daemon refuses to dispatch a ticket that:

- Is not in `ready`.
- Has unsatisfied `depends_on` (any predecessor not `done`).
- Already has a non-null `run_id` whose run is `Claimed | Running`.

## Validation rules

A ticket file is valid iff:

1. The filename matches `<id>.md`.
2. All required frontmatter fields are present and well-typed.
3. `status` and `priority` use known enum values.
4. `depends_on` references resolve to existing ticket files (no dangling pointers).
5. No dependency cycles in the project-wide graph.
6. If `status == in_progress`, `run_id` is non-null and points to a known orchestrator run.
7. If `status == done`, the file has at least one commit on the working branch referencing the `id` (audit hint, not strictly enforced).

Validation is a one-shot pass over `.orchestrator/`; the daemon runs it on startup and after every write.

## Multi-project model

Each repo owns its own `.orchestrator/` directory, its own prefix, and its own ID space. Boards are per-repo by construction; there is no cross-repo ticket model, no aggregated "everything" view, no shared dependency graph.

**Project resolution at view time.** The board UI has no project picker. Resolution runs through the active voice-bridge session: when `/relay-bridge` starts, the bridge script writes its launching cwd to `/tmp/voice_bridge.cwd`. The menu-bar Board reads that file (gated on `/tmp/voice_bridge.sock` existing as a liveness check) and renders the `.orchestrator/` directory inside that cwd. If the bridge cwd is a git repo with no `.orchestrator/config.toml` yet, the board initializes it before rendering an empty board. The voice bridge is 1:1 with a Claude Code session, the session is rooted in one repo, so "show me the board" unambiguously means "the board for this repo."

Without a live bridge, the board's `⌃⌥` hotkey surfaces the same "No session running" pill that fires when the user tries to record voice out of session, rather than opening — better to teach the rule (and reuse a known UI surface) than to silently open the wrong project or no project at all.

If the user switches projects (kills the bridge in repo A, launches a new one in repo B), the next toggle reflects repo B's `.orchestrator/`. A menu-bar-driven picker for browsing other repos' boards is a later enhancement, not part of the current implementation.

## Concurrency model

Because each ticket is a separate file, parallel sub-agents working on different tickets cannot collide on metadata edits — git merges trivially. The two real conflict cases:

- **Two agents claim the same ticket.** The daemon's `dispatch_ticket` is the single chokepoint; it refuses to dispatch a ticket already `in_progress`.
- **An agent edits its own ticket while the orchestrator also edits it.** Sub-agents are conventionally read-only on their own ticket file (they emit progress as commit messages and status comments instead). The schema permits writes, but the workflow discourages them.

## Example tickets

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

- [ ] Menu bar exposes "Show Board" item.
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
4. **Auto-dispatch on `ready`** — the board calls `dispatch_ticket` automatically whenever a card lands in the `ready` column (via drag, or new-in-ready followed by editor save). The daemon's `find_active` makes the call idempotent, so re-promoting a ticket that's already running is a no-op.
5. **Dependency auto-progression** — when a worker reaches `Succeeded`, the daemon scans the repo's `.orchestrator/` for tickets whose `depends_on` includes the just-finished ticket. Any dependent in `backlog` with all of its other deps also `done` gets its frontmatter flipped to `ready` and dispatched. This is the only path where the daemon writes ticket files — sub-agents own their own ticket; the daemon owns inter-ticket gating.
