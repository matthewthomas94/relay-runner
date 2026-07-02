# RR-127 Persistent Orchestrator Audit

## Summary

RR-127 is an epic, not a single worker ticket. The requested architecture changes the product model from "foreground session is the orchestrator" to "PM frontstage plus persistent orchestrator tech lead plus narrow workers."

## Touched Surfaces

- `services/voice_bridge.py`: raw STT intake, acknowledgement, planning/status events, stale command metadata, command publication.
- `services/command_actions.py`: current command contract still names the foreground agent as orchestrator and defers visible ticket creation to it.
- `services/orchestrator.py`: daemon currently dispatches one-ticket workers and tracks run state; persistent orchestrator lifecycle/review/merge behavior does not exist yet.
- `services/orchestrator_workflow.md`: worker prompt is still valid for narrow executor workers but needs context under the new architecture.
- `scripts/relay-bridge`: source of generated Codex/Claude skills and bridge startup behavior.
- `AGENTS.md`: repo constitution currently instructs the foreground session to act as orchestrator and write/refine tickets.
- `docs/orchestrator.md`: user-facing docs describe the old four-step loop and foreground-session integration responsibility.
- `Sources/relay-runner/Board/*` and program status surfaces: PM update mode needs direct status reads from board/run/program state.
- `Sources/relay-orchestrator-mcp/*`: MCP tool surface may need persistent-orchestrator lifecycle/status/action tools.

## Ticket Split

- RR-128: persistent orchestrator lifecycle and state.
- RR-129: parallel raw STT fanout to PM and orchestrator.
- RR-130: orchestrator-owned ticket authoring and worker dispatch requests.
- RR-131: PM update-mode status fetching and user summaries.
- RR-132: orchestrator review, merge, retry, and done-state loop.
- RR-133: documentation, skills, and project-guidance migration.

## Notes

The main risk is accidentally leaving solutioning in the PM path. The implementation should make the PM a user-facing/status frontstage and keep ticket writing, technical planning, review, retry, and merge decisions in the persistent orchestrator path.
