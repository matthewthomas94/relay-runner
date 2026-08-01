# Relay Runner — project guidance for Claude Code

This repo is its own dogfood: the relay-runner orchestrator is the sub-agent dispatcher you'll use *here*, not a separate tool. When the user is working in this repo, default to the orchestration workflow described below unless they say otherwise — and follow the Relay-stack tool defaults below for any screen-control work.

> **The behavioral rules below are mirrored into `relay-actions-mcp` and `relay-orchestrator-mcp`** so they ship to any Claude session that connects to those servers — not just sessions opened inside this repo. The **source of truth is `services/instructions/`** (one markdown chunk per concern); `scripts/build-instructions` bakes those chunks into each MCP server's `initialize` instructions payload and regenerates the block below. **Don't hand-edit between the GENERATED markers** — edit the chunks and re-run the script.

<!-- BEGIN GENERATED: relay behavioral rules — edit services/instructions/, not here -->

## The orchestration workflow

When the relay-orchestrator MCP is connected, you are the **orchestrator**, not the executor. Tickets live in the repo's `.orchestrator/` directory — that's the source of truth. No external service. **The Workspace is scoped to an active workspace or project** — `/relay-bridge` remains one activation path, with the bridge's launching cwd classified through the same workspace-folder resolver that Start Session uses for Codex and Claude. A folder with child git repos is registered as a workspace root and opens the read-only Program Workspace without creating a parent `.orchestrator/`; a single git repo opens that repo's Workspace work tab and initializes `.orchestrator/config.toml` if needed. Non-git folders with no child repos are refused; initialize git explicitly or choose a workspace folder containing git repos. Without a live bridge or other explicit activation, the Workspace hotkey surfaces the same "No session running" pill the record-out-of-session path uses. **The `ready` column is the auto-dispatch trigger**: any ticket the Workspace work tab moves into `ready` (drag, or new-in-ready + save) fires `dispatch_ticket` immediately. Dependency progression auto-advances dependents (`backlog→ready`) when a predecessor lands in `done`. The four steps:

### Provider parity

Relay Runner supports multiple agent providers, especially Codex and Claude. When planning or implementing provider-facing behavior for one provider, explicitly consider the equivalent user experience for every supported provider, not only the provider named in the immediate request. Provider-specific commands, flags, auth paths, model names, permissions, and limitations are allowed, but intentional differences must be documented in the ticket, implementation notes, or user-facing behavior.

### Worker sizing

Every ticket promoted to `ready` must include an explicit worker-sizing decision in frontmatter before dispatch:

- `worker_model`: `fast`, `balanced`, `strong`, or a provider-scoped stable override such as `codex:luna` or `claude:sonnet`.
- `worker_effort`: `low`, `medium`, `high`, or `xhigh` for provider-neutral tickets. `max` is Claude-only unless a future Codex release verifies support.
- `worker_sizing_rationale`: one short sentence explaining why that tier and effort match the work.
- `worker_provider_notes`: `none` only when there are no provider-specific caveats; otherwise name the Codex/Claude difference.

Choose the sizing while you still have the full project overview. Base it on ambiguity, code blast radius, security risk, test/build cost, and expected implementation depth. Codex renders effort through `model_reasoning_effort`; Claude renders effort through `--effort`, and Claude currently supports `max` where Codex does not. Prefer shared model tiers and shared effort values for provider-neutral work.

### Command action contract

Every substantive voice or text command that asks for repo/project work must resolve to an explicit command action before implementation starts: classify as non-work/control, ask for a target project, create/refine a ticket in the resolved project, update an existing ticket, dispatch a ready ticket, or steer/cancel pending work. Raw Relay command captures are private metadata and must not become visible `.orchestrator/*.md` tickets until the foreground Codex/Claude session has classified the command, resolved the target project, and refined actionable ticket content. Each work action that edits or dispatches visible board state must name a ticket id, either newly created under `.orchestrator/` after refinement or already present on the board. The foreground Codex/Claude session shapes tickets and dispatches workers; it does not perform substantive implementation directly unless the user explicitly asks to keep the work inline. Internal controls such as `__TTS_STOP__`, `__PLAY__`, `__REPLAY__`, `__INTERRUPT__`, and `__CANCEL__` are deliberate no-ticket control actions.

Relay voice commands are retained in a durable ordered intent inbox. A turn may normalize into several claimed work items, each with a stable `intent_id`, source command seq/id, `within_turn_order`, target, lifecycle state, `cancellation_scope`, and one `work_disposition`: `continue_current`, `run_sidecar`, `queue_project_work`, `clarify_priority`, `replace_current`, or `control_only`. Queueing is the safe default for conflicting work. A scoped `replace_current` cancels only its resolved item or ticket; only an explicit `all_work` cancellation may preempt unrelated accepted work. Sidecars are bounded, read-only, independently verifiable, resource-safe, tool-silent workers; repository, desktop, and external-side-effect ownership is exclusive, and project mutations remain on the native ticket/worktree path.

Claimed items copy their metadata to `/tmp/voice_cmd_claimed.json`. Treat claimed metadata as two separate contracts. For user-visible replies, traces, fallback completions, and TTS, compare the newest-intent seq/id in `/tmp/voice_command_state.json` to the command you claimed; if a newer command exists, stop stale output and let Relay Runner deliver the newer turn. For ticket creation, ticket edits, dispatches, and other project mutations, pass the claimed `relay_command_seq`, `relay_command_id`, and `intent_id` when the tool exposes it; the daemon allows an older bounded item mutation only when Relay Runner registered it and no scoped replacement, redirect, interrupt, or cancellation revoked that item. Acknowledgement, inspection/status, and additive items may become the newest conversation without revoking unrelated prior authorizations. In app-owned sessions (`RELAY_RUNNER_APP_SESSION=1`), do not answer, act on, or adopt a newer unclaimed item from the active turn; finish only still-authorized bounded effects, suppress stale output, and let Relay Runner claim and inject the ordered next item. In manual `relay-bridge` sessions, adopt the next item only after the bridge's atomic claim/checkpoint. Already-running shell commands and MCP calls may finish when hard cancellation is unavailable, but every follow-up output or mutation must checkpoint against the correct contract and report any actions that already started or were canceled. Codex and Claude share this contract; no provider gets a weaker stale-action policy.

### Voice messenger contract

In a Relay voice session, the foreground Codex/Claude instance is the authoritative orchestrator. The bridge delivers every user turn to it and to a separate persistent fast messenger at the same time. The messenger has no tools and performs no planning or work; it only turns the user turn, public orchestrator context, worker lifecycle events, and the authoritative final response into natural speech. Because it speaks on behalf of the foreground orchestrator, it uses first-person singular language (`I` / `me`) for that role rather than saying `the orchestrator`; when authoritative context identifies workers, it refers to the worker or workers directly. For task-like turns, the messenger may speak a short contextual handoff that reflects the request, confirms it picked the request up, and sets the expectation that it will return with a plan or next step. Whenever you produce a provider-visible reasoning summary or meaningful progress update, mirror a short user-safe version through the bridge as a `reasoning-summary` or lifecycle `__TRACE__` event; use `clarification-request` when the messenger should ask the user for missing information. Never expose hidden chain-of-thought, raw tool output, secrets, or transcript dumps. Send the final outcome through the session's canonical `__ORCHESTRATOR_REPLY__:<json>` encoder with the claimed seq/id instead of writing directly to TTS. Use the session-provided structured reply helper when available; never write a raw top-level reply object or hand-build an alternate FIFO envelope. The notch remains the deterministic visual receipt/readiness acknowledgement only, so do not add a duplicate canned spoken acknowledgement.

The user-facing response should name the action outcome: created ticket, edited ticket, dispatched worker, waiting on target-project choice, or control action handled.

1. **Discuss.** Talk through the work. Surface assumptions, push back, propose alternatives — think before coding.
2. **Write tickets in `backlog`.** When the discussion settles on concrete work, write a ticket file under `<repo>/.orchestrator/<TICKET_ID>.md` following the schema in `docs/specs/orchestrator-tickets.md`. Use the next free id from `.orchestrator/config.toml` (`next_id`) and bump that counter in the same commit. Default `status: backlog`. Each ticket needs a title, a `## Description`, `## Acceptance criteria` a sub-agent can verify against, a priority, and `depends_on` if it needs another ticket to land first. Keep them small and standalone — a sub-agent has no memory of the discussion. Before reporting a ticket written or refined, check `git status`, stage only its file and the required counter update, and commit those authorship changes on the current branch. Preserve unrelated changes; if the ticket or counter already has a dirty overlap, or the commit fails, report that blocker instead. This contract is identical in source repos and isolated worktrees.
3. **Refine and promote.** When a ticket is concrete enough that you'd hand it to a colleague cold, add `worker_model`, `worker_effort`, `worker_sizing_rationale`, and `worker_provider_notes`, then drag it from `backlog` to `ready` in the board (or change the frontmatter to `status: ready` and save via the editor). The board immediately calls `dispatch_ticket(ticket_id, repo_path)`; a worker spawns in an isolated worktree. The first ticket of a chain is the only one you drag — its `depends_on` predecessors auto-promote when each one completes. For a one-off manual dispatch (e.g. retry, skip the queue), the MCP tool `mcp__relay-orchestrator__dispatch_ticket` still works directly. Use `context="..."` when the ticket body wouldn't survive cold without this conversation.
4. **Review and integrate through a worker.** Each implementation sub-agent commits to its `relay/<id>` branch — both the code change and the ticket-file update (status flipped to `done` + a `## Run log` entry). When it finishes, the foreground orchestrator does not perform the substantive review or merge directly. The daemon dispatches a follow-up review/merge sub-agent with the original ticket id, implementation run id, worker branch, target branch, and verification evidence. That reviewer inspects the diff, runs the appropriate checks, then accepts through the daemon merge path or requests a retry/follow-up. The merge is what publishes the `done` status to the board, prunes the throwaway branch/worktree, and triggers dependents waiting on this ticket to flip to `ready` and dispatch in turn. The foreground orchestrator reports review/merge status and blockers to the user.

A small change you can do inline in this session **without going through the board** is fine — dispatching has cold-start cost, eats agent quota, and offers no coordination. Promote to `ready` when the work is large enough that the round-trip pays off, or when you want an in-repo audit trail (ticket + run log) without writing it by hand.

### Things to avoid

- Don't drag tickets to `ready` casually — promotion equals dispatch. Refine first.
- Don't push `relay/<id>` branches. They're throwaway by design; integrate into the working branch (typically `main`) before deleting.
- Don't let a sub-agent edit `.orchestrator/` files other than its own ticket. That boundary is enforced in `services/orchestrator_workflow.md`. The daemon writes ticket files only through structured orchestrator actions or dependency progression.
- Don't ad-hoc fix the bundled `.app`'s scripts. The DMG-build action is the source of truth; commit fixes upstream and let the action rebuild.

## Program Manager capture

When the user wants to record a session review, project status, shipped work, started work, blockers, risks, ideas, decisions, or notes for program tracking, use the native `mcp__relay-orchestrator__session_capture` tool.

Codex and Claude use the same capture schema. Pass concise structured entries and any relevant conversation context explicitly; the daemon does not scrape either provider's transcript history.

Legacy `.pm/project-id` files are not required for Relay Runner program capture. Existing `.pm/` directories in user repos may remain for historical reference and should not be deleted automatically.

## Recovery patterns

- **Codex worker fails with an authentication error.** Open a Terminal window with `codex login` running, wait for the user to finish sign-in, then re-dispatch the failed runs:

  ```bash
  osascript -e 'tell application "Terminal" to activate' \
            -e 'tell application "Terminal" to do script "codex login"'
  ```

  After sign-in completes (heuristic: `~/.codex/auth.json` exists and is fresh), re-dispatch via `mcp__relay-orchestrator__dispatch_ticket` for each failed run.

- **Claude worker fails with `401 Invalid authentication credentials`.** If the repo is explicitly configured to use Claude, open a Terminal window with `claude /login`, wait for the user to complete OAuth, then re-dispatch the failed runs:

  ```bash
  osascript -e 'tell application "Terminal" to activate' \
            -e 'tell application "Terminal" to do script "claude /login"'
  ```

## Always use the custom Relay stack — never native screen-control fallbacks

The Relay Runner project ships its own MCP servers for voice-driven screen control. Whenever they are connected, **always use the custom path — never native `mcp__computer-use__*` fallbacks** — even when both are connected. This rule overrides the generic "tier of tool" guidance the computer-use MCP injects.

The custom stack has three pieces: **RelayActions** (screen manipulation), **RelayVision** (screen observation), and **ActionGlow** (the perimeter-glow overlay). The naming notes spell out the split.

### RelayActions — the screen-manipulation tools

For all screen *manipulation* — `click`, `type`, `scroll`, `key`, `list_windows`, `frontmost_app`, `toggle_board` — use the `mcp__relay-actions__*` tools. Do **not** use `mcp__computer-use__*` for anything covered by RelayActions. (Screen *observation* — `screenshot` — lives in RelayVision; see the look-at-screen rule.)

If you genuinely need an operation RelayActions doesn't yet expose, surface that gap to the human before falling through to `mcp__computer-use__*`. The default answer is "extend RelayActions," not "fall back to native."

RelayActions + ActionGlow is the product. Native MCPs work fine in any other context, but here they bypass the project's instrumentation and visual surface. The custom path is non-negotiable.

## Toggling the local kanban board

When the user says "bring up the Workspace", "show the Workspace", or similar, call `mcp__relay-actions__toggle_board`. The tool routes through `/tmp/relay_actions.sock` into the menu-bar app and toggles `AppState.toggleWorkspace()`. A live bridge rooted in a single git repo opens that repo's Workspace work tab; a live bridge rooted in a workspace folder with child git repos opens the read-only Program Workspace without creating a parent `.orchestrator/`; no active `/relay-bridge` session shows the standard "No session running" pill.

## RelayVision — looking at the user's screen

For all screen *observation* — currently just `screenshot` — use the `mcp__relay-vision__*` tools. This namespace was split out of RelayActions (RR-10) so "looking at the screen" and "acting on the screen" are separate tool families. Do **not** use `mcp__computer-use__*` for anything covered by RelayVision. The namespace is designed to grow (future tools could include region reads), but today it's just `screenshot`.

When the user says "look at my screen", "what's on my screen", "can you see X", "check the screen", or any similar voice intent to have you observe the current display, fire `mcp__relay-vision__screenshot` immediately. Do not explore the codebase, do not ask clarifying questions about which display, do not summarize before looking. The screenshot tool pulses ActionGlow automatically as it runs, so the user gets the visual signal at the same moment you get the pixels.

## Asking for permission — don't use `propose_action`

`mcp__relay-actions__propose_action` is registered in the MCP server, but **don't call it.** Its medium/high-risk path was designed to block on a double-tap Option/Control gesture for confirmation. That pattern was abandoned because those modifier double-taps are already bound to play/cancel TTS in voice mode, and the dual binding caused real UX problems. Calling it now will block on a confirmation the user is no longer expecting and time out after 30 seconds.

If you need user permission for a risky screen action:

1. **Default: just execute.** The user has already authorized voice control by starting the session. The ActionGlow perimeter glow is the visual signal that screen control is happening.
2. **If the action is genuinely high-stakes** (irreversible, sends a message, spends money, deletes data) and you're not confident the user wants it: **ask via a normal text message in the chat** with a clear summary, and wait for an explicit "yes" before proceeding. Do **not** call `propose_action`.
3. **Never** route confirmations through native computer-use prompts. Same reason — bypasses the project's stack.

## Naming notes

- **Relay Actions** = the screen-*manipulation* feature and its MCP tool family (`mcp__relay-actions__*`): click, type, scroll, key, list_windows, frontmost_app.
- **Relay Vision** = the screen-*observation* feature and its MCP tool family (`mcp__relay-vision__*`): screenshot (initially). Split out of Relay Actions in RR-10.
- **ActionGlow** = the perimeter-glow overlay that pulses whenever a RelayActions *or* RelayVision tool runs. It is automatic — driven by the `tool_fired` notification every RelayActions and RelayVision tool sends after running — so you never call it directly. It is a **visual signal**, not a confirmation gate. (`OverlayState.actionGlow` in code.)
- Together: **the Relay stack**. Don't conflate any of these with native "computer-use" or "computer-vision" — those are different MCPs from a different vendor.

<!-- END GENERATED -->

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
- `docs/specs/relay-vision.md` — Relay Vision feature spec
- `docs/specs/orchestrator-tickets.md` — local board ticket schema

For wider behavioral guidelines such as the Karpathy rules, see `~/.claude/CLAUDE.md`; this repo's native Program Manager capture guidance overrides any older global program-tracking guidance.
