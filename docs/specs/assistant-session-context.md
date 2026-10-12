# General and project conversations

Start Session defaults to the preinstalled **general-tasks** project at `~/Library/Application Support/relay-runner/general-tasks`. The app creates and registers it automatically as a normal local project. Its tickets use the existing board and canonical project writer; its drafts and outputs stay in its managed folder. Existing centralized notes retain their location and identities.

Users select projects through the existing Projects list. Workspace, Notes, Terminal and Settings remain the navigation surfaces. Session bindings and native provider history are internal recovery state; there is no separate Conversation, Files or General switcher interface.

## Provider lifecycle

The app keeps one active managed foreground provider. Re-selecting its context
with the same provider/model reuses it. A context or provider change saves the
current history, stops the previous process, and opens or resumes the destination
context. Recording, note capture, an active provider turn, queued voice input,
unsubmitted terminal text, playback and outstanding approvals defer a switch.
The UI retains the current context while showing the pending destination.
Detached daemon workers keep their own canonical project/run ownership.
Agents use Relay Actions `activate_project` with a confirmed repository path or
known alias, including the `general-tasks` alias. The compatibility `activate_general` tool
selects the same built-in project. A request during the calling provider's turn returns a queued
message; it must finish that reply before the app switches. A queued response
does not authorize project work from the old General process.

After 30 minutes of safe inactivity, the foreground provider is saved and
terminated. Start Session reconnects it using normal provider resume support.
Closing the Workspace or changing tabs does not stop the process.

Codex resumes with its exact native session UUID using
`codex resume <uuid> --cd <confirmed-directory>` so a moved repository does not
restore its old working directory.
Claude resumes with `--resume <uuid>`; a new Claude session gets an explicit
`--session-id <uuid>`. Both retain subscription sign-in and readiness checks.
Claude uses the launcher's confirmed working directory. Isolated native CLI tests
passed exact-session resume after moving the working directory with Claude
2.1.294 and the current 2.1.296 executable (evidence:
`/tmp/rr-claude-2.1.294-moved-resume-evidence.json` and
`/tmp/rr-claude-current-moved-resume-evidence.json`). Embedded GUI trust and
readiness after a move remain an installed validation gate.
There is no arbitrary "latest session" selection. Provider/model changes create
a fresh native session, with a bounded public handoff from that same context.
Codex can become ready before invoking a lifecycle hook or creating its first
transcript. For that first request, the app observes the exact launched native
executable's single held thread-writer lock and confirmed cwd, checking its
PID/birth fingerprint before and after. The lock supplies the actual native
UUID without submitting a dummy turn. Missing, multiple, unheld or foreign
locks fail closed. A startup-only UUID cannot be resumed; its first real prompt
hook must enrich the binding with the native transcript path first. Claude
supplies startup identity through its native SessionStart hook.
These native history and resume guarantees apply to the embedded app-owned
session path. The compatibility external Terminal path retains its skill-driven
hook setup; it has exact process ownership protection, but does not yet promise
the embedded path's durable public transcript binding.

Each launch records its PID and birth/user/process-group fingerprint before
provider authentication or execution, including the compatibility external
Terminal path. Before replacement, the app checks that exact identity, requests
termination only of a matching old process, and waits for exit. A reused PID is
ignored. A live process whose identity cannot be checked blocks replacement.
Zombies count as exited; explicit embedded termination reaps only the stopped
direct child after checking its birth time, leaving other child monitors alone.
An old PTY that does not exit within five seconds produces a reconnect error;
it does not authorize a second provider.

## Persistence and recovery

Private operational state lives in
`~/Library/Application Support/relay-runner/sessions/conversation-v1.json`, outside
the personal file archive. It stores the conversation ID, active context,
per-context native session bindings, lifecycle state, public history and links to
canonical intents/runs. Hook sidecars are tied to the context, launch transport
UUID, provider and exact working directory. PIDs alone are never trusted.
Context selection, its visible marker and the previous binding's saved lifecycle
commit together. Failed persistence retains the complete previous document.

Restart restores history and context immediately. Previously running or starting
sessions become interrupted; Start Session or selecting that context reconnects
through the provider's native resume and existing authentication flow. Completed
requests, unfinished chat history and saved intent identifiers are never submitted
as new commands. Canonical daemon intent/run state remains the recovery authority.
Interrupted notes retain their existing explicit resume flow and never restart
recording automatically.

Public user and assistant text is imported incrementally from the exact bound
provider transcript with a durable byte cursor. Tool records, reasoning, system
and developer setup, and known injected scaffolding are excluded.
Relay routing metadata appended to user text is removed without dropping that
user turn, including previously saved entries and public handoffs. Partial trailing
records wait for a later poll. Individual records larger than 4 MiB are skipped
to bound memory, and the original native transcript remains the provider's own
resume source. Re-reading or restarting does not duplicate imported turns.
A corrupt session document is preserved and blocks replacement saves rather than
being overwritten by an empty conversation.

## Validation boundaries

Source tests cover context/history persistence, interruption normalization,
obligation guards, context-bound hook identities, exact provider resume commands,
large tool output between public turns, fractional timestamps, duplicate imports,
corrupt state, stale PID reuse, unknown identity and failed termination. Python
integration tests exercise real shell process binding; this requires read-only
`ps` access, which a development sandbox may restrict.

Installed validation still requires a signed app run: one-click General launch,
General/project switching while a command runs, both providers' resume and sign-in,
crash/restart with a surviving child, idle reclamation, global notes recovery and
visual Conversation continuity. A source build or mocked process test does not
establish those installed behaviors.

## Explicit request continuation

`activate_project` and `activate_general` accept optional public unfinished request text in `continuation`. The app captures its exact canonical active typed/voice native turn, confirms the destination binding, and saves a stable outbox entry. Source completion precedes switching. Destination readiness and an empty composer precede one bracketed paste and a separate Enter; human input, cancellation, approval, or a changed native identity blocks submission. The outbox is marked submitting durably before the first byte, and is consumed only by a canonical manual-submit acknowledgement matching nonce and full destination ownership.

Forwarded turns remain manual native turns. Voice parents retain their original intent, command identity, mutation ledger, revocations and used fingerprints; no voice claim or acknowledgement is rewritten. The public Conversation shows only the explicit unfinished text. Navigation never creates continuation work. Restart, partial paste, missing acknowledgement, or stale authority requires review; Clear continuation cancels it, and retry requires a new explicit request.

Codex filters stdio MCP child environments. App-owned launches therefore pass per-session `env_vars` allowlists for Relay Actions' exact source binding and the orchestrator's destination ownership and confirmed project token. Other MCP servers receive no additional fields, and user configuration is unchanged. Claude's native MCP children inherit the launch environment; isolated native handshake checks verify both paths. Missing or mismatched ownership still rejects continuation.
