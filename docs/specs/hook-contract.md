# Completion hook and reply helper contract

**Status:** Implemented (RR-477); Rust implementation RR-478

`services/relay_completion_hook.py` and `services/relay_reply.py` run as separate processes: the hook on every Claude and Codex lifecycle event, the reply helper whenever an agent pipes a reply to `$RELAY_REPLY_HELPER`. This document describes what those two programs read and write, as checked by the black-box suite in `tests/contract/`. The suite starts each program as an opaque command and imports nothing from `services/`, so a replacement written in another language is accepted against the same cases.

## Implementations

Since RR-478 the app registers `relay-rs hook` and `relay-rs reply` (built from `rust/`, shipped in `Contents/MacOS`) for Claude and Codex sessions alike: Codex's `-c hooks.*` flags, Claude's `--settings` hooks JSON, the `--record-process`, `--record-codex-startup` and `--context-continuation` calls, and `RELAY_REPLY_HELPER`, which then names the binary and is invoked as `"$RELAY_REPLY_HELPER" reply`. The skills `scripts/relay-bridge` installs make the same choice. `relay-rs` opens the intent inbox through bundled SQLite with the bridge's settings (WAL, `busy_timeout` 5000, `BEGIN IMMEDIATE`) and the same schema; `tests/test_hook_inbox_concurrency.py` runs it against a Python `ProviderTurnBroker` writing the same database.

The Python scripts stay bundled. Setting `RELAY_HOOK_RUNTIME=python` in the app's environment (for example `launchctl setenv RELAY_HOOK_RUNTIME python`, then relaunch Relay Runner) registers them again for both providers, with `RELAY_REPLY_HELPER` naming `services/relay_reply.py` and invoked as `/usr/bin/python3 "$RELAY_REPLY_HELPER"`. A build without `relay-rs` beside the app executable falls back the same way.

To run the suite against the Rust binary:

```bash
cargo build --release --manifest-path rust/Cargo.toml
RELAY_HOOK_CMD="'$PWD/rust/target/release/relay-rs' hook" RELAY_REPLY_CMD="'$PWD/rust/target/release/relay-rs' reply" \
    python3 -m unittest discover -s tests/contract -p 'test_hook_contract*.py'
```

## Running the suite

```bash
python3 -m unittest discover -s tests/contract -p 'test_hook_contract*.py'
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `RELAY_HOOK_CMD` | `/usr/bin/python3 services/relay_completion_hook.py` | The hook under test. Split like a shell command line; mode arguments are appended. |
| `RELAY_REPLY_CMD` | `/usr/bin/python3 services/relay_reply.py` | The reply helper under test. |
| `RELAY_HOOK_BUDGET_SECONDS` | `2.0` | The longest a lifecycle hook may take. Both providers stop a hook after 2 seconds. |

The suite needs macOS (`/bin/ps`, `/usr/sbin/lsof`, an 8192-byte FIFO buffer) and Python 3.9 or newer. Each case builds its own temporary directory and passes only the variables listed below, so it never writes to the files of a running Relay Runner session.

`--record-process` identifies the hook's parent process, so `RELAY_HOOK_CMD` must start the program directly, not through a wrapper that stays alive as its parent.

## Invocation modes

| Arguments | stdin | stdout | Exit code |
| --- | --- | --- | --- |
| none | One lifecycle event, a JSON object | Empty | Always 0 |
| `--record-process` | Ignored | Empty | 0 when the binding was written, otherwise 1 |
| `--record-codex-startup` | Ignored | Empty | 0 when the binding names a native session, otherwise 1 |
| `--context-continuation` | One request, a JSON object | One JSON object and a newline | Always 0 |
| reply helper, none | The reply text | Empty | Always 0 |

stderr carries free-form diagnostics. It never contains prompt text, reply text, summaries or compaction instructions.

## Environment variables

The suite sets these and no others, apart from `PATH`, `HOME` and, in one case, `LC_ALL`.

| Variable | Read by | Meaning |
| --- | --- | --- |
| `RELAY_RUNNER_PROVIDER` | hook | `claude` or `codex`. Selects the transcript parser and the turn-id rule. |
| `RELAY_APP_SESSION_ID`, `RELAY_RECOVERY_GENERATION`, `RELAY_ACTOR_ROLE`, `RELAY_FOREGROUND_GATE_HANDLE` | both | Foreground ownership. It holds when the role is `foreground_pm` or `foreground_manual` and the other three are non-empty. |
| `RELAY_PROVIDER_SESSION_ID` | both | The app's id for this provider launch (a UUID). |
| `RELAY_SESSION_KEY` | both | The voice session key. The reply helper falls back to the last component of `RELAY_SESSION_SPOOL_DIR`. |
| `RELAY_SESSION_SPOOL_DIR` | reply helper | The session's spool directory. |
| `VOICE_COMMAND_CLAIM_FILE` | both | The command this session claimed (input). |
| `VOICE_COMMAND_STATE_FILE` | both | The newest command and its dispositions (input). |
| `VOICE_FIFO` | both | The bridge's FIFO (output). |
| `RELAY_TERMINAL_MANUAL_SUBMISSION_FILE` | hook | Evidence that the user submitted a prompt in the terminal (input, consumed). |
| `VOICE_PROVIDER_TURNS_FILE` | hook | The version 1 turn ledger (output). |
| `VOICE_INTENT_INBOX` | hook | The SQLite inbox holding `intents` and the `provider_turn*` tables. |
| `VOICE_PROVIDER_TURN_PROJECTION_FILE` | hook | The JSON projection of `provider_turns` (output). |
| `RELAY_PROVIDER_TURN_BROKER_MODE` | hook | `legacy` keeps the ledger and skips the tables and the projection. Anything else writes both. |
| `RELAY_SESSION_EVENTS` | hook | Where `SessionStart` is recorded (output). |
| `RELAY_CONTEXT_COMPACTION_EVENTS` | hook | Where context diagnostics are recorded; falls back to `RELAY_SESSION_EVENTS`. |
| `RELAY_AUTO_COMPACT_THRESHOLD_TOKENS` | hook | Compaction threshold, default 150000, at least 1; a non-number means the default. |
| `RELAY_SESSION_BINDING_PATH`, `RELAY_CONTEXT_ID`, `RELAY_CONTEXT_WORKING_DIRECTORY` | hook | The session binding file and the launch it must match. |
| `RELAY_PROVIDER_PROCESS_ID` | hook | The provider's process id. |
| `RELAY_PROVIDER_BINARY`, `CODEX_HOME` | hook, `--record-codex-startup` | The provider executable (absolute) and the Codex home holding `thread-writer-locks/`. |

The hook also reads `VOICE_PROVIDER_TURN_TTL_SECONDS` (3600), `VOICE_PROVIDER_TURN_LIMIT` (32) and `RELAY_MANUAL_SUBMISSION_EVIDENCE_TTL_SECONDS` (10). The suite leaves them at their defaults.

## Lifecycle events

The event is a JSON object. The hook reads `hook_event_name`, `session_id`, `turn_id`, `provider_session_id` (each also accepted in camel case), `prompt_id`, `prompt`, `last_assistant_message`, `parent_tool_use_id`, `transcript_path`, `cwd`, `trigger` and `error`. Stdin that is not a JSON object, and an event name it does not know, are ignored.

A turn is named by `turn_id`. Claude sends none, so for Claude `prompt_id` stands in; for Codex `prompt_id` is ignored. An event with neither is tracked by a local sequence number, or by the session alone.

Every event first rewrites the session binding (see below). Then:

| Event | Provider | Effect |
| --- | --- | --- |
| `SessionStart` | Claude | Appends `{"outcome":"ready","stage":"provider_session_start","timestamp":…}` to `RELAY_SESSION_EVENTS`. Needs no foreground ownership. |
| `UserPromptSubmit` | both | Binds the prompt to the claimed command, or to a manual terminal submission, and announces `provider_started`. |
| `Stop` | both | Closes the turn and publishes the final reply. |
| `StopFailure` | Claude | Closes the turn as failed and publishes a completion without text. |
| `PreCompact`, `PostCompact` | both | Record a compaction attempt and its result. Need no foreground ownership. |

Without foreground ownership, `UserPromptSubmit`, `Stop` and `StopFailure` only rewrite the session binding. Otherwise every event after `SessionStart` appends one context diagnostic.

### Binding a prompt

A prompt binds to the claimed command when all of these hold:

- the claim has a `relay_command_id` and an integer `relay_command_seq`;
- the claim is the newest command in the state file, or is listed there under `deliverable_commands` with state `pending`, `delivered` or `claimed`;
- the prompt equals the claim's `agent_prompt`, or its `source_text` when there is no `agent_prompt`. For Claude the prompt may also be that text inside a complete `<pasted_content id="…">` envelope;
- the command has not already owned a provider turn.

An event without prompt text, or with a `parent_tool_use_id`, binds nothing.

A bound turn is written to the ledger, the tables and the projection as `active`, and `__PROVIDER_TURN_EVENT__:{"event":"provider_started",…}` is sent. Another active turn of the same foreground owner and provider session becomes `orphaned` (`superseded_by_prompt_submit`). Two cases differ: a second prompt for the same command under a new native identity rebinds the turn (`provider_identity_rebound`), and a second prompt under the same Codex turn id moves the physical turn to the newer command (`prompt_steered`).

A prompt that does not match a claim binds a manual turn only when the manual submission file holds fresh pending evidence for this owner, provider and provider session. The evidence is then marked `consumed`. Evidence carrying a `continuation_source` also needs the prompt's SHA-256 to match and the source request to be `ready` (see `--context-continuation`); the manual turn then carries the parent's intent and command.

### Completing a turn

`Stop` and `StopFailure` find the turn by its native session and turn id. Claude's `prompt_id` changes when a queued prompt is dequeued, so for Claude a sole active turn of the session is accepted. A Codex stop from a changed native session is reconciled through the provider session and turn id. When the ledger file is gone, the turn is found in the tables.

| Turn | Result | Ledger and table state |
| --- | --- | --- |
| Relay turn, command still current or preserved, `Stop` with text | Completion with `text` | `completed_final` |
| Same, `Stop` without text | Completion with `completion_status: empty` | `empty` |
| Same, `StopFailure` | Completion with `completion_status: failed` | `failed` |
| Relay turn, command superseded or its intent cancelled | Nothing published | `stale` |
| Manual turn | Nothing published | `completed_manual` or `failed_manual` |
| No turn, a finished turn, or another owner's turn | Nothing published | Unchanged |

A command is preserved when the newest command's `work_disposition` has `route: continue_current`, `authorization_effect: preserve` and a `cancellation_scope` of `none` or null. The ledger records `delivery: sent`, or `bridge_unavailable` when the FIFO is missing or has no reader.

### FIFO lines

Each line is a prefix, a JSON object and a newline. The JSON has sorted keys, `", "` and `": "` separators and ASCII-only escapes. The FIFO is opened for writing without blocking; a missing FIFO or one without a reader is not an error.

| Prefix | Fields |
| --- | --- |
| `__PROVIDER_TURN_EVENT__:` | `event`, `provider`, `relay_command_id`, `recovery_generation`, `observed_at` |
| `__RELAY_COMPLETION__:` | `event`, `relay_command_seq`, `relay_command_id`, `session_id`, the four ownership fields, and when present `session_key`, `intent_id`, `within_turn_order`, `target`, `disposition`, `cancellation_scope`, `turn_id`, `provider`, `action`; then `text` or `completion_status` |
| `__ORCHESTRATOR_REPLY__:` | `relay_command_id`, `relay_command_seq`, `text`, the four ownership fields, and when present `intent_id`, `session_key`, `provider_session_id` |

### Tables

The hook creates the `provider_turn_meta`, `provider_turn_owners`, `provider_turns`, `provider_turn_transitions` and `provider_turn_effects` tables when they are missing and sets `schema_version` to `3`. It never writes `intents` or `provider_turn_effects`. The suite's copy of the schema is `INBOX_SCHEMA` in `tests/contract/hook_contract_support.py`; rows the bridge would write are inserted there with plain SQL.

Identities are `kind + ":" + sha256(json([kind, …parts]))` over compact JSON:

| Identity | Parts |
| --- | --- |
| `owner` | app session id, recovery generation, actor role, foreground gate handle |
| `turn` | owner id, provider session id, native session id, then the native turn id, `local:<n>` or `session` |
| `activate` | turn id |
| `supersede` | previous turn id, new turn id |
| `steer` | turn id, origin, intent id, command seq, command id, manual submission id |
| `provider_completed`, `provider_completion_stale` | turn id, new state, release reason |

Transitions are `prompt_submitted`, `prompt_steered`, `superseded`, `provider_completed` and `provider_completion_stale`. Only an `active` turn can change state. The projection file is `{"schema_version":2,"updated_at":…,"records":[…]}` with mode 0600.

### Context diagnostics

Each event appends one compact, key-sorted JSON line to the compaction events file (mode 0600) with `timestamp`, `stage`, `outcome`, `provider`, `session_id`, `native_active_context_tokens`, `threshold_tokens`, `threshold_state` (`below`, `exact`, `above`, `unknown`), `idle_boundary`, `attempt`, `trigger`, `confirmation` and `failure_reason`.

| Event | Stage and outcome |
| --- | --- |
| `UserPromptSubmit` | `active_context_observed` / `busy` |
| `Stop` | `active_context_observed` / `idle` |
| `StopFailure` | `provider_turn_failed` / `failed`, with the first 80 characters of `error` |
| `PreCompact` | `compaction_attempt` / `started`; the attempt number advances per provider and session |
| `PostCompact` | `compaction_confirmed` / `confirmed` when the context is below the threshold, otherwise `compaction_unconfirmed` / `unconfirmed` with `native_context_not_reduced` |

After an unconfirmed compaction, the next `UserPromptSubmit` or `Stop` that sees the context below the threshold records `compaction_confirmed` for that attempt.

The context size is read from the last 2 MiB of `transcript_path`, newest line first; malformed lines are skipped and an unreadable transcript gives `null`.

- **Claude:** the newest of a `system` / `compact_boundary` record's `compactMetadata.postTokens`, or a main-chain `assistant` record's `message.usage`, summed as `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`. Sidechain records are skipped.
- **Codex:** `info.last_token_usage.total_tokens` of the newest `token_count`, either as the `payload` of an `event_msg` record or as a bare record. A `token_count` without usage info is skipped.

## Session binding

The binding file ties one app launch to the provider's native session:

```json
{"schema_version": 1, "context_id": "…", "provider": "codex", "provider_session_id": "…",
 "native_session_id": "…", "working_directory": "…", "transcript_path": "…",
 "provider_pid": 4242, "provider_process_identity": "…"}
```

It is written with mode 0600 beside a `<name>.lock` file, in a directory created with mode 0700. `provider_process_identity` is the output of `/bin/ps -p <pid> -o lstart= -o uid= -o pgid=`. A binding is written only when the provider is `claude` or `codex`, `RELAY_PROVIDER_SESSION_ID` is a UUID, the file is `bindings/<provider session id>.json`, and the working directory equals `RELAY_CONTEXT_WORKING_DIRECTORY` after resolving links.

- **Lifecycle event:** needs a UUID `session_id`; compares the event's `cwd`, or the process directory when it has none. `provider_pid` and its identity are included when `RELAY_PROVIDER_PROCESS_ID` names a running process. An event that cannot be bound is still handled.
- **`--record-process`:** `RELAY_PROVIDER_PROCESS_ID` must be the hook's own parent. Writes `native_session_id` and `transcript_path` as null.
- **`--record-codex-startup`:** Codex only. Starts from the binding `--record-process` wrote for this launch and watches that process until exactly one of its open files is `<CODEX_HOME>/thread-writer-locks/<uuid>.lock` and is exclusively locked, its directory is the working directory and its executable is `RELAY_PROVIDER_BINARY`. It then adds that UUID as `native_session_id`. It exits 0 at once when a lifecycle event has already supplied a native session, and exits 1 when the provider exits, the binding is replaced, or the lock does not name a session.

## `--context-continuation`

The app asks whether a request in one context may continue in another. The command only reads the inbox, and answers `{"status": …}` with an optional `message` or `source`.

| Request | Answer |
| --- | --- |
| `{"operation":"capture","source":{owner}}` | `active` with a `source` naming the newest turn of that owner, when it is active. |
| `{"operation":"check","source":{source}}` (the default operation) | `active` while the source turn runs, `ready` once it is `completed_final` or `completed_manual`. |
| `{"operation":"ack","source":{source},"destination":{owner},"submission_id":…}` | `consumed` once the destination owner has a turn with that manual submission id, otherwise `waiting`. |

An owner is `provider`, `provider_session_id`, `native_session_id`, `app_session_id`, `recovery_generation` and `foreground_gate_handle`, all non-empty; only `foreground_pm` turns are considered. A captured source adds `canonical_turn_id`, `owner_id`, `origin` and, when set, `native_turn_id`, `local_turn_seq`, `intent_id`, `command_seq`, `command_id` and `manual_submission_id`, all as strings.

The answer is `blocked` when the request is malformed, the inbox cannot be read, the source turn is unknown or did not finish successfully, a newer manual turn exists for the same owner and provider session (any newer turn, for a source without an intent), or the source's intent is missing, mismatched or not `acked`.

## Reply helper

The helper trims the reply and writes one `__ORCHESTRATOR_REPLY__:` line for the claimed command. It publishes only when the session has foreground ownership, the reply is not empty, the claim names a command, its intent is not listed in the state file's `cancelled_intent_ids`, and the claim is the newest command or the newest command preserves current work. When the state file has `session_commands[<session key>]`, the claim is judged against that entry instead of the shared newest command. Otherwise it writes nothing. It reads and writes no other file.

## Cases

Each case runs for both providers unless a class is named. File names are relative to `tests/contract/`.

| Mode | Success | Failure |
| --- | --- | --- |
| Claude `SessionStart` | `ClaudeTurnLifecycle.test_session_start_records_the_first_run_boundary` | `…test_session_start_with_an_unwritable_events_path_still_succeeds`, `…test_session_start_without_a_session_events_path_writes_nothing` |
| `UserPromptSubmit`, Claude and Codex | `test_prompt_submit_binds_the_claimed_relay_command`, `test_manual_terminal_submission_opens_and_closes_a_manual_turn` | `test_prompt_submit_with_a_stale_claim_is_not_bound`, `test_prompt_submit_with_a_mismatched_prompt_is_not_bound`, `test_prompt_submit_without_foreground_ownership_is_ignored` |
| `Stop`, Claude and Codex | `test_stop_publishes_the_final_reply` | `test_stop_for_a_superseded_command_is_dropped_as_stale`, `test_stop_without_a_fifo_reader_records_the_bridge_as_unavailable`, `test_stop_without_a_bound_turn_publishes_nothing` |
| Claude `StopFailure` | `ClaudeTurnLifecycle.test_stop_failure_publishes_a_failed_completion_without_text` | `…test_stop_failure_without_a_bound_turn_publishes_nothing`, `…test_stop_failure_without_foreground_ownership_leaves_the_turn_open` |
| `PreCompact`, Claude and Codex | `test_pre_compact_records_a_started_attempt` | `test_unwritable_events_path_is_ignored`, `test_no_events_path_records_nothing` |
| `PostCompact`, Claude and Codex | `test_post_compact_below_the_threshold_confirms_the_attempt` | `test_post_compact_without_a_reduction_is_unconfirmed`, `test_unwritable_events_path_is_ignored` |
| `--record-process`, Claude and Codex | `test_record_process_binds_the_parent_process` | `test_record_process_refuses_a_process_that_is_not_its_parent`, `test_record_process_refuses_a_launch_it_cannot_identify` |
| `--record-codex-startup`, Codex | `CodexBinding.test_startup_watcher_binds_the_session_of_the_held_writer_lock` | `CodexBinding.test_startup_watcher_gives_up_when_the_provider_exits`, `…test_startup_watcher_refuses_a_launch_it_cannot_identify` |
| `--record-codex-startup`, Claude | None: the mode is Codex only | `ClaudeBinding.test_startup_watcher_is_not_available_for_claude` |
| `--context-continuation`, Claude and Codex | `test_capture_names_the_active_relay_turn`, `test_check_reports_a_finished_source_as_ready`, `test_ack_waits_until_the_destination_accepts_the_submission` | `test_capture_is_blocked_without_an_active_turn`, `test_malformed_request_is_blocked`, `test_unavailable_inbox_is_blocked` |
| Reply helper, Claude and Codex | `test_reply_for_the_current_command_is_published_as_one_sorted_json_line` | `test_reply_for_a_superseded_command_is_dropped`, `test_reply_without_foreground_ownership_is_dropped` |

| Subject named in RR-477 | Cases |
| --- | --- |
| Claude `prompt_id` standing in for `turn_id` | `ClaudeTurnLifecycle.test_prompt_id_stands_in_for_the_turn_id`, `…test_stop_with_a_rotated_prompt_id_completes_the_sole_active_turn`, `CodexTurnLifecycle.test_prompt_id_is_not_a_turn_id_for_codex` |
| Both transcript token parsers | `ClaudeCompaction.test_context_is_input_plus_cache_tokens_of_the_newest_assistant_message`, `…test_newer_compact_boundary_reports_its_post_compaction_tokens`, `CodexCompaction.test_context_is_the_last_token_usage_of_the_newest_token_count`, `test_only_the_last_two_mebibytes_of_the_transcript_are_read` |
| Stale or mismatched claim | `test_prompt_submit_with_a_stale_claim_is_not_bound`, `test_prompt_submit_with_a_mismatched_prompt_is_not_bound`, `test_unreadable_claim_and_state_files_bind_nothing` |
| Missing FIFO reader | `test_prompt_submit_binds_without_a_fifo_reader`, `test_stop_without_a_fifo_reader_records_the_bridge_as_unavailable`, `test_reply_without_a_fifo_reader_is_dropped` |
| Locked database | `test_hook_waits_for_a_briefly_locked_inbox`, `test_stop_while_the_inbox_stays_locked_publishes_nothing`, `test_inbox_is_read_while_a_writer_holds_it` |
| Malformed stdin | `test_stdin_that_is_not_a_json_object_is_ignored`, `test_event_with_unusable_fields_is_ignored`, `test_malformed_request_is_blocked` |
| Timing | `test_every_lifecycle_hook_finishes_within_the_budget` prints the median and slowest latency on stderr |

## Known differences

These cases state the intended contract, and the current Python scripts fail them. They are expected failures while the default scripts are under test and ordinary cases for any command named in `RELAY_HOOK_CMD` or `RELAY_REPLY_CMD`.

| Case | What the Python script does |
| --- | --- |
| `test_hook_contract_faults.…test_reply_longer_than_the_fifo_buffer_arrives_whole` | The hook writes without waiting for the reader. A completion line longer than the 8192-byte FIFO buffer is cut off after 8192 bytes with no newline; the table row says `completed_final` while the ledger still says `active`. |
| `test_hook_contract_reply.…test_reply_longer_than_the_fifo_buffer_arrives_whole` | The same cut-off in the reply helper, which then exits 1 with a traceback. |
| `test_hook_contract_faults.…test_stdin_that_is_not_utf8_is_ignored` | Under a UTF-8 locale the hook exits 1 with a traceback when stdin is not valid UTF-8. |
| `test_hook_contract_faults.LockedInboxBudget.test_locked_inbox_is_given_up_within_the_hook_budget` | The hook waits 5 seconds for a locked inbox, past the providers' 2 second timeout. |

## Not covered

- The 120 second limit of `--record-codex-startup`.
- Revocation through the voice authorization ledger. `--context-continuation` reads `/tmp/voice_command_authorizations.json`, a fixed path the suite cannot point elsewhere, so the cases use command ids no real ledger contains.
- The ledger's age and size limits (`VOICE_PROVIDER_TURN_TTL_SECONDS`, `VOICE_PROVIDER_TURN_LIMIT`).
- The exact text of stderr diagnostics.
