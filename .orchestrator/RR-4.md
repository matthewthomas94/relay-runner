---
id: RR-4
title: Optional Linear projector — outbound mirror to Linear
status: ready
priority: low
depends_on: [RR-2]
run_id: null
canceled: false
---

## Description

Add an optional outbound mirror from `.orchestrator/` to a linked Linear project, so teams that want stakeholder-facing visibility can opt in without giving up local-first authoring.

The mirror is **strictly outbound**: file changes in `.orchestrator/` produce Linear `save_issue` / `save_comment` calls. Inbound sync (Linear → file) is explicitly out of scope; that would re-introduce the dual-source-of-truth problem this design was built to escape.

Opt-in via `config.toml`:

```toml
[linear_projector]
enabled = true
linear_project_id = "..."   # which Linear project to mirror to
```

When enabled, the daemon on each commit to `.orchestrator/`:

1. Diffs the change.
2. For each ticket whose status, priority, or body changed, calls Linear MCP to update the corresponding issue (creating one if it doesn't exist; matching by repo-prefix-id mapped to an external-id field).
3. For new tickets, creates them in Linear with the title, description, and status.
4. For deleted tickets, archives the Linear issue.

## Acceptance criteria

- [ ] `config.toml` schema extended with optional `[linear_projector]` block. When absent, no Linear traffic.
- [ ] When enabled, ticket changes in `.orchestrator/` produce corresponding Linear updates via `mcp__linear__save_issue` / `save_comment`.
- [ ] Linear issues created by the projector store the repo-prefix-id (e.g., `RR-7`) in a discoverable place — an external-id field, a label, or in the description body — so re-syncs can find them.
- [ ] If a Linear API call fails, log and continue; do not block the commit or roll back the file change.
- [ ] Disabling the projector (removing the config block) leaves existing Linear issues alone — no cleanup, no archive-on-disable.
- [ ] Documentation: `docs/orchestrator.md` describes the projector as opt-in, outbound-only, and explains why inbound sync is not supported.
