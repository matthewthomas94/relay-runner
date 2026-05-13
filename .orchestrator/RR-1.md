---
id: RR-1
title: Read-only kanban board view in menu bar app
status: ready
priority: high
depends_on: []
run_id: null
canceled: false
---

## Description

Add a "Show Board" menu item to the Relay Runner menu bar that opens a SwiftUI window rendering the contents of `.orchestrator/` as a four-column kanban board.

Columns, left to right: **Backlog**, **Ready**, **In Progress**, **Done**. Cards reuse the same translucent rounded-pill styling used by the STT/Thinking overlay so the board looks like it belongs to the rest of the app.

The board is **read-only** in this iteration. No drag-to-reorder, no new-card button, no in-app edit. Authoring happens via file edits in the repo (and later, via the dispatch flow and a write UX, which are separate tickets).

Project resolution follows the rule in `docs/specs/orchestrator-tickets.md`: the active board is the `.orchestrator/` of the repo where the voice bridge / Claude Code session is rooted.

## Acceptance criteria

- [ ] Menu bar app exposes a "Show Board" item (a keyboard shortcut may follow in a later ticket).
- [ ] Clicking "Show Board" opens a window titled with the current project's repo name.
- [ ] The window scans `.orchestrator/*.md`, parses YAML frontmatter, and renders one card per ticket file in the column matching its `status`.
- [ ] Tickets with `canceled: true` render with a visually muted treatment (e.g., strikethrough or reduced opacity) but stay in their original column.
- [ ] Each card displays at minimum: `id`, `title`, and a priority indicator.
- [ ] Empty columns render a placeholder ("No tickets in Backlog", etc.).
- [ ] Card styling visibly matches the STT/Thinking overlay pills (same corner radius, translucency, typography).
- [ ] Parse errors on individual files don't crash the board — log and skip, so one bad ticket doesn't take down the view.
- [ ] If the current repo has no `.orchestrator/` directory, the window shows an empty-state explanation pointing at the spec.
