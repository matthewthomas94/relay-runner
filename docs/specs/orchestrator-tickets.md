# Orchestrator tickets: file format & lifecycle

This document defines the on-disk schema for orchestrator-managed work. The goal is to replace Linear as the system of record with files that travel with the repo — so the orchestrator pattern works against any clone, with no external service required.

> Status: **draft schema**. Not yet wired into the daemon or UI. See *Implementation milestones* at the bottom for the rollout sequence.

## Why files, not a service

- The repo is self-contained. Clone it and the board state, history, and audit trail come with it.
- Git is the access layer — no auth, no roles, no permissions API. Want gated changes? Branch protection. Want to contribute? Open a PR.
- The history of any ticket is `git log` on its file. Free, full diffs, attributable.
- AI agents (this one included) can read, write, and grep tickets like any other source file.

Linear support, if added later, is an *outbound projector* — push state to it for stakeholder visibility — but the repo file remains authoritative.

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

The daemon reads `next_id`, mints `<prefix>-<next_id>`, then increments. Manual edits are fine but discouraged — gaps are harmless, collisions are not.

**First-time init.** If `.orchestrator/config.toml` is missing when the daemon starts, it creates one with:

- `prefix = "<REPO_SLUG>"` — the uppercased repo name (e.g., a repo named `relay-runner` becomes `RELAY` or `RR`; the daemon strips vowels past a length cap to keep IDs short). The user can override in `config.toml` before any tickets exist.
- `next_id = 1`.

No tickets are created — the user authors the first one via `/relay-dispatch` flow, the board UI, or by writing the file by hand.

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
| `backlog → ready`             | Orchestrator session (human-driven, AI-assisted) | Discuss step settles on acceptance criteria. |
| `ready → in_progress`         | Daemon                      | `dispatch_issue` called; stamps `run_id`.   |
| `in_progress → done`          | Integration step            | Sub-agent's branch merged.                  |
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

**Project resolution at view time.** The board UI doesn't show a project picker. The currently-active board is determined by the working directory of the Claude Code session that owns the voice bridge (i.e., where `/relay-bridge` was invoked). The voice bridge is 1:1 with a Claude Code session, the session is rooted in one repo, so "show me the board" unambiguously means "the board for this repo."

If the user switches projects (kills the bridge in repo A, launches a new one in repo B), the next "show me the board" command reflects repo B's `.orchestrator/`. A menu-bar-driven picker for browsing other linked projects' boards is a later enhancement, not part of the initial milestones.

## Concurrency model

Because each ticket is a separate file, parallel sub-agents working on different tickets cannot collide on metadata edits — git merges trivially. The two real conflict cases:

- **Two agents claim the same ticket.** The daemon's `dispatch_issue` is the single chokepoint; it refuses to dispatch a ticket already `in_progress`.
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

## Implementation milestones

Rollout sequence, in increasing risk:

1. **Schema** *(this doc)* — agree on the file format. No code.
2. **Read-only viewer** — SwiftUI window in the menu bar app, scans `.orchestrator/`, renders four-column board. Daemon untouched. Validates the schema works in practice.
3. **Dispatch wiring** — daemon learns the file format; `dispatch_issue` reads ticket from `.orchestrator/<id>.md`, stamps `run_id` and flips status to `in_progress`. Replaces (or runs alongside) Linear as source.
4. **Write UX** — new-card, edit-in-place, drag-between-columns. The board becomes the primary authoring surface.
5. **Linear projector** *(optional)* — outbound mirror for stakeholder visibility.

Migration from a Linear-backed flow is left to each user. Recommended path: hard-cut — close out remaining Linear tickets at their natural break point, then start authoring in `.orchestrator/` going forward. An optional one-shot importer (`linear → .orchestrator/`) can be added later if demand emerges, but it's explicitly not part of the initial milestones; the schema is the boundary, not Linear shape compatibility.
