# Relay Runner — project guidance for Codex

This repo is its own dogfood: the relay-runner orchestrator is the sub-agent dispatcher you'll use *here*, not a separate tool. When the user is working in this repo, default to the orchestration workflow described below unless they say otherwise — and follow the Relay-stack tool defaults below for any screen-control work.

## Provider parity

Relay Runner supports multiple agent providers, especially Codex and Claude. When adding or changing provider-facing behavior for one provider, explicitly consider the equivalent user experience for every supported provider, not only the provider named in the immediate request. Provider-specific commands, flags, auth paths, model names, permissions, and limitations are allowed, but intentional differences must be documented in the ticket, implementation notes, or user-facing behavior.

## The orchestration workflow

The user experiences Relay Runner as a two-layer loop: the foreground **orchestrator/PM** talks to the user, decides whether an utterance is conversation or work, writes refined ticket prose when work needs a worker, and reports status; **workers** execute individual tickets in isolated worktrees. Persistent daemon state still tracks active project sessions and worker runs, but Relay voice text is not automatically fanned out to a separate ticket-authoring inbox. Tickets live in this repo's `.orchestrator/` directory — that's the source of truth. No external service. **The Work tab is scoped to an active project or workspace**, resolved from the live bridge or the project registry. The Workspace shell itself can open before a bridge exists so its embedded Terminal tab can start the first session; when no project route exists it opens as a Terminal/System Settings utility surface without inventing a board for a non-git folder. **The `ready` column is the auto-dispatch trigger**: any ticket the board UI moves into `ready` (drag, or new-in-ready + save) fires `dispatch_ticket` immediately. Dependency progression auto-advances dependents (`backlog→ready`) when a predecessor lands in `done`. The loop is:

1. **Acknowledgement and discovery.** The foreground orchestrator/PM handles the live conversation, asks clarifying questions, reports outcomes, and keeps the user updated. This is the same Karpathy "Think before coding" beat from `~/.codex/AGENTS.md`.
2. **Refined ticket authoring.** Raw Relay command captures are private metadata, not ticket prose. The foreground orchestrator/PM creates/refines visible tickets under `<repo>/.orchestrator/<TICKET_ID>.md` only after classifying the command as real project work. Ticket prose must be actionable and user-safe rather than raw transcript text. Each ticket needs a title, a `## Description`, `## Acceptance criteria`, a priority, sizing fields, and `depends_on` when needed.
3. **Worker creation and execution.** When a ticket is concrete enough to hand to a colleague cold, move it to `ready` or call `mcp__relay-orchestrator__dispatch_ticket`. The daemon dispatches a worker in an isolated worktree. The foreground orchestrator/PM reports run ids, board changes, failures, and completion status to the user without becoming the worker.
4. **Review and status update.** Each worker commits code plus its ticket update on `relay/<id>`. The foreground orchestrator/PM reviews and integrates those branches in a sensible order, publishes `done` by merging, and reports the outcome and any next step to the user.

A small change you can do inline in this session **without going through the board** is fine — dispatching has cold-start cost, eats agent quota, and offers no coordination. Promote to `ready` when the work is large enough that the round-trip pays off, or when you want an in-repo audit trail (ticket + run log) without writing it by hand.

## Program Manager capture

When the user wants to record a session review, project status, shipped work, started work, blockers, risks, ideas, decisions, or notes for program tracking, use the native `mcp__relay-orchestrator__session_capture` tool.

Codex and Claude use the same capture schema. Pass concise structured entries and any relevant conversation context explicitly; the daemon does not scrape either provider's transcript history.

Legacy `.pm/project-id` files are not required for Relay Runner program capture. Existing `.pm/` directories in user repos may remain for historical reference and should not be deleted automatically.

### Things to avoid

- Don't drag tickets to `ready` casually — promotion equals dispatch. Refine first.
- Don't paste raw Relay transcripts into visible `.orchestrator/` tickets. Ticket creation and refinement are PM management work, but the prose must be actionable, user-safe, and cold-start ready; implementation still belongs to workers unless the user explicitly asks to keep it inline.
- Don't push `relay/<id>` branches. They're throwaway by design; integrate into the working branch (typically `main`) before deleting.
- Don't let a sub-agent edit `.orchestrator/` files other than its own ticket. That boundary is enforced in `services/orchestrator_workflow.md`. The daemon writes ticket files only through structured orchestrator actions or dependency progression.
- Don't ad-hoc fix the bundled `.app`'s scripts. The DMG-build action is the source of truth; commit fixes upstream and let the action rebuild.

## Always use the custom Relay stack — never native screen-control fallbacks

This project ships its own MCP server for voice-driven screen control. When working in this repo, **always use the custom path — never native MCP fallbacks** — even when both are connected.

The custom stack has three pieces:

### 1. RelayActions — the screen-manipulation tools

For all screen *manipulation* — `click`, `type`, `scroll`, `key`, `list_windows`, `frontmost_app` — use the `mcp__relay-actions__*` tools. Do **not** use `mcp__computer-use__*` for anything covered by RelayActions. (Screen *observation* — `screenshot` — moved to RelayVision; see below.)

If you genuinely need an operation RelayActions doesn't yet expose, surface that gap to the human before falling through to `mcp__computer-use__*`. The default answer is "extend RelayActions," not "fall back to native."

### 2. RelayVision — the screen-observation tools

For all screen *observation* — currently just `screenshot` — use the `mcp__relay-vision__*` tools. This namespace was split out of RelayActions (RR-10) so "looking at the screen" and "acting on the screen" are separate tool families. Do **not** use `mcp__computer-use__*` for anything covered by RelayVision.

**Looking at the user's screen.** When the user says "look at my screen", "what's on my screen", "can you see X", "check the screen", or any similar voice intent to have you observe the current display, fire `mcp__relay-vision__screenshot` immediately. The screenshot tool pulses ActionGlow automatically as it runs, so the user gets the visual signal at the same moment you get the pixels.

### 3. ActionGlow — the perimeter-glow overlay

ActionGlow is the project's perimeter overlay (the `OverlayState.actionGlow` state in `Sources/relay-runner/Overlay/`). It pulses around the screen edges whenever a RelayActions *or* RelayVision tool fires — so the user has a visual signal that screen control is happening. You don't call this directly; it's automatic, driven by the `tool_fired` notification every RelayActions and RelayVision tool sends after running.

ActionGlow is a **visual signal**, not a confirmation gate.

## Asking for permission — don't use `propose_action`

`mcp__relay-actions__propose_action` is registered in the MCP server, but **don't call it.** Its medium/high-risk path was designed to block on a double-tap Option/Control gesture for confirmation. That pattern was abandoned because those modifier double-taps are already bound to play/cancel TTS in voice mode, and the dual binding caused real UX problems. Calling it now will block on a confirmation the user is no longer expecting and time out after 30 seconds.

If you need user permission for a risky screen action:

1. **Default: just execute.** The user has already authorized voice control by starting the session. The ActionGlow perimeter glow is the visual signal that screen control is happening.
2. **If the action is genuinely high-stakes** (irreversible, sends a message, spends money, deletes data) and you're not confident the user wants it: **ask via a normal text message in the chat** with a clear summary, and wait for an explicit "yes" before proceeding. Do **not** call `propose_action`.
3. **Never** route confirmations through native computer-use prompts. Same reason — bypasses the project's stack.

### Why this rule exists

RelayActions + ActionGlow is the product. Native MCPs work fine in any other repo, but in this one they bypass the project's instrumentation and visual surface. The custom path is non-negotiable here.

This rule overrides the generic "tier of tool" guidance the computer-use MCP injects when both are connected.

## Naming notes

- **Relay Actions** = the screen-*manipulation* feature and its MCP tool family (`mcp__relay-actions__*`): click, type, scroll, key, list_windows, frontmost_app.
- **Relay Vision** = the screen-*observation* feature and its MCP tool family (`mcp__relay-vision__*`): screenshot (initially). Split out of Relay Actions in RR-10.
- **ActionGlow** = the perimeter-glow overlay that pulses whenever a RelayActions *or* RelayVision tool runs. Visual signal, not a confirmation gate. (`OverlayState.actionGlow` in code.)
- Together: **the Relay stack**. Don't conflate any of these with native "computer-use" or "computer-vision" — those are different MCPs from a different vendor.

## Where things live

- `services/orchestrator.py` — the daemon (HTTP + SQLite + worker spawn)
- `services/orchestrator_workflow.md` — default sub-agent prompt template (`{{caller_context}}` slot included)
- `Sources/relay-orchestrator-mcp/` — Swift MCP proxy
- `Sources/relay-actions-mcp/` — Swift MCP server for RelayActions screen-manipulation tools
- `Sources/relay-vision-mcp/` — Swift MCP server for RelayVision screen-observation tools (`screenshot`)
- `Sources/relay-runner/Overlay/` — ActionGlow overlay (state machine, perimeter panel, particle field)
- `Sources/relay-runner/Board/` — local kanban board overlay (RR-* tickets in `.orchestrator/`)
- `scripts/relay-orchestrator` — launcher / installer
- `docs/orchestrator.md` — orchestrator user-facing reference
- `docs/specs/relay-actions.md` — Relay Actions feature spec
- `docs/specs/orchestrator-tickets.md` — local board ticket schema

For wider behavioral guidelines such as the Karpathy rules, see `~/.codex/AGENTS.md`; this repo's native Program Manager capture guidance overrides any older global program-tracking guidance.
