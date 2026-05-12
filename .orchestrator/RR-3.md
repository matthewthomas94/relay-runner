---
id: RR-3
title: Write UX on the board — new card, edit, drag between columns
status: ready
priority: medium
depends_on: [RR-1]
run_id: null
canceled: false
---

## Description

Make the board view the primary authoring surface so users don't have to hand-edit markdown files. Three writes:

1. **New card.** A "+" affordance in each column. Clicking opens an inline editor (title + description; status defaulted to the column the user clicked). Saving mints the next `<prefix>-<N>` id via the daemon (or directly from `config.toml`), writes the file, commits.
2. **Edit in place.** Clicking a card opens it for editing — title, description, acceptance criteria, priority, dependencies. Saving rewrites the file's frontmatter + body and commits.
3. **Drag between columns.** Dragging a card from one column to another flips its `status` field, writes the file, commits. Disallow drags that would violate dependencies (predecessor not done → can't move to `in_progress`); surface a clear error.

Each write is a single atomic git commit so the audit trail stays clean.

## Acceptance criteria

- [ ] "+" button in each column header; opens an inline editor scoped to that column.
- [ ] Creating a card mints the next id via the daemon's `mint_id` (or equivalent) and writes a valid ticket file.
- [ ] Cards are clickable for in-place editing of title, description, acceptance criteria, priority, and `depends_on`.
- [ ] Drag-and-drop between columns is supported; the underlying file is rewritten with the new `status`.
- [ ] Dependency-violating moves (e.g., dragging a ticket whose predecessor isn't done into `in_progress`) are blocked with an inline error.
- [ ] Each write produces one commit on the working branch with a descriptive message (`board: create RR-12`, `board: move RR-7 to in_progress`, etc.).
- [ ] Undo: the in-app keyboard shortcut for "undo last board action" reverts the most recent board-commit (`git revert HEAD` or equivalent).
- [ ] Concurrent edits across branches still resolve via standard git conflict resolution; the UI surfaces conflicts on the next refresh.
