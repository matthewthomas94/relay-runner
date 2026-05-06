# Relay Runner — project guidance for Claude Code

This repo is its own dogfood: the relay-runner orchestrator is the sub-agent dispatcher you'll use *here*, not a separate tool. When the user is working in this repo, default to the orchestration workflow described below unless they say otherwise — and follow the Relay-stack tool defaults below for any screen-control work.

## The orchestration workflow

The user thinks of this session as the **orchestrator**, not the executor. The four steps:

1. **Discuss.** Talk through the work. Surface assumptions, push back, propose alternatives. This is the same Karpathy "Think before coding" beat from `~/.claude/CLAUDE.md` — it just runs in a richer context here because the orchestrator owns it end-to-end.
2. **Write tickets.** When the discussion settles on concrete work, file Linear issues against the linked project (`mcp__f2ce8af4-…__save_issue`). Each issue needs a title, a description with acceptance criteria a sub-agent can verify against, and a priority. Keep them small and standalone — a sub-agent has no memory of the discussion.
3. **Dispatch.** Call `mcp__relay-orchestrator__dispatch_issue(identifier=...)`. If the issue's body wouldn't survive cold without this conversation, pass `context=...` with the relevant background. Parallel dispatches are fine when the units of work are independent; expect merge conflicts when sub-agents touch overlapping code.
4. **Integrate.** Merge `relay/<id>` branches into the working branch in a sensible order, resolve conflicts intentionally (don't just accept "theirs"), mark the Linear issues Done, prune worktrees + delete the throwaway branches.

A small change you can do inline in this session **without dispatching** is fine — dispatching has cold-start cost, eats Anthropic quota, and offers no coordination. Use sub-agents when the work is large enough that the round-trip pays off, or when you want a true Linear audit trail.

### Things to avoid

- Don't auto-poll Linear for new issues. The orchestrator MVP is dispatch-driven; every run is an explicit user/orchestrator decision.
- Don't push `relay/<id>` branches. They're throwaway by design; integrate into the working branch (typically `orchestrator-mvp` while we're on the MVP, or `main` after merge) before deleting.
- Don't modify the Linear issue's state, assignee, priority, or labels from inside a sub-agent. Comments only — that boundary is enforced in `services/orchestrator_workflow.md`.
- Don't ad-hoc fix the bundled `.app`'s scripts. The DMG-build action is the source of truth; commit fixes upstream and let the action rebuild.

## Always use the custom Relay stack — never native screen-control fallbacks

This project ships an end-to-end stack for voice-driven screen control with on-screen confirmation. When working in this repo, **always use the custom path — never native MCP fallbacks** — even when both are connected.

The custom stack has two layers, both first-class:

### 1. RelayActions — the screen-control tools

For all screen control — `screenshot`, `click`, `type`, `scroll`, `key`, `list_windows`, `frontmost_app`, `propose_action` — use the `mcp__relay-actions__*` tools. Do **not** use `mcp__computer-use__*` for anything covered by RelayActions.

If you genuinely need an operation RelayActions doesn't yet expose, surface that gap to the human before falling through to `mcp__computer-use__*`. The default answer is "extend RelayActions," not "fall back to native."

### 2. RelayVision — the on-screen confirmation overlay

RelayVision is the project's perimeter overlay surface (the `OverlayState.relayVision` state in `Sources/relay-runner/Overlay/`). It activates when the MCP server calls `propose_action`, and it's how the user sees and confirms what's about to happen on their screen.

Before any **state-changing** click / type / key / scroll, call `mcp__relay-actions__propose_action` so RelayVision surfaces the confirmation:
- `risk: "medium"` — single-step state changes (click a button, type into a field, key combo).
- `risk: "high"` — irreversible / destructive (Send, Delete, Pay, Submit, Publish).
- `risk: "low"` — read-only / reversible (scroll, hover, screenshot). Auto-confirms; usually you can call the underlying tool directly without `propose_action`.

Do **not** route confirmations through native computer-use prompts, ad-hoc chat questions, or any other channel for risky screen actions. That bypasses RelayVision — which is the surface the project exists to drive.

### Why this rule exists

RelayActions + RelayVision is the product. Native MCPs work fine in any other repo, but in this one they bypass the instrumentation, the visual confirmation surface, and the double-tap Option/Control gesture that make the system safe enough to leave running. The custom path is non-negotiable here.

This rule overrides the generic "tier of tool" guidance the computer-use MCP injects when both are connected.

## Naming notes

- **Relay Actions** = the screen-control feature and its MCP tool family (`mcp__relay-actions__*`). The tools themselves.
- **RelayVision** = the perimeter overlay + double-tap confirmation gesture. The on-screen surface that lets the user see and approve what's about to happen. (`OverlayState.relayVision` in code.)
- Together: **the Relay stack**. Don't conflate either with native "computer-use" or "computer-vision" — those are different MCPs from a different vendor.

## Where things live

- `services/orchestrator.py` — the daemon (HTTP + SQLite + worker spawn)
- `services/orchestrator_workflow.md` — default sub-agent prompt template (`{{caller_context}}` slot included)
- `Sources/relay-orchestrator-mcp/` — Swift MCP proxy
- `Sources/relay-actions-mcp/` — Swift MCP server for RelayActions screen-control tools
- `Sources/relay-runner/Overlay/` — RelayVision overlay (state machine, perimeter panel, particle field)
- `scripts/relay-orchestrator` — launcher / installer
- `docs/orchestrator.md` — orchestrator user-facing reference
- `docs/specs/relay-actions.md` — Relay Actions feature spec

For the wider behavioral guidelines (Karpathy rules, project-ledger sync, etc.), see `~/.claude/CLAUDE.md` — those still apply on top of this.
