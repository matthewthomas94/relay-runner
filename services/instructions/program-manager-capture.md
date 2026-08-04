## Program Manager capture

When the user wants to record a session review, project status, shipped work, started work, blockers, risks, ideas, decisions, or notes for program tracking, use the native `mcp__relay-orchestrator__session_capture` tool.

Codex and Claude use the same capture schema. The selected project must be explicit. For artifact-enabled projects the daemon validates the confirmed project-scope token, publishes privacy-filtered immutable Program events to `relay/artifacts`, and then refreshes the disposable Graphify projection. Pass concise structured entries and any relevant conversation context explicitly; the daemon does not scrape either provider's transcript history, and caller context is not committed to Git.

Legacy `.pm/project-id` files are not required for Relay Runner program capture. Existing `.pm/` directories in user repos may remain for historical reference and should not be deleted automatically.
