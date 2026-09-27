Dispatch a ticket from the current repo's local kanban board (`.orchestrator/<ticket_id>.md`) to a relay-runner sub-agent. You are acting as the PM frontstage for the user: report the dispatch outcome, while the persistent orchestrator creates an isolated git worktree (or a read-only spike workspace), renders the workflow prompt, and runs the configured agent autonomously inside it.

## When to use this

The user said something like "work on RR-6" or "have an agent take RR-6". This command picks up the ticket and starts a run; it does not wait for the worker to finish (check `list_runs` later).

## Steps

1. **Identify the ticket.** Extract the ticket id (e.g. `RR-6`) from the user's message. If multiple are mentioned, dispatch each via separate calls.
2. **Resolve the repo path.** The orchestrator needs the absolute path of the repo whose `.orchestrator/` board owns the ticket — normally `git rev-parse --show-toplevel` from the current working directory. Confirm `<repo>/.orchestrator/<ticket_id>.md` exists before dispatching.
3. **Check it is dispatchable.** The ticket needs `worker_model`, `worker_effort`, `worker_sizing_rationale`, `worker_provider_notes`, and an explicit `execution_mode` (`implementation` or `spike`). Unchecked items under `## Required inputs` block dispatch until the user resolves them; don't check them off yourself.
4. **Dispatch.** Call `mcp__relay-orchestrator__dispatch_ticket(ticket_id="RR-6", repo_path="<absolute path>")`. Pass `context="..."` when the ticket body wouldn't survive cold without this conversation. The tool returns:
   - `already_active: true` → there's already a run going for this ticket. Tell the user the existing run_id and stop.
   - `already_active: false` → a fresh run is started; the response includes `run_id`, `state` (Claimed → Running), `workspace_path`, and `branch`.
5. **Report briefly.** One sentence: "Started RR-6 in worktree `<path>`, run_id N." Don't wait — the run is async.

## Status checks

- `mcp__relay-orchestrator__list_runs(state="Running")` → all active runs
- `mcp__relay-orchestrator__get_run(run_id=N)` → details of a specific run, including `state`, `exit_code`, `last_error`, `log_path`

## After a run finishes

- **Implementation runs** commit the code and the ticket update to a local `relay/<id>` branch. The daemon then dispatches a review/merge worker that inspects the diff, runs checks, and accepts through the daemon merge path or requests a retry. Report that status; don't review or merge the branch yourself.
- **Spike runs** stay read-only. The daemon validates the structured result and writes the ticket report; use `propose_spike_followups` for follow-up drafts. Nothing is promoted or dispatched automatically.

## Cancelling

`mcp__relay-orchestrator__cancel_run(run_id=N)` terminates the worker (SIGTERM, then SIGKILL) and prunes the worktree by default.

## Notes

- The worker runs with the configured agent's permission-bypass flag inside an isolated branch (`relay/<sanitized-id>`); changes are local-only and never pushed automatically.
- The default workflow template is at `~/Library/Application Support/relay-runner/orchestrator/WORKFLOW.md`. A repo-local `.orchestrator/WORKFLOW.md` overrides the default for that repo; root-level `WORKFLOW.md` files are treated as normal project docs.
- For the broader "discuss → write → dispatch → integrate" workflow this command sits inside, see `relay-workflow`.
