# Project guidance for Claude Code

This repo is its own dogfood: the relay-runner orchestrator is the sub-agent dispatcher you'll use *here*, not a separate tool. When the user is working in this repo, default to the orchestration workflow described below unless they say otherwise.

## The orchestration workflow

The user thinks of this session as the **orchestrator**, not the executor. The four steps:

1. **Discuss.** Talk through the work. Surface assumptions, push back, propose alternatives. This is the same Karpathy "Think before coding" beat from `~/.claude/CLAUDE.md` — it just runs in a richer context here because the orchestrator owns it end-to-end.
2. **Write tickets.** When the discussion settles on concrete work, file Linear issues against the linked project (`mcp__f2ce8af4-…__save_issue`). Each issue needs a title, a description with acceptance criteria a sub-agent can verify against, and a priority. Keep them small and standalone — a sub-agent has no memory of the discussion.
3. **Dispatch.** Call `mcp__relay-orchestrator__dispatch_issue(identifier=...)`. If the issue's body wouldn't survive cold without this conversation, pass `context=...` with the relevant background. Parallel dispatches are fine when the units of work are independent; expect merge conflicts when sub-agents touch overlapping code.
4. **Integrate.** Merge `relay/<id>` branches into the working branch in a sensible order, resolve conflicts intentionally (don't just accept "theirs"), mark the Linear issues Done, prune worktrees + delete the throwaway branches.

A small change you can do inline in this session **without dispatching** is fine — dispatching has cold-start cost, eats Anthropic quota, and offers no coordination. Use sub-agents when the work is large enough that the round-trip pays off, or when you want a true Linear audit trail.

## Things to avoid

- Don't auto-poll Linear for new issues. The orchestrator MVP is dispatch-driven; every run is an explicit user/orchestrator decision.
- Don't push `relay/<id>` branches. They're throwaway by design; integrate into the working branch (typically `orchestrator-mvp` while we're on the MVP, or `main` after merge) before deleting.
- Don't modify the Linear issue's state, assignee, priority, or labels from inside a sub-agent. Comments only — that boundary is enforced in `services/orchestrator_workflow.md`.
- Don't ad-hoc fix the bundled `.app`'s scripts. The DMG-build action is the source of truth; commit fixes upstream and let the action rebuild.

## Where things live

- `services/orchestrator.py` — the daemon (HTTP + SQLite + worker spawn)
- `services/orchestrator_workflow.md` — default sub-agent prompt template (`{{caller_context}}` slot included)
- `Sources/relay-orchestrator-mcp/` — Swift MCP proxy
- `scripts/relay-orchestrator` — launcher / installer
- `docs/orchestrator.md` — user-facing reference

For the wider behavioral guidelines (Karpathy rules, project-ledger sync, etc.), see `~/.claude/CLAUDE.md` — those still apply on top of this.
