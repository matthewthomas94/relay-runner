# Orchestrator daemon HTTP API

The contract the orchestrator daemon (`services/orchestrator.py`) offers its
clients: the HTTP routes, the files and databases it leaves on disk, the git
commits it writes, and the switches that run it in isolation. The black-box
suite in `tests/contract/` checks this document against a running daemon, and
any replacement daemon (the planned Rust port, RR-448) must pass the same
suite. Behaviour described here is the reference daemon's behaviour as of
RR-485, including its quirks; changing it is a separate, deliberate decision.

## Transport

- HTTP/1.0 over loopback only: the daemon binds `127.0.0.1` on the configured
  `[orchestrator] port` (default `7634`). If that port is taken, or the
  configured port is `0`, it binds an ephemeral port instead.
- Once listening it writes the bound port as decimal text, with no newline, to
  the port file (default `/tmp/relay_orchestrator.port`; see
  [Isolation](#isolation)). Clients read the port file and fall back to `7634`.
- Every response is `Content-Type: application/json` with a `Content-Length`.
  Methods other than `GET` and `POST` are answered by the HTTP server library
  itself with `501` and an HTML body.
- `GET` parameters are query-string parameters; a repeated parameter is a list
  where the route says so, otherwise the first value wins. Booleans in queries
  accept `1`, `true` or `yes` (case-insensitive) as true.
- A `POST` body is a JSON object. An empty body, malformed JSON or a JSON value
  that is not an object all read as `{}`, so the route reports its missing
  required field rather than a parse error.
- There is no authentication: the socket is loopback-only. Mutations that need
  a confirmed project carry a `project_scope_token` (below); voice-originated
  mutations carry `relay_command_seq`, `relay_command_id`, `relay_intent_id`
  and `relay_session_key`, which the daemon checks against the voice command
  state file.
- At most 32 requests are served concurrently. The program routes
  (`/v1/program/status`, `/v1/program/dashboard`, `/v1/ready-sweep`,
  `/v1/program/ready-sweep`, `/v1/queue-drain/reconcile`) share 8 of those
  slots; when they are exhausted the route answers `503`
  `{"error": "Program Workspace is busy refreshing; retry shortly.", "retryable": true}`.

### Errors

A failing route answers `{"error": "<message>"}` plus the fields below. The
status comes from the exception the handler raised:

| Status | Raised as | Extra fields |
|---|---|---|
| 400 | `ValueError` (missing or invalid field, unknown id, wrong state) | — |
| 404 | no matching route: `{"error": "no route for <METHOD> <path>"}` | — |
| 404 | `GET /v1/runs/{id}` with an unknown id: `{"run": null}` (no `error`) | — |
| 404 | `POST /v1/messenger/outcomes/{id}/delivered` with an unknown id: `{"outcome": null}` | — |
| 409 | artifact rollout gate refused the write | `error_code`, `recovery` |
| 409 | another writer moved the artifact ref first | `retryable: true` |
| 409 | artifact event collision or identity mismatch | `retryable: false` |
| 409 | the `.orchestrator/` projection could not be materialised | `error_code: "materialization_conflict"`, `retryable: false` |
| 409 | personal storage state refused the operation | `state` |
| 422 | artifact validation (note schema, unknown note, bad request id) | — |
| 500 | `RuntimeError` | — |
| 503 | program refresh unavailable | `retryable: true` |
| 503 | file-system or SQLite I/O failure: `"The local workspace service could not complete I/O; retry shortly."` | `retryable: true` |

A path segment that must be an integer and is not (`/v1/runs/abc`) or an
integer query parameter that is not (`limit=many`) is a `400` whose message is
Python's `invalid literal for int() with base 10: '<value>'`.

**Known defect.** An exception outside this table escapes the handler and the
daemon closes the connection without a response. The reachable case is
`POST /v1/personal-storage/pin` and `/retrieve` without `artifact_id`
(`KeyError`). Clients always send it; a port may answer `400` instead.

### Project scope tokens

Artifact-board routes take `repo_path` and `project_scope_token`. The token is
standard base64 of a compact JSON object (sorted keys) issued by the app from
its project registry (`projects/registry-v2.json`):

```json
{"gitCommonDirectoryFingerprint": "…", "issuedAt": 1786000000.0,
 "projectID": "…", "registrySchemaVersion": 2, "registryRecordUpdatedAt": 1786000000.0,
 "repositoryPath": "/path/to/repo", "version": 1}
```

The daemon accepts it only when the project id, repository path, fingerprint
and `registryRecordUpdatedAt` match the current registry record for
`repo_path`. A project whose board is still tracked files (a *legacy board*)
refuses artifact writes with `400 project is not using the artifact-backed
board writer`.

## Route index

Callers name the non-test code that sends the request: **Board** is
`Sources/relay-runner/Board/OrchestratorClient.swift`, **MCP** is
`Sources/relay-orchestrator-mcp/Tools.swift`, **Bridge** is
`services/voice_bridge.py`, **Settings** is
`Sources/relay-runner/Settings/PersonalFileStorageSettingsView.swift`,
**Worker prompt** is a URL the daemon writes into a worker's prompt. Routes
marked **none** have no non-test caller today.

| Method | Path | Success | Callers |
|---|---|---|---|
| GET | `/v1/health` | 200 | `scripts/relay-orchestrator`, `VenvInstaller.swift` |
| GET | `/v1/runs` | 200 | MCP, Board, Bridge |
| POST | `/v1/runs` | 202 (200 when already active) | MCP, Board, Bridge |
| GET | `/v1/runs/{run_id}` | 200 (404 unknown) | MCP |
| POST | `/v1/runs/{run_id}/cancel` | 200 | MCP |
| GET | `/v1/runs/{run_id}/review` | 200 | MCP |
| POST | `/v1/runs/{run_id}/review` | 202 | MCP |
| POST | `/v1/runs/{run_id}/review/decision` | 200 accept, 202 retry | Worker prompt (review) |
| GET | `/v1/runs/{run_id}/outcome` | 200 | Worker prompt (artifact implementation) |
| POST | `/v1/runs/{run_id}/outcome` | 202 | Worker prompt (artifact implementation) |
| POST | `/v1/runs/{run_id}/resume-verification` | 200 (202 when redispatched) | MCP |
| POST | `/v1/runs/reconcile-preserved` | 200 | MCP |
| POST | `/v1/runs/recover-preserved-collision` | 200 | MCP |
| POST | `/v1/ready-sweep` | 200 | Board |
| POST | `/v1/program/ready-sweep` | 200 | Board |
| GET | `/v1/queue-drains` | 200 | MCP |
| POST | `/v1/queue-drains/{drain_id}/cancel` | 200 | none |
| POST | `/v1/queue-drain/reconcile` | 200 | MCP |
| GET | `/v1/program/status` | 200 | MCP, Board, Bridge |
| GET | `/v1/program/dashboard` | 200 | Board |
| POST | `/v1/program/capture` | 201 | MCP |
| POST | `/v1/orchestrator-actions` | 202 | none |
| GET | `/v1/orchestrator-sessions` | 200 | Bridge |
| POST | `/v1/orchestrator-session/ensure` | 201 created, 200 existing | Bridge |
| POST | `/v1/orchestrator-session/heartbeat` | 200 | Bridge |
| POST | `/v1/orchestrator-session/stop` | 200 | Bridge |
| POST | `/v1/orchestrator-session/command` | 202 | Bridge |
| GET | `/v1/messenger/outcomes` | 200 | Bridge |
| POST | `/v1/messenger/outcomes/{outcome_id}/delivered` | 200 (404 unknown) | Bridge |
| POST | `/v1/messenger/outcomes/{outcome_id}/attempt` | 202 | Bridge |
| POST | `/v1/continuity/observation` | 202 | Bridge |
| GET | `/v1/continuity-reports/{report_id}` | 200 | MCP |
| POST | `/v1/continuity-reports/{report_id}/proposals/{proposal_id}/review` | 200 | MCP |
| POST | `/v1/spikes/follow-ups/propose` | 201 created, 200 existing | MCP, Board |
| POST | `/v1/spikes/follow-ups/{batch_id}/proposals/{proposal_id}/review` | 200 | MCP, Board |
| POST | `/v1/artifacts/tickets/claim-next-id` | 201 | Board |
| POST | `/v1/artifacts/tickets/write` | 200 | Board |
| POST | `/v1/artifacts/tickets/delete` | 200 | Board |
| POST | `/v1/artifacts/attachments/write` | 200 | Board |
| GET | `/v1/artifacts/dependencies/{ticket_id}` | 200 | Board |
| GET | `/v1/artifacts/rollout` | 200 | none |
| GET | `/v1/artifacts/retention/preview` | 200 | none |
| GET | `/v1/artifacts/retention/status` | 200 | none |
| POST | `/v1/artifacts/retention/apply` | 200 | none |
| POST | `/v1/artifacts/retention/retry` | 200 | none |
| GET | `/v1/artifacts/storage` | 200 | none |
| GET | `/v1/artifacts/history/search` | 200 | Board |
| GET | `/v1/artifacts/history/{artifact_id}` | 200 | Board |
| GET | `/v1/artifacts/history/{artifact_id}/attachments/{filename}` | 200 | none |
| POST | `/v1/artifacts/history/{artifact_id}/restore` | 200 | Board |
| POST | `/v1/artifacts/history/{artifact_id}/reopen` | 200 | Board |
| GET | `/v1/artifacts/notes` | 200 | MCP, Board |
| GET | `/v1/artifacts/notes/{identity}` | 200 | MCP, Board |
| POST | `/v1/artifacts/notes/create` | 201 | Board |
| POST | `/v1/artifacts/notes/{note_id}/update` | 200 | Board |
| POST | `/v1/artifacts/notes/{note_id}/retry-metadata` | 200 | Board |
| POST | `/v1/artifacts/notes/{note_id}/archive` | 200 | none |
| POST | `/v1/artifacts/notes/{note_id}/delete` | 200 | Board |
| POST | `/v1/artifacts/notes/{note_id}/cancel` | 200 | Board |
| GET | `/v1/general/tasks` | 200 | none |
| POST | `/v1/general/tasks` | 201 | none |
| GET | `/v1/general/tasks/{task_id}` | 200 | none |
| POST | `/v1/general/tasks/{task_id}/dispatch` | 202 | none |
| POST | `/v1/general/tasks/{task_id}/review` | 200 | none |
| POST | `/v1/general/tasks/{task_id}/cancel` | 200 | none |
| POST | `/v1/general/tasks/{task_id}/artifact` | 200 | none |
| GET | `/v1/personal-storage/status` | 200 | Settings |
| GET | `/v1/personal-storage/account` | 200 | Settings |
| GET | `/v1/personal-storage/files` | 200 | none |
| POST | `/v1/personal-storage/sign-in` | 200 | Settings |
| POST | `/v1/personal-storage/configure` | 200 | Settings |
| POST | `/v1/personal-storage/disconnect` | 200 | Settings |
| POST | `/v1/personal-storage/sync` | 200 | Settings |
| POST | `/v1/personal-storage/policy` | 200 | Settings |
| POST | `/v1/personal-storage/pin` | 200 | none |
| POST | `/v1/personal-storage/retrieve` | 200 | none |

`tests/contract/orchestrator_route_inventory.py` reads `Handler._route` and
`handle_personal_storage_request` with `ast` and the suite fails when either
gains, loses or renames a route this table does not match. The suite also
sends every row to the running daemon with empty input and compares the
status and error with `golden/orchestrator/routes/empty-input.json`.

## Runs

A run is one worker attempt at one ticket. `id` is the SQLite row id in
`runs.db`. The run object every route returns:

| Field | Meaning |
|---|---|
| `id`, `ticket_id`, `repo_path`, `attempt` | identity; `attempt` counts runs of the ticket |
| `state` | see below |
| `workspace_path`, `branch` | the worktree under `workspace_root` named `<repo>-<8 hex>-<ticket id lowercased>` and its `relay/<ticket id lowercased>` branch |
| `execution_mode` | `implementation` or `spike` |
| `started_at`, `ended_at` | Unix seconds (float); `ended_at` is `null` while active |
| `exit_code`, `last_error`, `pid` | worker result; `-1` for a refused dispatch, `-15` for a cancel |
| `activity`, `activity_at` | last progress line the worker emitted |
| `provider_key`, `model_alias`, `worker_model`, `worker_effort`, `worker_sizing_rationale`, `worker_provider_notes` | the resolved worker sizing |
| further fields | review, verification and queue bookkeeping; the golden files in `golden/orchestrator/runs/` hold the full shape |

States: `Claimed`, `Running`, `Reviewing`, `AwaitingReview`, `Merged`,
`Failed`, `Canceled`, `VerificationBlocked`, `IntegrationBlocked`,
`MergeConflict`, `Stalled`; spikes add `SpikeResultReady` and
`SpikeCompleted`. `Claimed`, `Running` and `SpikeResultReady` are active.

- `GET /v1/runs?state=&limit=100` → `{"runs": [run, …]}`, newest first.
- `POST /v1/runs` dispatches a ticket. Body: `ticket_id`, `repo_path`
  (required); `context` (text appended to the worker prompt), `source`
  (default `direct`), `project_scope_token` (required for an artifact board),
  `dispatcher_session_key`, voice fields. → `202 {"already_active": false, "run": run}`
  or `200 {"already_active": true, "run": run}` for the live run. Errors (400):
  `ticket_id is required`, `repo_path is required`, `<path> is not a git
  repository`, `ticket <id> not found`, `missing worker sizing metadata: …`
  (also recorded as a `Failed` run with `exit_code -1`), `… is verification
  blocked`, and dependency/queue refusals. A ticket whose dependencies are not
  `done` is queued instead: `202 {"queued": true, "already_active": false,
  "run": null, "waiting_on": [ticket ids]}` (see
  [Queue drains](#queue-drains-and-the-ready-sweep)). On an artifact board a
  dispatch without a valid scope token is `422 artifact lifecycle dispatch
  requires a confirmed project scope token`.
- `GET /v1/runs/{id}` → `{"run": run}`; unknown → `404 {"run": null}`.
- `POST /v1/runs/{id}/cancel` body `prune_worktree` (default true) →
  `{"canceled": true, "run": run, "worktree_removed": bool}`; `worktree_removed`
  and `worktree_error` are present only when pruning. A terminal run →
  `{"canceled": false, "reason": "run is in terminal state <state>", …}`.
  Unknown → 400 `unknown run_id <id>`.
- `GET /v1/runs/{id}/review` → `run`, `review_needed`, `ticket_status`,
  `ticket_run_log`, `branch_commits`, `branch_diff_stat`,
  `branch_diff_name_status`, `log_tail`, `verification_evidence`.
- `POST /v1/runs/{id}/review` body `context` → `202 {"review_dispatched": bool, …}`;
  400 `… is not awaiting review`.
- `POST /v1/runs/{id}/review/decision` body `decision` (`accept` | `retry`),
  `reason`, `redispatch` (default true). Accept → `200 {"accepted": true,
  "run": run, "worktree_removed": bool, "promoted": [ticket ids], …}`; retry →
  `202`. 400 `decision must be 'accept' or 'retry'`, `… is not awaiting review`.
- `GET|POST /v1/runs/{id}/outcome` exist only for artifact-board runs. POST
  body: `status` (`completed` | `verification_blocked`), `summary`,
  `changed_paths`, `verification`, `source_commit`, and for a blocked run
  `verification_blocker`, `verification_resume` → `202 {"accepted": true,
  "outcome": {…}}`. 400 for a legacy run (`uses the legacy ticket lifecycle`,
  `is not accepting a worker outcome`). The outcome is checked against the
  worker branch when the worker exits: a `source_commit` that is not the
  worker's HEAD fails the run (`exit=0 but ticket incomplete: structured
  outcome source_commit does not match worker HEAD`) and publishes
  `Record failed for <TICKET> run <id>`, returning the ticket to `backlog`.
- `POST /v1/runs/{id}/resume-verification` body `reason` (required),
  `redispatch` (default true) → `{"resumed": true, "reason", "resume_commit",
  "previous_run", "redispatched": run | null}`; `202` when redispatched.
  400 `reason is required`, `… is not verification blocked`.
- `POST /v1/runs/reconcile-preserved` and `/recover-preserved-collision`
  body `repo_path`, `ticket_id` → `{"reconciled": bool, "source":
  "canonical-ticket" | "existing-ledger", "run": run}`.

### Legacy and artifact lifecycles

On a **legacy board** the worker commits its source change and the ticket
update on `relay/<id>`; the daemon checks the ticket says `done` (or
`verification_blocked`) with the run id and a run-log entry, then a review
worker posts its decision and the daemon merges into the checked-out branch
with the message `merge <TICKET> worker run <id>`. On an **artifact board** the
worker commits source only and posts an outcome; the daemon publishes the
claim (`Claim <TICKET> for run <id>`) and the reviewed outcome (`Publish
reviewed outcome for <TICKET> run <id>`) as commits on
`refs/heads/relay/artifacts`. Accepting a run moves dependents whose
dependencies are all done from `backlog` to `ready` and dispatches them
(`source: dependency-progression`). A spike's worker returns a structured
result; the daemon writes the report into the ticket and never merges.

## Queue drains and the ready sweep

- `POST /v1/ready-sweep` body `repo_path` (required), `trigger`,
  `project_scope_token` → `{"repo_path", "trigger", "promoted", "dispatched":
  [{"ticket_id", "run_id"}], "skipped": [{"ticket_id", "reason"}], "drain"}`:
  dispatches every `ready` ticket whose dependencies are done and records the
  rest with a reason (`dependencies_not_done`, `status:<status>`). The sweep
  opens or updates the project's queue drain, returned as `drain`.
- `POST /v1/program/ready-sweep` body `trigger` → the same for every
  registered project: `{"trigger", "projects", "dispatched", "skipped"}`.
- `GET /v1/queue-drains?repo_path=&include_terminal=false&limit=20` →
  `{"queue_drains": [drain, …]}`. A drain id is
  `drain-<12 hex of repo, branch and provider>-<sequence>`.
- `POST /v1/queue-drain/reconcile` body `repo_path` or `repo_paths`, `trigger`
  → `{"trigger", "projects": […]}`.
- `POST /v1/queue-drains/{drain_id}/cancel` body `reason` → `{"queue_drain":
  drain}` with `state: canceled`; 400 `unknown queue drain <id>`. A drain
  completes (`state: completed`) once every observed ticket is done.

## Program, sessions, messenger and continuity

- `GET /v1/program/status?query=summary&provider=&limit=8` → `{"query",
  "provider", "message", "items", "counts", …}`.
- `GET /v1/program/dashboard?provider=&limit=0&trigger=program-board-refresh&repo_path=…&sweep=1`
  → one status object per lane (`summary`, `backlog`, …); `sweep=0` skips the
  ready sweep it otherwise runs first.
- `POST /v1/program/capture` body `repo_path`, `entries` (required),
  `ticket_id`, `run_id`, `provider`, `context`, `capture_id`, `source`,
  `project_scope_token` → `201`.
- `POST /v1/orchestrator-actions` body `repo_path` (required), `actions`,
  `request_id`, voice fields → `202`.
- `GET /v1/orchestrator-sessions?repo_path=&limit=100` → `{"orchestrator_sessions": […]}`.
- `POST /v1/orchestrator-session/ensure` body `repo_path` (required),
  `provider`, `model`, `effort`, `source`, `pid`, `state` (default `idle`),
  `command_action_states` → `{"orchestrator_session": {…, "created": bool}}`,
  `201` when created.
- `POST /v1/orchestrator-session/heartbeat` body `session_id` or `repo_path`,
  `provider`, `state`; `/stop` body `session_id` or `repo_path`, `reason`.
  400 `orchestrator session not found`.
- `POST /v1/orchestrator-session/command` body `repo_path`, `source_text`,
  `relay_command_seq`, `relay_command_id`, `intent_id`, `within_turn_order`,
  `session_id`, `provider`, `recovery_generation`, `context`, `action`,
  `outcome`, `target`, `disposition`, `cancellation_scope`, `lifecycle_state`,
  `received_at`, `status` (default `received`), `defer_processing` → `202`.
- `GET /v1/messenger/outcomes?repo_path=&provider=&limit=20&session_key=&live_session_keys=a,b`
  → `{"outcomes": […]}`; `POST …/{id}/delivered` → `{"outcome": …}` (404
  `{"outcome": null}` when unknown); `POST …/{id}/attempt` → `202 {"ok": true}`
  for any id.
- `POST /v1/continuity/observation` → `202`; 400 `continuity event requires session_id`.
- `GET /v1/continuity-reports/{id}`; `POST …/proposals/{pid}/review` body
  `decision` (`edit` | `accept` | `reject`), `updates`, `target_repo_path`,
  voice fields.
- `POST /v1/spikes/follow-ups/propose` body `origin_repo_path`,
  `origin_ticket_id`, `origin_run_id`, `proposals` (list), `provider` → `201`
  when a batch is created; `POST …/{batch}/proposals/{pid}/review` body
  `decision`, `updates`, voice fields.

## Artifact board, history and retention

All take `repo_path` and `project_scope_token` (query for `GET`, body for
`POST`). Writes are one commit each on `refs/heads/relay/artifacts`, followed
by re-materialising the untracked `.orchestrator/` projection in the working
tree; `golden/orchestrator/board/` holds every commit byte for byte.

- `POST /v1/artifacts/tickets/claim-next-id` body `request_id` → `201
  {"ticket_id", "next_id", …}`; reusing a `request_id` for a different claim
  is refused.
- `POST /v1/artifacts/tickets/write` body `ticket_id`, `markdown_base64`,
  `request_id`; the daemon adds `artifact_id` and `user_edited_at` to the
  frontmatter.
- `POST /v1/artifacts/tickets/delete` body `ticket_id`, `request_id`;
  deleting a missing ticket succeeds and writes nothing.
- `POST /v1/artifacts/attachments/write` body `ticket_id`, `filename` (no
  path), `mime_type`, `content_base64`, `request_id`; stored at
  `.orchestrator/attachments/<ticket>/<filename>`.
- `GET /v1/artifacts/dependencies/{ticket_id}` → the ticket's dependency and
  dependent summary.
- `GET /v1/artifacts/rollout` → `{"status", "rollout": {…}}`, no project.
- `GET /v1/artifacts/retention/preview`, `/retention/status`, `/storage`;
  `POST /retention/apply` body `request_id` (required), `provider`,
  `confirm_github_exposure`; `POST /retention/retry` body
  `confirm_github_exposure`. Archival needs a GitHub remote; a local-only
  project previews and reports but never archives.
- `GET /v1/artifacts/history/search?query=` → `{"history": […], "recovery"}`;
  `GET /history/{artifact_id}?online=&confirm_github_exposure=`;
  `GET /history/{artifact_id}/attachments/{filename}`; `POST
  /history/{artifact_id}/restore|reopen` body `request_id` (required),
  `provider`, `online`, `confirm_github_exposure`.

## Notes

The global notes library lives under the state root (`notes/`, `files/`) and
is independent of `repo_path`.

- `GET /v1/artifacts/notes?limit=50&after=` → `{"notes", "artifact_commit",
  "limit", "has_more", "total_count", "next_cursor", "sync"}`.
- `GET /v1/artifacts/notes/{identity}` (note id or artifact id) → one note;
  422 `no unique project note matches '<identity>'`.
- `POST /v1/artifacts/notes/create` body `request_id`, `created_at`,
  `capture_started_at`, `captured_at`, `recording_state`,
  `checkpoint_reason`, `segments`, `capture_ended_at`, `provider` → `201`.
  Completing a capture starts a metadata worker (the provider CLI with a JSON
  schema) that fills `title` and `summary`.
- `POST …/{note_id}/update` body `request_id`, `update` (object), `provider`;
  `…/retry-metadata`; `…/archive` body `artifact_id`, `archived_at`,
  `request_id`, `provider`; `…/delete` and `…/cancel` (cancel also stops a
  recording) body `artifact_id`, `request_id`. A malformed note id is 400
  `invalid unpadded note ID: '<id>'`; schema errors are 422.

## General tasks and personal storage

- `GET /v1/general/tasks?limit=100` → `{"tasks", "total_count", "scope": "general"}`;
  `GET /v1/general/tasks/{id}`; `POST /v1/general/tasks` body `title`,
  `description`, `acceptance_criteria`, `request_id` (title, description and
  request id required) → `201`; `POST …/{id}/dispatch` body `provider` → `202`;
  `…/review` body `run_id`, `approve` (bool), `summary`; `…/cancel` and
  `…/artifact` body `run_id` (and `artifact_id`). Unknown → 400 `General task not found`.
- `/v1/personal-storage/*` routes return the storage status object (`state`,
  `message`, `connected`, `destination`, `files_root`, `budget_bytes`,
  `retention_days`, `usage`, …) except `account`, `files` (`{"files": […]}`,
  `query` parameter), `sign-in` (`{"state", "device_code", "url"}`) and
  `retrieve` (`{"reference", "content_base64"}`). State refusals are 409 with
  `state`.

## Files and databases

Under the data root (default `~/Library/Application Support/relay-runner/orchestrator/`):

| File | Contents |
|---|---|
| `runs.db` | `runs` table: one row per run |
| `runs.json` | board live-state index, below |
| `queue_drains.db` | queue drains and their items |
| `orchestrator_sessions.db` | foreground PM sessions |
| `orchestrator_commands.db` | voice command ledger |
| `messenger_outcomes.db` | worker lifecycle outcomes awaiting speech |
| `followup_proposals.db` | spike follow-up batches and proposals |
| `continuity_reports.db` | continuity reports and permanent-fix drafts |
| `graphify.db` | program index |
| `continuity_incidents.jsonl`, `continuity_agent_events.jsonl` | continuity audit logs |
| `workspaces/` | default `workspace_root` for worktrees |

The parent directory (the state root) holds `projects/registry-v2.json` (owned
by the app), `program/projects.json`, the artifact rollout state, the notes
library (`notes/`) and personal storage (`files/`, `general/`).

`runs.json` is rewritten atomically (temp file and rename) on every run
transition and periodically. `Sources/relay-runner/Board/RunStateStore.swift`
decodes it:

```json
{"runs": [{"ticket_id": "CT-1", "repo_path": "/repo", "run_id": 1, "state": "Merged",
           "attempt": 1, "started_at": 0.0, "ended_at": 0.0, "last_error": null,
           "workspace_path": "/ws/repo-0a1b2c3d-ct-1", "branch": "relay/ct-1",
           "execution_mode": "implementation", "activity": "…", "activity_at": 0.0,
           "provider_key": "claude", "model_alias": "sonnet", "worker_model": "balanced",
           "worker_effort": "medium", "worker_sizing_rationale": "…",
           "worker_provider_notes": "none"}]}
```

It lists active runs, runs that ended inside the retention window, and runs in
review-blocking or durable states, newest first. A daemon starting over
databases written by an earlier release migrates them in place; on start it
also marks runs whose worker is gone as stalled or failed.

## Isolation

Environment variables that move every file the daemon shares with an
installed copy. Each is unset by default and the defaults are unchanged.

| Variable | Default | Moves |
|---|---|---|
| `RELAY_ORCHESTRATOR_DATA_ROOT` | `~/Library/Application Support/relay-runner/orchestrator` | the databases, `runs.json`, default workspaces; its parent is the state root (registry, notes, personal storage) |
| `RELAY_ORCHESTRATOR_RUNTIME_DIR` | `/tmp` | the port file, `voice_command_state.json`, `voice_command_authorizations.json`, `relay-sessions/`, `voice_state.sock`, `voice_bridge.sock`, `relay_recovery_*.json` |
| `RELAY_ORCHESTRATOR_PORT_FILE` | `<runtime dir>/relay_orchestrator.port` | the port file alone |
| `BRIDGE_CONTROL_SOCK` | `<runtime dir>/voice_bridge.sock` | the bridge control socket alone |
| `RELAY_DIAGNOSTICS_DIR` | the app's diagnostics directory | support diagnostics |
| `RELAY_SESSION_WORK_STYLE_FILE` | the app's work-style file | the session work style |

`--config <path>` selects the TOML configuration; `[orchestrator]
workspace_root`, `port`, `agent` and `command` select the worktree root, the
port, the worker provider and its executable. The artifact worker prompt names
the daemon's own port file, so a worker reports to the daemon that started it.
`HOME` and `PATH` complete the sandbox: the suite sets `HOME` to an empty
directory and `PATH` to its fake `claude`, `codex` and `gh` plus the system
directories.

## Golden files

`tests/contract/golden/orchestrator/` holds the expected JSON responses and
git commits. `RELAY_CONTRACT_UPDATE_GOLDEN=1` rewrites them from the current
daemon; review the diff before committing. Before comparison every value is
normalised by these rules, in order (`Normalizer` in
`tests/contract/orchestrator_contract_support.py`):

1. Literal paths: the sandbox root becomes `<ROOT>`, each repository
   `<REPO:name>`, the source checkout `<SOURCE>`, and `127.0.0.1:<port>`
   `127.0.0.1:<PORT>`.
2. ISO 8601 timestamps become `<TIMESTAMP>`.
3. 64-hex digests become `<SHA256:n>`, 40-hex object ids `<OID:n>`, 32-hex
   values `<HEX32:n>` and UUIDs `<UUID:n>`, numbered by first appearance in
   the file so equal values keep equal placeholders. A hex value directly after
   a word character or `-` (such as `ticket-<40 hex>`, derived from fixed
   project and ticket ids) is kept.
4. `daemon-<24 hex>` device ids become `<DEVICE>`; the 8-hex worktree hash
   `-<HASH8>-`; the 12-hex drain hash `drain-<HASH12>-`.
5. Numbers under `pid`, `port`, `duration_seconds`, `elapsed_seconds`,
   `age_seconds`, `idle_seconds`, `uptime_seconds`, `worker_pid`,
   `review_pid` become `<KEY>`; numbers under keys ending `_at`, `_time` or
   `_until`, and under `timestamp`, `ts`, `deadline`, `issuedAt` and
   `registryRecordUpdatedAt`, become `<TIME>`.

A golden commit is a directory: `COMMIT.json` holds the normalised message,
author and committer identities without their dates, the parent count and
every file mode; `tree/` holds every blob, normalised as text when it is UTF-8
and byte for byte otherwise. The suite's repositories commit as
`Contract Suite <suite@contract.invalid>` and its fake workers as `Scripted
Worker <worker@contract.invalid>`.

## Running the suite

```bash
/opt/homebrew/bin/python3 -m unittest discover -s tests/contract -p 'test_orchestrator_contract_*.py'
```

`RELAY_ORCHESTRATOR_CMD` replaces the daemon command (default: this Python
with `services/orchestrator.py`; the suite appends `--config <file>`), and
`RELAY_ARTIFACT_MIGRATION_CMD` the board migration command. Timeouts:
`RELAY_ORCHESTRATOR_START_TIMEOUT` (30 s) and `RELAY_ORCHESTRATOR_WAIT_TIMEOUT`
(60 s).
