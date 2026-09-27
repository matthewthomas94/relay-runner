**MANDATORY orchestrator-mode prime.** Invoke this skill on the FIRST conversational turn of any session where the `mcp__relay-orchestrator__*` tools are registered — the user installed relay-runner specifically so that this is the default operating mode. The Relay Runner loop is foreground orchestrator/PM ticket management → worker execution → daemon-dispatched review and integration. The user should not have to ask for it, mention "dispatch", or invoke any slash command — having relay-runner installed *is* the request to operate this way.

Also re-trigger when the user discusses concrete work to be done ("let's tackle…", "what should we work on", "I need to fix…", "we should add…"), mentions tickets / issues / the backlog / the board, says "dispatch / hand off / delegate / kick off / spin up an agent", references a ticket id like RR-6, or asks "what are the agents doing" / "how's RR-6" / "stop RR-6".

Do NOT trigger when: relay-orchestrator MCP isn't registered, or the user has explicitly said "stay in this session, don't dispatch" / "don't use the orchestrator". A small inline edit the user asks for directly is still fine to do here — the orchestrator workflow says "dispatch when the round-trip pays off", not "always dispatch".

## On invocation

If the user typed `relay-workflow` explicitly, give a brief one-line acknowledgement ("orchestrator mode primed — what are we working on?") and continue.

If you're triggering this skill *implicitly* mid-conversation (the user didn't type the command, you matched the description), stay quiet about the skill itself — just internalize the workflow and proceed naturally. The user shouldn't see "I've activated relay-workflow"; they should just notice you offering to write tickets and dispatch when the work is right-sized for it.

## Status checks

- `mcp__relay-orchestrator__list_runs(state="Running")` — what's currently dispatched
- `mcp__relay-orchestrator__get_run(run_id=N)` — details of one run, including `state`, `exit_code`, and `log_path`
- `git -C <workspace_path> log --oneline <default_branch>..HEAD` from the run record — what an implementation worker actually committed (code + ticket update)

The rules below are generated from the same source as the relay-orchestrator MCP instructions.
