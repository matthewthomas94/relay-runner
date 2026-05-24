# Relay Runner — project guidance for Claude Code

This repo is its own dogfood: the relay-runner orchestrator is the sub-agent dispatcher you'll use *here*, not a separate tool. When the user is working in this repo, default to the orchestration workflow described below unless they say otherwise — and follow the Relay-stack tool defaults below for any screen-control work.

## The orchestration workflow

The user thinks of this session as the **orchestrator**, not the executor. Tickets live in this repo's `.orchestrator/` directory — that's the source of truth. No external service. **The board is gated on an active `/relay-bridge` session** — the bridge's launching cwd is what tells the menu-bar app which repo's `.orchestrator/` to render, so without a live bridge (`/tmp/voice_bridge.sock` present) the board hotkey just surfaces a brief toast. **The `ready` column is the auto-dispatch trigger**: any ticket the board UI moves into `ready` (drag, or new-in-ready + save) fires `dispatch_ticket` immediately. Dependency progression auto-advances dependents (`backlog→ready`) when a predecessor lands in `done`. The four steps:

1. **Discuss.** Talk through the work. Surface assumptions, push back, propose alternatives. This is the same Karpathy "Think before coding" beat from `~/.claude/CLAUDE.md` — it just runs in a richer context here because the orchestrator owns it end-to-end.
2. **Write tickets in `backlog`.** When the discussion settles on concrete work, write a ticket file under `<repo>/.orchestrator/<TICKET_ID>.md` following the schema in `docs/specs/orchestrator-tickets.md`. Use the next free id from `.orchestrator/config.toml` (`next_id`) and bump that counter in the same commit. Default `status: backlog`. Each ticket needs a title, a `## Description`, `## Acceptance criteria` a sub-agent can verify against, a priority, and `depends_on` if it needs another ticket to land first. Keep them small and standalone — a sub-agent has no memory of the discussion. Commit the new ticket on the working branch.
3. **Refine and promote.** When a ticket is concrete enough that you'd hand it to a colleague cold, drag it from `backlog` to `ready` in the board (or change the frontmatter to `status: ready` and save via the editor). The board immediately calls `dispatch_ticket(ticket_id, repo_path)`; a worker spawns in an isolated worktree. The first ticket of a chain is the only one you drag — its `depends_on` predecessors auto-promote when each one completes. For a one-off manual dispatch (e.g. retry, skip the queue), the MCP tool `mcp__relay-orchestrator__dispatch_ticket` still works directly. Use `context="..."` when the ticket body wouldn't survive cold without this conversation.
4. **Integrate.** Each sub-agent commits to its `relay/<id>` branch — both the code change and the ticket-file update (status flipped to `done` + a `## Run log` entry). Merge those branches into the working branch in a sensible order, resolve conflicts intentionally (don't just accept "theirs"), then prune worktrees + delete the throwaway branches. The merge is what publishes the `done` status to the board, which is what triggers any dependents waiting on this ticket to flip to `ready` and dispatch in turn.

A small change you can do inline in this session **without going through the board** is fine — dispatching has cold-start cost, eats Anthropic quota, and offers no coordination. Promote to `ready` when the work is large enough that the round-trip pays off, or when you want an in-repo audit trail (ticket + run log) without writing it by hand.

### Things to avoid

- Don't drag tickets to `ready` casually — promotion equals dispatch. Refine first.
- Don't push `relay/<id>` branches. They're throwaway by design; integrate into the working branch (typically `main`) before deleting.
- Don't let a sub-agent edit `.orchestrator/` files other than its own ticket. That boundary is enforced in `services/orchestrator_workflow.md`. The daemon writes ticket files in exactly one case: flipping a dependent from `backlog` to `ready` after its predecessor finishes.
- Don't ad-hoc fix the bundled `.app`'s scripts. The DMG-build action is the source of truth; commit fixes upstream and let the action rebuild.

## Always use the custom Relay stack — never native screen-control fallbacks

This project ships its own MCP server for voice-driven screen control. When working in this repo, **always use the custom path — never native MCP fallbacks** — even when both are connected.

The custom stack has two pieces:

### 1. RelayActions — the screen-control tools

For all screen control — `screenshot`, `click`, `type`, `scroll`, `key`, `list_windows`, `frontmost_app` — use the `mcp__relay-actions__*` tools. Do **not** use `mcp__computer-use__*` for anything covered by RelayActions.

If you genuinely need an operation RelayActions doesn't yet expose, surface that gap to the human before falling through to `mcp__computer-use__*`. The default answer is "extend RelayActions," not "fall back to native."

### 2. RelayVision — the perimeter-glow overlay

RelayVision is the project's perimeter overlay (the `OverlayState.relayVision` state in `Sources/relay-runner/Overlay/`). It pulses around the screen edges whenever a RelayActions tool fires — so the user has a visual signal that screen control is happening. You don't call this directly; it's automatic, driven by the `tool_fired` notification every RelayActions tool sends after running.

RelayVision is a **visual signal**, not a confirmation gate.

## Asking for permission — don't use `propose_action`

`mcp__relay-actions__propose_action` is registered in the MCP server, but **don't call it.** Its medium/high-risk path was designed to block on a double-tap Option/Control gesture for confirmation. That pattern was abandoned because those modifier double-taps are already bound to play/cancel TTS in voice mode, and the dual binding caused real UX problems. Calling it now will block on a confirmation the user is no longer expecting and time out after 30 seconds.

If you need user permission for a risky screen action:

1. **Default: just execute.** The user has already authorized voice control by starting the session. The RelayVision perimeter glow is the visual signal that screen control is happening.
2. **If the action is genuinely high-stakes** (irreversible, sends a message, spends money, deletes data) and you're not confident the user wants it: **ask via a normal text message in the chat** with a clear summary, and wait for an explicit "yes" before proceeding. Do **not** call `propose_action`.
3. **Never** route confirmations through native computer-use prompts. Same reason — bypasses the project's stack.

### Why this rule exists

RelayActions + RelayVision is the product. Native MCPs work fine in any other repo, but in this one they bypass the project's instrumentation and visual surface. The custom path is non-negotiable here.

This rule overrides the generic "tier of tool" guidance the computer-use MCP injects when both are connected.

## Naming notes

- **Relay Actions** = the screen-control feature and its MCP tool family (`mcp__relay-actions__*`). The tools themselves.
- **RelayVision** = the perimeter-glow overlay that pulses whenever a RelayActions tool runs. Visual signal, not a confirmation gate. (`OverlayState.relayVision` in code.)
- Together: **the Relay stack**. Don't conflate either with native "computer-use" or "computer-vision" — those are different MCPs from a different vendor.

## Where things live

- `services/orchestrator.py` — the daemon (HTTP + SQLite + worker spawn)
- `services/orchestrator_workflow.md` — default sub-agent prompt template (`{{caller_context}}` slot included)
- `Sources/relay-orchestrator-mcp/` — Swift MCP proxy
- `Sources/relay-actions-mcp/` — Swift MCP server for RelayActions screen-control tools
- `Sources/relay-runner/Overlay/` — RelayVision overlay (state machine, perimeter panel, particle field)
- `Sources/relay-runner/Board/` — local kanban board overlay (RR-* tickets in `.orchestrator/`)
- `scripts/relay-orchestrator` — launcher / installer
- `docs/orchestrator.md` — orchestrator user-facing reference
- `docs/specs/relay-actions.md` — Relay Actions feature spec
- `docs/specs/orchestrator-tickets.md` — local board ticket schema

For the wider behavioral guidelines (Karpathy rules, project-ledger sync, etc.), see `~/.claude/CLAUDE.md` — those still apply on top of this.
