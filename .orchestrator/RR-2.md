---
id: RR-2
title: Daemon reads .orchestrator/ as the source of truth on dispatch
status: ready
priority: high
depends_on: []
run_id: null
canceled: false
---

## Description

Wire the orchestrator daemon to use `.orchestrator/<id>.md` files as the system of record. `mcp__relay-orchestrator__dispatch_issue(identifier="RR-7")` should:

1. Resolve `RR-7` to `<repo>/.orchestrator/RR-7.md`.
2. Verify the ticket is in `status: ready`, has no unsatisfied `depends_on`, and is not already in a running state.
3. Stamp the ticket: set `status: in_progress` and `run_id: <new run id>` in the frontmatter, commit that edit to the working branch.
4. Spawn the sub-agent as today — isolated worktree on `relay/<id>`, render workflow prompt, `claude -p`.
5. On run completion (success), the sub-agent's commits land on `relay/<id>` as today; the integration step flips `status: done`.

Linear continues to work in parallel for now — the daemon may *also* read from Linear if no `.orchestrator/<id>.md` exists. That fallback is removed once the Linear projector ships (or sooner if desired).

## Acceptance criteria

- [ ] `dispatch_issue` with a `<PREFIX>-<N>` identifier resolves to `.orchestrator/<id>.md` in the linked project's repo.
- [ ] The daemon refuses dispatch if the ticket is not `ready`, has unsatisfied deps, or already has a non-terminal `run_id`.
- [ ] On successful dispatch, the ticket file's frontmatter is updated (`status: in_progress`, `run_id: <N>`) and committed atomically on the working branch.
- [ ] The sub-agent's workflow prompt is rendered with the ticket's body in place of (or alongside) the Linear-issue-body placeholder it uses today.
- [ ] If no `.orchestrator/<id>.md` exists, the daemon falls back to the existing Linear-MCP path so we don't break in-flight workflows.
- [ ] `list_runs` continues to work; runs still link back to a ticket identifier.
- [ ] Schema validation runs on daemon startup and on every `dispatch_issue` call. Validation failures are returned as structured errors, not crashes.
- [ ] Documentation updated: `docs/orchestrator.md` describes the new dispatch flow and notes the fallback period.
