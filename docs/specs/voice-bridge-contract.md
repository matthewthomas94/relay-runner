# Voice bridge contract

**Status:** Implemented (RR-483)

`services/voice_bridge.py` is the process between Relay Runner's voice input, the foreground Codex or Claude session, the persistent messenger, the speech service, the orchestrator daemon and Relay Remote. This document describes what the bridge does at its process boundary, as checked by the black-box suite `tests/contract/test_bridge_contract_*.py`. The suite starts the bridge as an opaque command, feeds it through its FIFOs and sockets, and observes the files it writes and the requests it makes to three fakes it owns. It imports nothing from `services/`, so a replacement written in another language is accepted against the same cases.

Every case is written once as a contract class and runs twice, once per provider: `ClaudeX` and `CodexX` subclasses set `RELAY_RUNNER_PROVIDER` and the `[general] provider` of the config. A case named below as `area/test_name` is `test_name` in `tests/contract/test_bridge_contract_<area>.py`.

Related contracts: the speech service the bridge starts is [speech-service-protocol.md](speech-service-protocol.md); the completion hook that writes the provider turn ledger and sends `__RELAY_COMPLETION__` is [hook-contract.md](hook-contract.md); Relay Remote framing is [relay-remote.md](relay-remote.md) with the shared vectors in `tests/RelayRemoteProtocolTests/Vectors`.

## Running the suite

```bash
python3 -m unittest discover -s tests/contract -p 'test_bridge_contract*.py'
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `RELAY_VOICE_BRIDGE_CMD` | `rust/target/debug/relay-rs bridge` (the folder is `RELAY_RUST_BIN_DIR` when set) | The bridge under test, split like a shell command line. `--config <path> --relay` are appended, and `--suppress-startup-greeting` for the cases that test it. |
| `RELAY_BRIDGE_CONTRACT_WAIT_SECONDS` | `10` | How long a case waits for something the bridge should do promptly. |
| `RELAY_BRIDGE_CONTRACT_QUIET_SECONDS` | `1.0` | How long a case watches for something that must not happen. |

The suite needs macOS and Python 3.10 or newer. A full run is 289 cases (each starts its own bridge, some two) and takes about 16 minutes; run one area with `-p 'test_bridge_contract_replies.py'`.

Each case builds a sandbox under a fresh `/tmp/rbc-XXXX` folder (short, because Unix socket paths are limited to 104 bytes on macOS) and starts the bridge with **only** the environment the sandbox builds: `HOME`, `PATH` (the sandbox's `bin/` first, then `/usr/bin:/bin`), `TMPDIR`, `LANG` and the variables in [Environment](#environment). Every path the bridge reads or writes is redirected into the sandbox, so a case never touches the sockets, mailbox, inbox or speech of a running Relay Runner session. The one exception is the continuity reply path, which the bridge accepts only under `/tmp` (see [Continuity](#continuity)); that case uses a unique name and removes the file.

### The isolation switch

Before RR-483 several bridge paths were fixed under `/tmp`. They now resolve under `RELAY_BRIDGE_RUNTIME_DIR`, whose default is `/tmp`, so a session that does not set it is unchanged. This is the same switch RR-485 gave the orchestrator daemon (`RELAY_ORCHESTRATOR_RUNTIME_DIR`). `VOICE_STATE_SOCK` is also honoured by the bridge now; the speech service already read it, and the app already sets it to `/tmp/voice_state.sock`, the same path. No other behaviour changed.

### The Rust bridge

RR-492 ports the bridge to Rust as `relay-rs bridge` (`rust/relay-rs/src/bridge/`). It covers the main loop, the FIFO and control-socket dispatch, the spool and mailbox files, the orchestrator client, focus and multi-session targeting, and the speech-service client. It also covers `pm_frontstage.py` and the bridge's use of the continuity modules. It builds on the `relay-intents` crate (RR-489), the Rust messenger backends (RR-490) and the Rust Relay Remote server (RR-491); the bridge hosts that server in-process. `voice_audio_lease.py` needs no port. Since RR-480 only the speech service (`tts_worker.py`) takes that lease, and the bridge always speaks through the speech service. Both providers change together, and the same cases accept the Rust bridge for each:

```bash
cargo build --manifest-path rust/Cargo.toml
RELAY_VOICE_BRIDGE_CMD="'$PWD/rust/target/debug/relay-rs' bridge" \
  python3 -m unittest discover -s tests/contract -p 'test_bridge_contract*.py'
```

Since the cut-over (RR-493) `scripts/relay-bridge` starts `relay-rs bridge` from the app bundle's `Contents/MacOS` (or a source checkout's cargo build) with the same arguments, for both providers and for Start Session, `--start-daemon`, the installed skills and the app watchdog alike. RR-487 removed the Python bridge (`services/voice_bridge.py`) and its `RELAY_BRIDGE_RUNTIME=python` rollback, so these cases now run against `relay-rs bridge` by default. Relay Runner and the scripts still recognise a `voice_bridge.py` process, but only to stop one an older release left running.

Intentional differences from the removed Python bridge, none visible to either provider:

- **`--relay` only.** The legacy direct mode exits with status 2.
- **No in-process speech.** `RELAY_SPEECH_SERVICE_MODE=legacy` is not read. If the speech service cannot be started, the bridge reports it on stderr and exits with status 1. The Python bridge fell back to speaking in-process.
- **Speech service choice.** `RELAY_SPEECH_SERVICE_CMD`, else `relay-speech` (`RELAY_SPEECH_BINARY`, or the one beside `relay-rs`). There is no Python fallback.
- **Relay Remote is always the in-process Rust server.** `RELAY_REMOTE_RUNTIME` is not read.

## The fakes

The suite owns three fakes and never reaches a model, a speaker or the real daemon.

| Fake | Where | What it does |
| --- | --- | --- |
| Orchestrator | `FakeOrchestrator` in `bridge_contract_support.py` | An HTTP server on `127.0.0.1` whose port is written to `ORCHESTRATOR_PORT_FILE`. It records every request (method, path, query, JSON body) and answers `/v1/orchestrator-session/ensure` with session `41` / `project:contract`, heartbeat and stop with `ok`, `/v1/messenger/outcomes` with the outcomes a case adds (removing one on `POST …/<id>/delivered`), and `/v1/runs`, `/v1/program/status`, `/v1/orchestrator-sessions`, `/v1/orchestrator-session/command` and `/v1/continuity/observation` with empty success. A case can make a path fail. |
| Messenger | `fakes/messenger.py`, run by `bin/claude` and `bin/codex` wrappers | Speaks the Claude stream-json protocol (`claude --print --input-format stream-json …`, plus `claude auth status --json`) and the Codex app-server JSON-RPC protocol (`initialize`, `model/list`, `thread/start`, `turn/start`, `turn/interrupt`, with `item/agentMessage/delta` and `turn/completed`). Replies come from `RELAY_CONTRACT_MESSENGER_SCRIPT`, re-read for every prompt; every launch and prompt is logged to `RELAY_CONTRACT_MESSENGER_LOG`. The config names the wrapper by absolute path, because the bridge checks known install paths before `PATH`. |
| Speech service | `fakes/speech_service.py`, started through `RELAY_SPEECH_SERVICE_CMD` | Speaks the speech protocol: answers `hello`, accepts and queues `speak`, answers every other request the bridge sends, publishes `state` and `reply_finished` events, and makes `remote_speech` calls for an attached Relay Remote sink. Every request is logged to `RELAY_CONTRACT_SPEECH_LOG`. A datagram on `RELAY_CONTRACT_SPEECH_CONTROL` makes it finish the head of its queue, refuse, report playing, or crash. |

The sandbox also binds `VOICE_STATE_SOCK` itself and collects every datagram the bridge sends the overlay.

## Process

```
voice_bridge --config <config.toml> --relay [--suppress-startup-greeting]
```

| Behaviour | Case |
| --- | --- |
| Creates `VOICE_FIFO` and the TTS FIFO as FIFOs, binds `BRIDGE_CONTROL_SOCK`, listens on `RELAY_REMOTE_SOCK`, and writes its pid to `voice_bridge.pid` in the runtime dir. | process/test_startup_creates_the_fifos_and_sockets_at_their_configured_paths |
| Replaces a leftover regular file at a FIFO path with a FIFO. | process/test_leftover_files_at_the_fifo_paths_are_replaced_by_fifos |
| Registers with `POST /v1/orchestrator-session/ensure` (repo path, provider, session key) and heartbeats the returned session every `ORCHESTRATOR_HEARTBEAT_SECONDS`. | process/test_startup_registers_the_orchestrator_session_and_heartbeats_it |
| Runs and delivers commands when no daemon answers. | process/test_bridge_runs_and_delivers_commands_without_the_daemon |
| Starts the speech service with `--socket`/`--config` and the session's state file, `SPEECH_EVENT_LOG`, `TTS_CONTROL_SOCK` and `VOICE_STATE_SOCK`. | process/test_startup_starts_the_speech_service_with_the_session_paths |
| Without `RELAY_SPEECH_SERVICE_CMD`, starts the relay-speech `RELAY_SPEECH_BINARY` names. | process/test_without_a_command_the_bridge_starts_relay_speech |
| Restarts a crashed speech service and resubmits its queue. | restart/test_a_crashed_speech_service_is_started_again_and_given_its_queue |
| Speaks the startup greeting once, with no command. | process/test_startup_greeting_is_spoken_once_without_a_command |
| `--suppress-startup-greeting` skips the greeting and the messenger's first reply. | process/test_suppressed_greeting_also_skips_the_first_messenger_reply |
| Records readiness in the support journal under `RELAY_DIAGNOSTICS_DIR`. | process/test_readiness_is_recorded_in_the_support_journal |
| `shutdown` stops the bridge, posts `/v1/orchestrator-session/stop` and removes its FIFOs, sockets and pid file. | process/test_shutdown_request_stops_the_bridge_and_removes_its_files |
| Start-up removes a previous run's mailbox, claim, ack, turn ledger and authorization ledger and replaces the command state. | restart/test_startup_removes_files_a_previous_run_left |
| A recoverable command the daemon reports as `delivery_failed` is announced with a `working` state asking the user to repeat it. | process/test_a_command_whose_delivery_failed_is_reported_at_startup |

## Environment

The suite sets every variable below in each sandbox unless the Case column names a case that sets or changes it.

| Variable | Default | Meaning | Case |
| --- | --- | --- | --- |
| `RELAY_BRIDGE_RUNTIME_DIR` | `/tmp` | Folder for the bridge's own files: `voice_bridge.pid`, `.cwd`, `.provider`, `.spool`, `voice_bridge_watchdog_restart`, `voice_bridge_stop_requested`, `tts_in.fifo`, `voice_command_state.json` and `relay-sessions/`. | process/test_startup_creates_the_fifos_and_sockets_at_their_configured_paths |
| `VOICE_FIFO` | `/tmp/voice_in.fifo` | The voice input FIFO ([FIFO tokens](#fifo-tokens)). | fifo/test_user_turn_starts_a_command_for_speech_messenger_and_mailbox |
| `BRIDGE_CONTROL_SOCK` | `/tmp/voice_bridge.sock` | Datagram control socket ([Control socket](#control-socket)). | process/test_ping_and_unknown_commands_leave_the_bridge_running |
| `VOICE_STATE_SOCK` | `<runtime>/voice_state.sock` | The overlay's datagram socket the bridge sends state to. | fifo/test_user_turn_starts_a_command_for_speech_messenger_and_mailbox |
| `RELAY_REMOTE_SOCK` | `/tmp/relay_remote.sock` | Relay Remote stream socket. | remote/test_first_hello_is_welcomed_fresh |
| `TTS_CONTROL_SOCK` | `/tmp/tts_control.sock` | Passed to the speech service. | process/test_startup_starts_the_speech_service_with_the_session_paths |
| `RELAY_SPEECH_SERVICE_CMD` | unset | The speech service command; unset starts `RELAY_SPEECH_BINARY`. | process/test_startup_starts_the_speech_service_with_the_session_paths |
| `RELAY_SPEECH_BINARY` | the `relay-speech` beside `relay-rs` | The speech service started when `RELAY_SPEECH_SERVICE_CMD` is unset. | process/test_without_a_command_the_bridge_starts_relay_speech |
| `RELAY_SPEECH_SERVICE_SOCK` | `/tmp/relay_speech_service.sock` | The speech service's socket. | process/test_startup_starts_the_speech_service_with_the_session_paths |
| `SPEECH_EVENT_LOG` | `/tmp/relay_speech_events.jsonl` | Passed to the speech service. | process/test_startup_starts_the_speech_service_with_the_session_paths |
| `VOICE_INTENT_INBOX` | `/tmp/relay_intent_inbox.sqlite3` | The durable intent inbox. | commands/test_claim_then_acknowledgement_moves_the_intent_through_its_states |
| `VOICE_PROVIDER_TURNS_FILE` | `/tmp/voice_provider_turns.json` | The v1 provider turn ledger the completion hook writes (input). | commands/test_a_provider_turn_in_the_ledger_acknowledges_a_claim |
| `VOICE_PROVIDER_TURN_PROJECTION_FILE` | `/tmp/voice_provider_turns_v2.json` | The v2 turn projection the bridge writes. | environment/test_the_turn_projection_is_written_unless_the_broker_is_legacy |
| `RELAY_PROVIDER_TURN_BROKER_MODE` | `dual_write` | `legacy` writes no v2 projection. | environment/test_the_turn_projection_is_written_unless_the_broker_is_legacy |
| `VOICE_COMMAND_AUTHORIZATION_FILE` | `/tmp/voice_command_authorizations.json` | The authorization ledger. | commands/test_authorizations_follow_the_turns_relationship |
| `VOICE_COMMAND_EVENT_LOG` | `~/Library/Application Support/relay-runner/command-actions/events.jsonl` | Private command log, mode `0600`. | commands/test_private_command_log_records_each_intents_states |
| `VOICE_COMMAND_EVENT_LIMIT` | `200` | Events kept in the private log. | commands/test_private_command_log_keeps_only_the_newest_events |
| `RELAY_DIAGNOSTICS_DIR` | `~/Library/Application Support/relay-runner/support-diagnostics/v1` | Support journal folder. | process/test_readiness_is_recorded_in_the_support_journal |
| `RELAY_RUNNER_APP_SESSION` | unset | `1`: an app-owned session using a session spool. | commands/test_mailbox_holds_the_agent_prompt_and_its_metadata |
| `RELAY_SESSION_SPOOL_DIR` | unset | The session's spool; a folder directly under `<runtime>/relay-sessions/` also names the session key. | commands/test_mailbox_holds_the_agent_prompt_and_its_metadata |
| `RELAY_SESSION_KEY` | derived from the spool | The voice session key. | replies/test_daemon_outcomes_are_spoken_and_marked_delivered |
| `RELAY_PROVIDER_SESSION_ID` | unset | Foreground provider session; matched against completions and ledger turns. | replies/test_completion_with_text_is_spoken_as_the_completion_final |
| `RELAY_APP_SESSION_ID` | unset | App session identity checked by continuity controls. | restart/test_continuity_resume_for_another_session_or_generation_does_nothing |
| `RELAY_RECOVERY_GENERATION` | unset | Recovery generation; a new one retires older unacknowledged work. | restart/test_a_new_recovery_generation_retires_the_old_unacknowledged_work |
| `RELAY_CONTINUITY_RECOVERY_PENDING` | unset | `1` keeps the command state across start-up. | restart/test_pending_continuity_recovery_keeps_the_command_state |
| `RELAY_PRESERVE_CONTEXT_AUTHORIZATION` | unset | `1` keeps the authorization ledger across start-up. | restart/test_preserved_context_keeps_the_authorization_ledger |
| `VOICE_CMD_FILE` | `<spool or runtime>/voice_cmd_ready` | The mailbox; set explicitly for a manual bridge. | commands/test_a_manual_bridge_uses_the_legacy_mailbox_paths |
| `VOICE_COMMAND_STATE_FILE` | `<spool or runtime>/voice_command_state.json` | The command state; also passed to the speech service. | commands/test_a_manual_bridge_uses_the_legacy_mailbox_paths |
| `VOICE_COMMAND_CLAIM_FILE` | `<spool or runtime>/voice_cmd_claimed.json` | The claim file. | commands/test_a_manual_bridge_uses_the_legacy_mailbox_paths |
| `VOICE_MANUAL_CLAIM_ACK_FILE` | `<spool or runtime>/voice_cmd_manual_ack.json` | The claim acknowledgement. | commands/test_a_manual_bridge_uses_the_legacy_mailbox_paths |
| `RELAY_RUNNER_PROVIDER` | config `[general] provider` | Provider the bridge reports. | process/test_startup_registers_the_orchestrator_session_and_heartbeats_it |
| `ORCHESTRATOR_PORT_FILE` | `/tmp/relay_orchestrator.port` | Where the daemon's port is read. | process/test_startup_registers_the_orchestrator_session_and_heartbeats_it |
| `ORCHESTRATOR_DEFAULT_PORT` | `7634` | Port used without a port file; the suite sets `9`, which nothing answers. | process/test_bridge_runs_and_delivers_commands_without_the_daemon |
| `ORCHESTRATOR_HEARTBEAT_SECONDS` | `10` | Heartbeat interval. | process/test_startup_registers_the_orchestrator_session_and_heartbeats_it |
| `MESSENGER_OUTCOME_POLL_SECONDS` | `2` | Outcome poll interval. | replies/test_daemon_outcomes_are_spoken_and_marked_delivered |
| `PM_UPDATE_POLL_SECONDS`, `PM_UPDATE_CADENCE_SECONDS`, `PM_UPDATE_STARTUP_GRACE_SECONDS` | `2`, `8`, `6` | PM update reads after project work. | commands/test_project_work_is_queued_on_the_ticket_path_and_fanned_out |
| `FOREGROUND_REPLY_FALLBACK_SECONDS` | `120` | Wait before the missing-reply fallback; the suite sets `600`, the fallback cases `0.5`. | replies/test_empty_completion_speaks_the_missing_reply_fallback |
| `PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS` | `5` | How often an active turn is rechecked before the fallback. | replies/test_the_fallback_waits_while_the_provider_turn_is_active |
| `RELAY_WORK_STYLE` | unset | `auto`, `direct` or `orchestrated`; overrides the session file. | environment/test_relay_work_style_direct_makes_a_change_request_inline_work |
| `RELAY_SESSION_WORK_STYLE_FILE` | `~/Library/Application Support/relay-runner/session-work-style.json` | The session's saved work style. | environment/test_the_session_work_style_file_applies_and_the_variable_wins |
| `RELAY_SESSION_SCOPE`, `RELAY_GENERAL_FILES_ROOT` | unset | `general` with the general-tasks folder: ticket work there is general, not project, work. | environment/test_a_general_session_keeps_ticket_work_off_the_project |
| `VOICE_TERMINAL_<SECTION>_<KEY>` | unset | Value for a config key the file leaves out. | environment/test_a_setting_missing_from_the_config_file_comes_from_the_environment |
| `HOME`, `PATH` | | Default file locations; the messenger child's search path. | messenger/test_messenger_is_started_tool_free_on_the_configured_provider |

Read by the bridge or a module it imports, but not part of this contract (see [Not covered](#not-covered)): `RELAY_SPEECH_SERVICE_MODE`, `VOICE_ACKNOWLEDGEMENT`, `FOREGROUND_REPLY_HARD_CEILING_SECONDS`, `FOREGROUND_REPLY_TRACE_ACTIVE_SECONDS`, `RELAY_CODEX_MODEL_LIST_JSON`, `RELAY_CORRELATION_ID`, `XDG_CONFIG_HOME`, `CLAUDE_CONFIG_DIR`, `ANTHROPIC_CONFIG_DIR`, `ANTHROPIC_BASE_URL` and the metered-route variables `claude_subscription.py` refuses. `VOICE_MODELS_DIR` and `RELAY_TUTORIAL_TTS` belong to the speech worker.

## Config

The suite writes this `config.toml`:

```toml
[general]
provider = "claude"            # or "codex"
command = "<sandbox>/bin/claude"
messenger_enabled = true
[tts]
auto_play = false
```

| Key | Case |
| --- | --- |
| `[general] provider`, `command` | messenger/test_messenger_is_started_tool_free_on_the_configured_provider, messenger/test_a_missing_provider_command_speaks_the_degraded_acknowledgement |
| `[general] messenger_enabled` | messenger/test_a_disabled_messenger_is_silent |
| `[tts]` (passed through) | process/test_reload_rereads_the_speech_configuration |

## Files and sockets

`<spool>` is the session spool (`RELAY_SESSION_SPOOL_DIR`); a manual bridge uses the legacy variables instead.

| Path | Writer | Contents | Case |
| --- | --- | --- | --- |
| `<spool>/voice_cmd_ready` | bridge | The agent prompt of the delivered intent. | commands/test_mailbox_holds_the_agent_prompt_and_its_metadata |
| `<spool>/voice_cmd_ready.meta` | bridge | Its metadata (below). | commands/test_mailbox_holds_the_agent_prompt_and_its_metadata |
| `<spool>/voice_cmd_claimed.json` | session | The claimed metadata; the bridge then records the intent `claimed`. | commands/test_claim_then_acknowledgement_moves_the_intent_through_its_states |
| `<spool>/voice_cmd_manual_ack.json` | session | Acknowledges a claim when its ids match; the bridge removes it. | commands/test_an_acknowledgement_that_does_not_match_the_claim_is_ignored |
| `<spool>/voice_command_state.json` | bridge | The newest command, `deliverable_commands`, `cancelled_intent_ids`, `inbox_recovery_blocker`, `source_command_intents`, `session_commands`. | replies/test_reply_for_a_cancelled_intent_is_dropped, restart/test_a_claimed_unacknowledged_command_becomes_a_recovery_blocker |
| `<spool>/voice_reply_badge.json` | nobody | No longer written (RR-488): a background session's reply is spoken in turn, and its outcomes wait for focus uncounted. The cases check the file stays absent. | sessions/test_background_reply_is_spoken_in_its_session_without_a_badge, sessions/test_focused_session_hears_its_outcomes_and_others_wait_for_focus |
| `<runtime>/voice_bridge.pid` | bridge | Its pid. | process/test_startup_creates_the_fifos_and_sockets_at_their_configured_paths |
| `<runtime>/voice_bridge.cwd`, `.provider`, `.spool` | bridge | The focused session's directory, provider and spool, written on focus. | sessions/test_focus_moves_turns_to_the_focused_session |
| `<runtime>/voice_bridge_watchdog_restart` | app | Names the bridge pid and provider; keeps the claim, turns and command state across the stop. | restart/test_a_watchdog_restart_keeps_the_claim_turns_and_command_state, restart/test_a_marker_for_another_bridge_does_not_preserve |
| `<runtime>/voice_bridge_stop_requested` | app | An explicit stop: clean up despite a watchdog marker. | restart/test_an_explicit_stop_request_cleans_despite_the_marker |
| `<runtime>/tts_in.fifo` | others | Lines to speak; dropped when stale. | commands/test_tts_fifo_lines_are_spoken_unless_stale |
| `VOICE_INTENT_INBOX` | bridge | `intents` rows: `pending → delivered → claimed → acked`, or `cancelled`, `review_required`. | commands/test_claim_then_acknowledgement_moves_the_intent_through_its_states |
| `VOICE_COMMAND_AUTHORIZATION_FILE` | bridge | `authorizations` records with `relay_session_key`, `status` and `revoked_by.relationship`. | commands/test_authorizations_follow_the_turns_relationship |
| `VOICE_COMMAND_EVENT_LOG` | bridge | One private JSON line per intent state. | commands/test_private_command_log_records_each_intents_states |
| `VOICE_PROVIDER_TURNS_FILE` | completion hook | v1 turn records with ownership and state. | commands/test_a_provider_turn_in_the_ledger_acknowledges_a_claim, replies/test_the_fallback_waits_while_the_provider_turn_is_active |
| `VOICE_PROVIDER_TURN_PROJECTION_FILE` | bridge | `{"schema_version": 2, "records": [...]}`. | environment/test_the_turn_projection_is_written_unless_the_broker_is_legacy |
| `RELAY_DIAGNOSTICS_DIR/events-v1-shell-<pid>.jsonl` | bridge | Support journal. | process/test_readiness_is_recorded_in_the_support_journal |

### Mailbox metadata

The `.meta` file carries at least: `relay_command_seq`, `relay_command_id`, `intent_id`, `within_turn_order`, `source_text`, `action`, `work_disposition`, `cancellation_scope`, `preempt_provider`, `target_intent_ids`, `intent_qualification`, `deliverable_commands`, `cancelled_intent_ids`, `inbox_recovery_blocker`, `recovery_generation`, `voice_target_session_key` and `provider`. The agent prompt in `voice_cmd_ready` ends with the command action, the work-intent disposition and the provisional intent qualification. (commands/test_mailbox_holds_the_agent_prompt_and_its_metadata)

## FIFO tokens

Each line on `VOICE_FIFO` is one input, UTF-8, ended by `\n`; a line may arrive in pieces and blank lines are ignored. A line that is not a token is a user turn.

| Input | Effect | Case |
| --- | --- | --- |
| user text | New command: next `relay_command_seq`, new id, `new_turn` to speech, an `acknowledgement` state, a `user_turn` prompt to the messenger, an intent in the inbox and, when it is next, the mailbox. | fifo/test_user_turn_starts_a_command_for_speech_messenger_and_mailbox, fifo/test_each_turn_takes_the_next_sequence_number_and_a_new_id, fifo/test_text_is_kept_exactly_and_a_line_may_arrive_in_pieces |
| `slash foo` spoken | Becomes `/foo`. | fifo/test_spoken_slash_commands_become_slash_commands |
| `__TTS_STOP__` | `stop_playback` as a barge-in. | fifo/test_tts_stop_stops_playback_as_a_barge_in |
| `__INTERRUPT__` | Stops speech and publishes an interrupt command that supersedes the current one. | fifo/test_interrupt_stops_speech_and_publishes_an_interrupt_command, remote/test_interrupt_control_publishes_an_interrupt_command |
| `__CANCEL__` | `skip`; no command; clears a voice target pin; offers no other reply itself (the speech queue plays the next). | fifo/test_cancel_dismisses_speech_without_starting_a_command, sessions/test_cancel_clears_a_voice_target_pin, sessions/test_background_reply_queues_behind_playing_speech_once |
| `__PLAY__`, `__PLAY__:<json>` | `note_play_control`, then `play_or_replay`. | fifo/test_play_records_the_gesture_and_plays_or_replays |
| `__PLAY_ACK__:<json>` | `note_visual_acknowledgement`; malformed records nothing. | fifo/test_play_ack_records_the_visual_acknowledgement |
| `__REPLAY__` | `replay`. | fifo/test_replay_asks_speech_to_replay |
| `__STATUS__:<json>` | While refining, reports transcription started. | fifo/test_status_while_refining_reports_transcription_started |
| `__CONTINUITY__:<json>` | Posted to `/v1/continuity/observation` as an opaque observation. | fifo/test_continuity_signals_are_reported_as_observations |
| `__VOICE_TARGET__:<json>` | Pins only the next transcript to a session. | sessions/test_voice_target_pins_only_the_next_transcript |
| `__SKIP_UNCERTAIN__:<json>` | With the exact recovery blocker, cancels it and releases the queue; anything else changes nothing. | restart/test_skip_uncertain_with_the_exact_blocker_releases_the_queue |
| `__ORCHESTRATOR_REPLY__:<json>` | The foreground's final ([Replies](#replies)). | replies/test_reply_for_the_current_command_is_spoken_once_as_its_final |
| `__RELAY_COMPLETION__:<json>` | The completion hook's final. | replies/test_completion_with_text_is_spoken_as_the_completion_final |
| `__PROVIDER_TURN_EVENT__:<json>` | Reported as a continuity observation. | replies/test_provider_turn_events_are_reported_as_continuity_observations |
| `__TRACE__:<json>` | Progress to the overlay and messenger ([Traces](#traces)). | replies/test_trace_for_the_current_command_reaches_the_overlay_and_the_messenger |
| unknown `__X__:`, raw control-shaped JSON, spaced reserved tokens | Quarantined, payload not logged; token-like prose stays a turn. | fifo/test_unknown_and_malformed_controls_are_quarantined |

## Control socket

Datagrams on `BRIDGE_CONTROL_SOCK`, at most 4096 bytes. macOS refuses back-to-back sends with `ENOBUFS`; a sender retries.

| Datagram | Effect | Case |
| --- | --- | --- |
| `ping` | Nothing; the bridge stays up. | process/test_ping_and_unknown_commands_leave_the_bridge_running |
| anything unknown | Ignored. | process/test_ping_and_unknown_commands_leave_the_bridge_running |
| `reload` | `reload_config` to speech. | process/test_reload_rereads_the_speech_configuration |
| `shutdown` | Clean stop. | process/test_shutdown_request_stops_the_bridge_and_removes_its_files |
| `__FOCUS__:<json>` | Focuses or registers (`focus: false`) a session; invalid payloads are rejected; a focus switch leaves speech alone (RR-488). | sessions/test_focus_moves_turns_to_the_focused_session, sessions/test_invalid_focus_payloads_are_rejected, sessions/test_focus_false_registers_without_focusing, sessions/test_focus_switch_leaves_playing_speech_alone |
| `__REPLAY__:<json>` | `control_session` to speech with `play`, then `replay` when not handled; nothing for an unknown session. | sessions/test_replay_asks_speech_to_play_then_replay_the_session |
| `__SESSION_PLAYBACK__:<json>` | `control_session` to speech: `stop` only stops; `play` falls back to `replay`. The bridge reads nothing out itself. | sessions/test_session_playback_asks_speech_for_the_session |
| `{"type": "continuity_recovery", …}` | Answers on its `reply_path`. | restart/test_invalid_continuity_recovery_reports_failure_to_its_reply_path |
| `{"type": "continuity_resume", …}` | Please-repeat after lost speech, once; ignored for another session or generation. | restart/test_continuity_resume_after_lost_speech_asks_the_user_to_repeat, restart/test_continuity_resume_for_another_session_or_generation_does_nothing |
| `{"type": "continuity_provider_ready", "event": "provider_ready", …}` | Accepted only for the exact replacement. | restart/test_provider_ready_for_the_exact_replacement_is_accepted, restart/test_provider_ready_for_a_mismatched_replacement_is_refused |

The bridge also publishes `session_playback` and `speech_queue` datagrams to `VOICE_STATE_SOCK` (process/test_session_playback_states_are_published_to_the_overlay).

## Commands, the inbox and the claim lifecycle

| Rule | Case |
| --- | --- |
| An intent is `delivered` when the mailbox is written, `claimed` when the claim file appears, `acked` on a matching acknowledgement. | commands/test_claim_then_acknowledgement_moves_the_intent_through_its_states |
| A ledger turn owned by this session acknowledges the claim. | commands/test_a_provider_turn_in_the_ledger_acknowledges_a_claim |
| An acknowledgement whose ids do not match is ignored. | commands/test_an_acknowledgement_that_does_not_match_the_claim_is_ignored |
| One unacknowledged intent per session: a newer one waits; queued ones go in arrival order. | commands/test_a_newer_turn_waits_until_the_delivered_one_is_acknowledged, commands/test_queued_turns_are_delivered_in_arrival_order |
| "X and then Y" is two items with `within_turn_order` 1 and 2. | commands/test_a_turn_with_two_requests_becomes_two_ordered_items |
| Project work is `queue_project_work`, posted to `/v1/orchestrator-session/command` and followed by PM update reads. | commands/test_project_work_is_queued_on_the_ticket_path_and_fanned_out |
| Conversation is not posted. | commands/test_conversation_is_not_fanned_out_to_the_daemon |
| An ambiguous cancellation is `clarify_priority`. | commands/test_an_ambiguous_cancellation_asks_for_its_target |
| A scoped cancellation is `replace_current` / `item` and cancels only the item it names. | commands/test_a_scoped_cancellation_cancels_only_the_queued_item_it_names |
| "Stop everything" is `replace_current` / `all_work` with `preempt_provider`. | commands/test_cancelling_everything_cancels_all_queued_work_and_preempts |
| A read-only task beside another session's active work is `run_sidecar`, answered without the mailbox. A busy foreground is steered instead. | commands/test_a_read_only_task_beside_other_active_work_runs_as_a_sidecar, commands/test_a_busy_foreground_provider_is_steered_instead_of_a_sidecar |
| Authorizations are recorded and revoked by relationship. | commands/test_authorizations_follow_the_turns_relationship |
| The work style routes an undecided change request. | environment/test_auto_leaves_a_change_request_undecided, environment/test_relay_work_style_direct_makes_a_change_request_inline_work |
| A negated stop asking for status, and a request to explain Relay Runner to an audience, are `conversation` that preserves current work. | classification/test_a_negated_stop_asking_for_status_preserves_the_current_work, classification/test_a_demo_explanation_is_conversation |
| A question followed by a change is one non-mutating clarification: nothing authorized, nothing posted. | classification/test_a_question_followed_by_a_change_asks_one_clarification |
| The acknowledgement never repeats a secret or the transcript. | classification/test_the_acknowledgement_never_repeats_a_secret |

## Replies

A reply is `__ORCHESTRATOR_REPLY__:{"relay_command_seq", "relay_command_id", "text", …}`; a completion is `__RELAY_COMPLETION__:{…}` from the hook. A reply is spoken when its command is current, or is preserved by a newer `continue_current` turn, and its intent is not cancelled.

| Rule | Case |
| --- | --- |
| Spoken once as the authoritative final. | replies/test_reply_for_the_current_command_is_spoken_once_as_its_final |
| Its `display_text` has whitespace collapsed; the speech service shows it as the waiting preview. | replies/test_a_replys_display_text_has_its_whitespace_collapsed |
| A completion with text is spoken as source `completion`. | replies/test_completion_with_text_is_spoken_as_the_completion_final |
| Reply and completion for one command are spoken once, either order. | replies/test_reply_then_completion_for_one_command_is_spoken_once, replies/test_completion_then_reply_for_one_command_is_spoken_once |
| A superseded command's reply is dropped; a preserved one is spoken. | replies/test_reply_for_a_superseded_command_is_dropped, replies/test_reply_preserved_by_a_newer_conversation_turn_is_spoken |
| A cancelled intent's reply is dropped. | replies/test_reply_for_a_cancelled_intent_is_dropped |
| Malformed or unkeyed replies are ignored. | replies/test_malformed_and_unkeyed_replies_are_ignored |
| An empty completion speaks the missing-reply fallback; project work's says worker updates still come. | replies/test_empty_completion_speaks_the_missing_reply_fallback, replies/test_project_work_fallback_says_worker_updates_still_come |
| Claiming a command without a finished turn starts no fallback. | replies/test_a_claimed_command_without_a_finished_turn_gets_no_fallback |
| A reply cancels the fallback; it waits while the turn is active; none once superseded. | replies/test_a_reply_before_the_fallback_fires_cancels_it, replies/test_the_fallback_waits_while_the_provider_turn_is_active, replies/test_no_fallback_once_the_command_is_superseded |
| Without the messenger a reply goes straight to speech. | replies/test_without_the_messenger_a_reply_goes_straight_to_speech |
| Replies survive a restart. | restart/test_a_reply_after_a_restart_is_still_spoken |

### Traces

| Rule | Case |
| --- | --- |
| A trace for the current command sends a `working` state and a messenger progress prompt; it never speaks directly. | replies/test_trace_for_the_current_command_reaches_the_overlay_and_the_messenger |
| A long trace is cut to 96 characters ending `...` on the overlay and kept whole for the messenger. | replies/test_long_progress_is_compact_on_the_overlay_and_whole_for_the_messenger |
| A trace without a command uses the claimed command. | replies/test_trace_without_a_command_uses_the_claimed_command |
| A superseded trace is dropped. | replies/test_trace_for_a_superseded_command_is_dropped |
| `clarification-request` is asked by the messenger. | replies/test_clarification_request_trace_is_asked_by_the_messenger |

### Daemon outcomes

| Rule | Case |
| --- | --- |
| `GET /v1/messenger/outcomes` (with `repo_path`, `provider`, `limit=50`, `session_key`, `live_session_keys`) is polled; each outcome is spoken and `POST …/delivered`. | replies/test_daemon_outcomes_are_spoken_and_marked_delivered |
| Two or more at once are summarised in one update. | replies/test_several_outcomes_at_once_are_summarised_in_one_update |
| An outcome's whole `lifecycle_detail` reaches the messenger even when its `message` is cut short. | replies/test_an_outcomes_whole_lifecycle_detail_reaches_the_messenger |
| Not polled without the messenger. | replies/test_without_the_messenger_outcomes_are_not_polled |
| The focused session hears its outcomes; others stay undelivered and uncounted until focused. | sessions/test_focused_session_hears_its_outcomes_and_others_wait_for_focus |

## Messenger

| Rule | Case |
| --- | --- |
| Started tool-free. Claude: `--print`, stream-json both ways, `--tools ""`, `--mcp-config '{"mcpServers":{}}'`, `--strict-mcp-config`, `--disable-slash-commands`. Codex: `app-server --stdio`, shell, apps, hooks, web search and MCP servers off; one ephemeral, read-only, `approvalPolicy: never` thread. The child gets `RELAY_ACTOR_ROLE=messenger` and none of the foreground's session variables. | messenger/test_messenger_is_started_tool_free_on_the_configured_provider |
| A `__HANDOFF__` reply is spoken as a `handoff` acknowledgement; `__ANSWER__` as `conversation`. | messenger/test_user_turn_reaches_the_messenger_and_its_handoff_is_spoken, messenger/test_an_answer_is_spoken_as_conversation |
| Stages `messenger_submitted`, `messenger_provider_started`, `messenger_first_semantic_output`. | messenger/test_messenger_stages_are_recorded_with_the_provider |
| `__SILENT__` or a failed turn speaks the degraded acknowledgement. | messenger/test_silence_or_failure_speaks_the_degraded_acknowledgement |
| A newer turn drops the unfinished answer. | messenger/test_a_newer_turn_drops_the_messengers_unfinished_answer |
| The final is spoken verbatim; a final adding nothing to the messenger's answer is not spoken again. | messenger/test_the_orchestrators_final_is_spoken_without_asking_the_messenger, messenger/test_a_final_that_repeats_the_messengers_answer_is_not_spoken_again |
| A missing command is `messenger_failed` / `provider_unavailable`; disabled is silent. | messenger/test_a_missing_provider_command_speaks_the_degraded_acknowledgement, messenger/test_a_disabled_messenger_is_silent |

### Rust backends

RR-490 ported the messenger's provider backends to Rust (`rust/relay-rs/src/messenger/`): the Claude stream-json and Codex app-server processes, the model and effort resolution (Codex through `model/list`), the Claude subscription gate, warm-up, re-binding to the focused session and interruption. `relay-rs bridge` runs them in-process. Both providers move together, and what they send the provider is unchanged: the launch command and environment, `thread/start` and `turn/start` parameters, stream-json input and the interrupt path. RR-487 removed the Python messenger and its `RELAY_MESSENGER_RUNTIME` switch.

### Provider differences

| | Claude | Codex |
| --- | --- | --- |
| Auth gate | `claude auth status --json` before each start; without a verified subscription the messenger never starts (messenger/test_an_unverified_claude_subscription_keeps_the_messenger_down, Claude only) | none; `codex login` is out of band |
| Interrupting a turn | restart the process with `--resume <session>` | `turn/interrupt` |
| Provider turn events | `stream_*` | `turn_*` |
| Model catalog | | `app-server` is launched for `model/list` even with the messenger disabled, for the sidecar lane |

## Sessions and voice targeting

| Rule | Case |
| --- | --- |
| Each added session registers its own orchestrator session; pruning one stops it. | sessions/test_each_added_session_registers_its_own_orchestrator_session |
| A pruned session hands its undelivered command to the focused one. | sessions/test_pruned_session_hands_its_undelivered_command_to_the_focused_session |
| A background session's reply is spoken for that session (RR-488): no messenger, no command key, `dedup_key` `outcome:<seq>:<id>`, judged against its own session's command; a completion is matched by provider session. | sessions/test_background_reply_is_spoken_in_its_session_without_a_badge, sessions/test_background_completion_is_matched_by_its_provider_session |
| A background reply queues behind playing speech as one `speak` and never cuts in; `reply_finished` and `__CANCEL__` make the bridge offer nothing again. | sessions/test_background_reply_queues_behind_playing_speech_once |

## Relay Remote

`RELAY_REMOTE_SOCK` carries the newline-JSON frames of [relay-remote.md](relay-remote.md); the cases use the vectors in `tests/RelayRemoteProtocolTests/Vectors`.

The bridge serves this socket in-process with the Rust Relay Remote server (RR-491, `rust/relay-rs/src/remote/`).

| Rule | Case |
| --- | --- |
| `identify` answers a status probe and closes. | remote/test_identify_status_probe_answers_and_closes |
| `hello` is welcomed fresh; `identify` may come first; anything else first is `hello_required`; another protocol is refused. | remote/test_first_hello_is_welcomed_fresh, remote/test_identify_line_may_precede_hello, remote/test_first_frame_must_be_hello, remote/test_hello_with_another_protocol_is_refused |
| Invalid frames get their error code; an over-long line is refused and skipped; `ping` gets `pong`. | remote/test_invalid_frames_are_answered_with_their_error_code, remote/test_line_over_the_limit_is_refused_and_skipped, remote/test_ping_is_answered_with_the_pong_vector |
| An utterance is the newest command; a retry is not queued twice; a bridge token is refused. | remote/test_utterance_is_accepted_as_the_newest_command, remote/test_retried_utterance_is_not_queued_twice, remote/test_utterance_naming_a_bridge_token_is_refused |
| Controls act as their FIFO tokens. | remote/test_controls_act_as_their_fifo_tokens, remote/test_interrupt_control_publishes_an_interrupt_command |
| `hello` attaches the device as speech sink, or as mirror with remote mode off. | remote/test_hello_attaches_the_device_as_speech_sink, remote/test_remote_mode_off_moves_the_device_to_mirror, remote/test_hello_with_remote_mode_off_attaches_a_mirror |
| Speech reaches the device; acks reach speech; a reconnect replays what it missed. | remote/test_speech_for_a_sink_reaches_the_device_as_speech_frames, remote/test_ack_is_passed_to_speech, remote/test_reconnect_replays_the_speech_it_missed |

## Restart

| Rule | Case |
| --- | --- |
| Sequence numbers continue. | restart/test_sequence_numbers_continue_after_a_restart |
| A delivered, unclaimed intent is delivered again (`resume_exact`); queued ones in order. | restart/test_a_delivered_unclaimed_command_is_delivered_again, restart/test_queued_commands_are_delivered_again_in_order |
| A claimed, unacknowledged intent becomes `review_required` and blocks the queue; "Voice is paused…" is spoken. | restart/test_a_claimed_unacknowledged_command_becomes_a_recovery_blocker |
| A new recovery generation retires it (`stale_generation_retired`). | restart/test_a_new_recovery_generation_retires_the_old_unacknowledged_work |

## Continuity

The bridge writes a `continuity_recovery` answer only to a `reply_path` matching `/tmp/relay_recovery_recovery_<24 hex>.json` (restart/test_invalid_continuity_recovery_reports_failure_to_its_reply_path). `__CONTINUITY__` observations carry opaque ids `"<kind>-" + sha256("continuity-v1:<kind>:<value>")[:24]` (fifo/test_continuity_signals_are_reported_as_observations).

## Orchestrator endpoints

| Request | Case |
| --- | --- |
| `POST /v1/orchestrator-session/ensure`, `/heartbeat`, `/stop` | process/test_startup_registers_the_orchestrator_session_and_heartbeats_it, process/test_shutdown_request_stops_the_bridge_and_removes_its_files |
| `POST /v1/orchestrator-session/command` | commands/test_project_work_is_queued_on_the_ticket_path_and_fanned_out |
| `GET /v1/orchestrator-sessions`, `/v1/runs`, `/v1/program/status` | commands/test_project_work_is_queued_on_the_ticket_path_and_fanned_out |
| `GET /v1/messenger/outcomes`, `POST /v1/messenger/outcomes/<id>/delivered` | replies/test_daemon_outcomes_are_spoken_and_marked_delivered |
| `POST /v1/continuity/observation` | fifo/test_continuity_signals_are_reported_as_observations, replies/test_provider_turn_events_are_reported_as_continuity_observations, restart/test_provider_ready_for_the_exact_replacement_is_accepted |

## Preemption tests

Each test in `tests/test_voice_bridge_preemption.py` is listed below with the contract case that checks the same behaviour, or why it is not part of this contract. **Internal** means not observable at the bridge's process boundary, or owned by another component's contract. **Gap** means observable but not checked here.

Of the 148 tests, 42 are covered, 45 partly covered (the row names the part that is not), 49 internal and 12 gaps. Bridge cases are cited as `area/test_name`. Completion hook cases are cited as `hook <area>: <Class>.<test>` (`tests/contract/test_hook_contract_<area>.py`) and speech service cases as `speech <area>: <Class>.<test>` (`tests/contract/test_speech_contract_<area>.py`).

| Preemption test | Disposition | Contract case or reason |
| --- | --- | --- |
| `test_relay_submits_messenger_before_command_classification` | Internal | Ordering of two internal calls (messenger submit before `_resolve_voice_work_items`); black-box only sees that the messenger receives the turn (fifo/test_user_turn_starts_a_command_for_speech_messenger_and_mailbox), not that it preceded classification. |
| `test_explicitly_disabled_messenger_does_not_emit_degraded_prompt` | Covered | messenger/test_a_disabled_messenger_is_silent |
| `test_enabled_unavailable_messenger_queues_visible_audible_degraded_response_and_delivers_foreground` | Covered | messenger/test_a_missing_provider_command_speaks_the_degraded_acknowledgement (degraded text from `fallback`, command still delivered). The visible preview of queued speech is published by the speech service, not the bridge, in service mode (speech-service-protocol.md). |
| `test_completion_hook_requires_matching_foreground_owner_for_both_providers` | Internal | Completion hook (`relay_completion_hook.py`) behaviour: hook turns: TurnLifecycleContract.test_prompt_submit_without_foreground_ownership_is_ignored, TurnLifecycleContract.test_stop_without_foreground_ownership_leaves_the_turn_open. |
| `test_relay_startup_queues_greeting_once` | Covered | process/test_startup_greeting_is_spoken_once_without_a_command |
| `test_relay_startup_skips_greeting_when_tutorial_suppresses_it` | Covered | process/test_suppressed_greeting_also_skips_the_first_messenger_reply |
| `test_relay_readiness_waits_for_fifo_initialization` | Partly | process/test_readiness_is_recorded_in_the_support_journal covers readiness recorded after the FIFO opens. Not covered: no readiness record when FIFO initialization fails. |
| `test_bridge_readiness_preserves_provider_parity` | Covered | process/test_readiness_is_recorded_in_the_support_journal (both providers; asserts `provider` and `process: shell`). |
| `test_parse_args_recognizes_tutorial_startup_greeting_suppression` | Covered | process/test_suppressed_greeting_also_skips_the_first_messenger_reply (harness passes `--suppress-startup-greeting`; the effect is asserted, the parser itself is internal). |
| `test_tutorial_session_suppresses_only_first_fast_messenger_reply` | Covered | process/test_suppressed_greeting_also_skips_the_first_messenger_reply (first turn delivered without a messenger prompt; second reaches the messenger). |
| `test_voice_command_publication_does_not_arm_missing_final_fallback` | Covered | replies/test_a_claimed_command_without_a_finished_turn_gets_no_fallback |
| `test_dispatch_feedback_smoke_produces_one_action_and_one_spoken_outcome` | Partly | Pieces covered: raw JSON `__ORCHESTRATOR_REPLY__` object quarantined (fifo/test_unknown_and_malformed_controls_are_quarantined); completion text spoken once as final (replies/test_completion_with_text_is_spoken_as_the_completion_final). Not covered as one dispatch flow (one action, one final, no fallback). |
| `test_run_sidecar_bypasses_active_foreground_publication_path` | Partly | commands/test_a_read_only_task_beside_other_active_work_runs_as_a_sidecar covers `run_sidecar` and no mailbox command. Not asserted: PM update mode not started (no `/v1/runs`, `/v1/program/status` GETs) and the messenger `user_turn` carrying the sidecar disposition. |
| `test_newer_command_suppresses_stale_tts_after_first_claimed` | Covered | commands/test_tts_fifo_lines_are_spoken_unless_stale (plain TTS line dropped while a command waits in the mailbox). |
| `test_latest_command_wins_before_agent_claims_input` | Internal | Unit of the low-level `_write_cmd_file` overwrite; at the process boundary the inbox gates the mailbox and a newer turn waits instead (commands/test_a_newer_turn_waits_until_the_delivered_one_is_acknowledged). |
| `test_single_message_tts_still_queues_without_pending_command` | Covered | commands/test_tts_fifo_lines_are_spoken_unless_stale. The waiting preview of queued speech is published by the speech service (speech-service-protocol.md). |
| `test_tts_queue_publishes_waiting_preview_after_enqueue` | Internal | Ordering of enqueue vs. preview across two channels (speech socket vs. state datagram); needs timing between two internal calls. |
| `test_authoritative_playback_gate_and_preview_follow_accepted_intent` | Internal | In service mode the speech service arms waiting playback atomically with the `speak` it accepts and publishes the preview itself (`supports_atomic_waiting_playback`, `publishes_waiting_preview`); speech-service-protocol.md owns it. The bridge's part, offering the final with `waiting_playback_kind: final`, is replies/test_without_the_messenger_a_reply_goes_straight_to_speech. |
| `test_tts_queue_uses_authoritative_display_text_separate_from_spoken_text` | Partly | replies/test_a_replys_display_text_has_its_whitespace_collapsed checks that a final carries a separate, whitespace-collapsed `display_text`. A TTS-FIFO JSON line with its own `display_text` is not checked; the preview itself is the speech service's (speech-service-protocol.md). |
| `test_sequence_tagged_tts_drops_after_command_superseded` | Covered | commands/test_tts_fifo_lines_are_spoken_unless_stale (JSON line for the current command spoken; late one for a superseded command dropped). |
| `test_stale_authoritative_payload_does_not_publish_preview_or_queue_tts` | Covered | commands/test_tts_fifo_lines_are_spoken_unless_stale (a stale line is not offered to speech). With nothing offered the speech service publishes no preview (speech-service-protocol.md). |
| `test_messenger_tts_can_speak_while_orchestrator_command_is_pending` | Covered | messenger/test_user_turn_reaches_the_messenger_and_its_handoff_is_spoken (handoff spoken while the command waits unclaimed in the mailbox). |
| `test_new_session_voice_bypasses_stale_recovery_blocker` | Partly | restart/test_a_new_recovery_generation_retires_the_old_unacknowledged_work covers a delivered-unclaimed intent only. Not covered: a claimed-unacknowledged blocker from an older generation is cancelled, no `inbox_recovery_blocker`, the new turn delivered. |
| `test_voice_acknowledgement_replaces_stale_pending_command` | Partly | fifo/test_user_turn_starts_a_command_for_speech_messenger_and_mailbox checks the `acknowledgement` datagram's phase and command id. Not checked: `status_event.source == "pm"`, text not echoing the transcript, no `source_text` in the status command. Pending-file removal is a legacy no-inbox path. |
| `test_voice_acknowledgement_drops_after_command_superseded` | Internal | Needs a newer command to land between command start and acknowledgement emit (race); not reproducible black-box. |
| `test_acknowledgement_copy_synthesizes_intent_without_echoing_transcript` | Internal | Unit of the private helper `build_voice_acknowledgement`; the wording is a chosen copy, not a contract. |
| `test_acknowledgement_copy_uses_fast_generic_intent_response` | Internal | Unit of the private helper `build_voice_acknowledgement`; the wording is a chosen copy, not a contract. |
| `test_acknowledgement_copy_falls_back_for_sensitive_text` | Covered | classification/test_the_acknowledgement_never_repeats_a_secret |
| `test_voice_acknowledgement_defaults_to_immediate_delivery` | Internal | Asserts a module constant (`VOICE_ACKNOWLEDGEMENT_DELAY_SECONDS == 0`), not boundary behaviour. |
| `test_voice_acknowledgement_stays_notch_only_without_generic_planning_response` | Partly | Acknowledgement datagram covered by fifo/test_user_turn_starts_a_command_for_speech_messenger_and_mailbox; acknowledgement never spoken implied by messenger/test_a_disabled_messenger_is_silent. `source: pm` and message==text not asserted. |
| `test_persistent_orchestrator_heartbeat_uses_dynamic_update_state` | Partly | process/test_startup_registers_the_orchestrator_session_and_heartbeats_it checks heartbeats only in `idle`. Not covered: a later state (e.g. `awaiting_workers`) reaching the heartbeat. |
| `test_pm_update_mode_emits_safe_status_and_stops_when_superseded` | Partly | commands/test_project_work_is_queued_on_the_ticket_path_and_fanned_out checks PM update mode issues its GETs. Not asserted: the `working` datagram built from a run ("RR-7 run 51: ..."), no `source_text`, polling stops after supersession. |
| `test_raw_instruction_fanout_sends_same_private_command_metadata` | Covered | commands/test_project_work_is_queued_on_the_ticket_path_and_fanned_out (fan-out payload fields). The `context` scrubbing part is internal: no boundary input supplies a command `context`. |
| `test_raw_instruction_fanout_rejects_stale_command_before_post` | Internal | Needs a newer command between classification and the synchronous fan-out POST (race). |
| `test_orchestration_trace_emits_public_notch_payload` | Partly | replies/test_trace_for_the_current_command_reaches_the_overlay_and_the_messenger checks `working` kind/text. Not asserted: `ticket-created` "Created ticket RR-9", `trace_event.ticket_id`, `status_event.phase == "planning"`, no `source_text`. |
| `test_orchestration_trace_updates_notch_and_messenger_without_direct_tts` | Covered | replies/test_trace_for_the_current_command_reaches_the_overlay_and_the_messenger (working datagram, messenger `orchestrator_trace`, spoken as lifecycle progress). |
| `test_long_progress_keeps_compact_notch_and_complete_messenger_detail` | Covered | replies/test_long_progress_is_compact_on_the_overlay_and_whole_for_the_messenger |
| `test_orchestrator_reply_control_is_routed_to_messenger` | Covered | replies/test_reply_for_the_current_command_is_spoken_once_as_its_final, messenger/test_the_orchestrators_final_is_spoken_without_asking_the_messenger. The preview is the speech service's (speech-service-protocol.md). |
| `test_skip_uncertain_control_preserves_newest_command_identity` | Covered | restart/test_skip_uncertain_with_the_exact_blocker_releases_the_queue (mismatched/non-JSON skip changes nothing; state keeps the newest command's seq). |
| `test_turn_held_by_uncertain_message_says_voice_is_paused_until_skipped` | Partly | restart/test_a_claimed_unacknowledged_command_becomes_a_recovery_blocker, restart/test_skip_uncertain_with_the_exact_blocker_releases_the_queue cover hold, "Message N" notice, stale vs. exact skip, release. Not asserted: notice announced only once; direct-speech fallback when the messenger rejects the trace. |
| `test_session_spool_liveness_follows_the_app_owned_spool` | Internal | Unit of the private helper `_session_spool_is_live`; observable pruning is driven by `live_session_keys` (sessions/test_pruned_session_hands_its_undelivered_command_to_the_focused_session). |
| `test_option_play_control_uses_play_or_replay_boundary` | Covered | fifo/test_play_records_the_gesture_and_plays_or_replays |
| `test_timestamped_option_and_visual_ack_controls_preserve_timing` | Covered | fifo/test_play_records_the_gesture_and_plays_or_replays; fifo/test_play_ack_records_the_visual_acknowledgement |
| `test_first_play_during_authoritative_preview_waits_for_matching_final_intent` | Internal | In-process SpeechCoordinator armed-play state; speech service contract owns it: speech playback: WaitingPlaybackTests.test_armed_play_is_kept_for_the_commands_reply, WaitingPlaybackTests.test_waiting_playback_kind_arms_with_the_speak. Bridge side (final offered with `waiting_playback_kind: final`): replies/test_without_the_messenger_a_reply_goes_straight_to_speech. |
| `test_three_ordered_tool_turns_queue_every_final_in_arrival_order` | Internal | Cross-command queue order, no replacement and replay target are SpeechCoordinator behaviour: speech queue: QueueOrderTests.test_replies_play_in_the_order_they_were_accepted, SupersedeAndReplaceTests.test_newer_command_never_removes_a_reply; speech playback: ReplayTests.test_replay_speaks_the_newest_reply_as_a_new_utterance. Bridge piece (completion for the current command offered) is replies/test_completion_with_text_is_spoken_as_the_completion_final. |
| `test_continue_current_handoff_yields_first_play_and_replay_to_authoritative_final` | Internal | Which utterance first-play/replay picks is speech-service state: speech queue: SupersedeAndReplaceTests.test_reply_supersedes_its_commands_waiting_handoff; speech playback: ReplayTests.test_replay_speaks_the_newest_reply_as_a_new_utterance. Bridge offers covered by messenger/test_user_turn_reaches_the_messenger_and_its_handoff_is_spoken and replies/test_reply_for_the_current_command_is_spoken_once_as_its_final. |
| `test_suppressed_conversation_final_leaves_replay_target_intact` | Partly | messenger/test_a_final_that_repeats_the_messengers_answer_is_not_spoken_again covers suppression for identical text only. Not covered: near-duplicate suppression ("You're welcome!" vs "You're welcome."). |
| `test_raw_control_shaped_json_is_quarantined_without_payload_logging` | Covered | fifo/test_unknown_and_malformed_controls_are_quarantined (raw/nested/malformed control JSON starts nothing; smuggled text absent from stderr). Diagnostic field names are internal logging. |
| `test_unknown_prefixed_control_is_quarantined_but_token_prose_is_conversation` | Covered | fifo/test_unknown_and_malformed_controls_are_quarantined |
| `test_whitespace_separated_reserved_control_is_quarantined_without_payload_logging` | Partly | fifo/test_unknown_and_malformed_controls_are_quarantined drops `__PLAY__ now`. Not covered: `__TRACE__ {json}` specifically and its payload kept out of stderr. |
| `test_completion_hook_recovers_after_malformed_explicit_reply` | Covered | replies/test_malformed_and_unkeyed_replies_are_ignored (malformed reply dropped, later valid completion spoken once). |
| `test_current_orchestrator_reply_falls_back_when_messenger_rejects_it` | Partly | replies/test_without_the_messenger_a_reply_goes_straight_to_speech covers direct-to-speech with preview arming when the messenger is disabled. A running messenger refusing `submit_final` is an in-process return value the fake cannot produce. |
| `test_acknowledgement_does_not_publish_final_response_preview` | Covered | fifo/test_user_turn_starts_a_command_for_speech_messenger_and_mailbox checks the acknowledgement datagram; the bridge never publishes `message_waiting` itself in service mode, the speech service does for queued speech (speech-service-protocol.md). |
| `test_duplicate_orchestrator_reply_control_is_spoken_once` | Covered | replies/test_reply_for_the_current_command_is_spoken_once_as_its_final |
| `test_missing_foreground_reply_fallback_reports_current_claim_once` | Covered | replies/test_empty_completion_speaks_the_missing_reply_fallback |
| `test_missing_foreground_reply_fallback_skips_after_explicit_reply` | Partly | replies/test_a_reply_before_the_fallback_fires_cancels_it covers empty completion then reply. Not covered: reply first, then empty completion arms no fallback. |
| `test_late_provider_final_cancels_pending_missing_final_fallback` | Covered | replies/test_a_reply_before_the_fallback_fires_cancels_it |
| `test_missing_foreground_reply_fallback_waits_while_provider_turn_is_active` | Covered | replies/test_the_fallback_waits_while_the_provider_turn_is_active |
| `test_missing_foreground_reply_fallback_waits_for_pending_command_behind_active_turn` | Gap | Needed: the fallback's command still undelivered in `voice_cmd_ready` behind an older active turn; assert no fallback until the mailbox drains, then exactly one. |
| `test_multi_item_orphaned_sibling_cancels_missing_final_for_both_providers` | Gap | Needed: a two-item command where item 2's ledger record is `orphaned`/`source_superseded` by a manual turn; an empty completion for item 1 speaks no missing-reply fallback. (stderr `decision=` diagnostics are internal.) |
| `test_missing_final_waits_for_pending_sibling_then_warns_when_it_is_cancelled` | Gap | Needed: two-item command, item 1 empty, item 2 pending: no fallback while item 2 is pending, exactly one after item 2 is cancelled. |
| `test_manual_takeover_records_explicit_source_supersession_for_both_providers` | Internal | Completion hook ledger writing. Nearest: hook turns: TurnLifecycleContract.test_newer_command_supersedes_the_active_turn, TurnLifecycleContract.test_manual_terminal_submission_opens_and_closes_a_manual_turn (a manual submit superseding a Relay turn is not itself a hook case). |
| `test_duplicate_empty_sibling_completions_emit_one_source_warning` | Gap | Needed: a two-item command where both items finish empty; exactly one missing-reply fallback for the command (FallbackContract is single-item only). |
| `test_source_arbitration_ignores_other_embedded_provider_session` | Gap | Needed: ledger with this session's turn `empty` plus an `active` manual turn from another provider session; the fallback must still be spoken. |
| `test_sibling_takeover_terminalizes_only_the_replaced_intent` | Gap | Needed: two-item command, item 1 `orphaned`/`sibling_superseded` by item 2, item 2 `empty`; exactly one fallback. |
| `test_fully_cancelled_source_turn_never_emits_missing_final` | Partly | replies/test_no_fallback_once_the_command_is_superseded covers supersession by "stop everything". Not covered: empty completion for an intent in `cancelled_intent_ids` (item-scoped cancellation) speaks no fallback. |
| `test_completion_hook_binds_claude_pasted_prompt` | Internal | Completion hook: hook turns: ClaudeTurnLifecycle.test_pasted_prompt_envelope_matches_the_claim, ClaudeTurnLifecycle.test_incomplete_pasted_prompt_envelope_is_not_matched, CodexTurnLifecycle.test_pasted_prompt_envelope_is_not_matched_for_codex. |
| `test_completion_hook_binds_exact_claimed_prompt_without_storing_text` | Internal | Completion hook: hook turns: TurnLifecycleContract.test_prompt_submit_binds_the_claimed_relay_command, TurnLifecycleContract.test_manual_terminal_submission_opens_and_closes_a_manual_turn. |
| `test_unmatched_provider_continuation_preserves_exact_relay_turn` | Internal | Completion hook: hook turns: TurnLifecycleContract.test_prompt_submit_with_a_mismatched_prompt_is_not_bound, TurnLifecycleContract.test_stop_publishes_the_final_reply (the combination with an already-active Relay turn is not a hook case). |
| `test_manual_prompt_requires_exact_terminal_submit_boundary` | Internal | Completion hook: hook turns: TurnLifecycleContract.test_manual_terminal_submission_opens_and_closes_a_manual_turn, TurnLifecycleContract.test_manual_submission_without_valid_evidence_is_not_bound. |
| `test_manual_submit_evidence_rejects_stale_cross_session_and_ambiguous_boundaries` | Internal | Completion hook: hook turns: TurnLifecycleContract.test_manual_submission_without_valid_evidence_is_not_bound. |
| `test_completion_hook_tracks_manual_turn_boundaries_for_both_app_providers` | Internal | Completion hook: hook turns: TurnLifecycleContract.test_manual_terminal_submission_opens_and_closes_a_manual_turn. |
| `test_completion_hook_releases_startup_identity_before_stale_relay_stop` | Internal | Completion hook: hook turns: TurnLifecycleContract.test_newer_command_supersedes_the_active_turn, TurnLifecycleContract.test_stop_for_a_superseded_command_is_dropped_as_stale (startup-identity manual turn not itself a hook case). |
| `test_completion_hook_preserves_active_final_for_newer_continue_current_command` | Internal | Completion hook: hook turns: TurnLifecycleContract.test_stop_is_published_when_a_newer_command_preserves_current_work. Bridge side: replies/test_reply_preserved_by_a_newer_conversation_turn_is_spoken. |
| `test_completion_hook_rebinds_duplicate_relay_prompt_identity_for_both_providers` | Internal | Hook turn-ledger rebinding: hook turns: CodexTurnLifecycle.test_startup_identity_is_rebound_to_the_persisted_session (Codex only; no Claude hook case). |
| `test_completion_hook_reconciles_single_submit_stop_identity_drift` | Internal | Hook Stop identity reconciliation: hook turns: CodexTurnLifecycle.test_stop_from_a_changed_native_session_is_reconciled_by_turn_id, TurnLifecycleContract.test_second_stop_for_a_finished_turn_is_ignored (Claude variant not a hook case). |
| `test_completion_hook_reconciles_exact_manual_turn_identity_drift` | Internal | Hook manual-turn reconciliation. Nearest: hook turns: TurnLifecycleContract.test_manual_terminal_submission_opens_and_closes_a_manual_turn, CodexTurnLifecycle.test_stop_from_a_changed_native_session_is_reconciled_by_turn_id (manual + drift not a hook case). |
| `test_completion_hook_reconciles_claude_stop_failure_identity_drift` | Internal | Hook StopFailure path: hook turns: ClaudeTurnLifecycle.test_stop_failure_publishes_a_failed_completion_without_text (without drift; drift not a hook case). |
| `test_completion_hook_reconciled_stop_releases_stale_current_without_final` | Internal | Hook marks the reconciled Stop `stale`: hook turns: TurnLifecycleContract.test_stop_for_a_superseded_command_is_dropped_as_stale (without drift). |
| `test_completion_hook_rejects_ambiguous_identity_drift` | Internal | Hook refusal with two active records sharing a turn id; nearest hook case: hook turns: CodexTurnLifecycle.test_changed_native_session_without_a_provider_session_is_rejected. |
| `test_late_identity_drifted_stop_cannot_release_newer_manual_or_other_session` | Internal | Hook turn-ledger arbitration across a manual turn and another provider session; no hook contract case covers the combination. |
| `test_completion_hook_preserves_exact_manual_barrier_after_relay_turn` | Internal | Hook: hook turns: TurnLifecycleContract.test_manual_terminal_submission_opens_and_closes_a_manual_turn (without a preceding Relay turn). |
| `test_voice_bridge_provider_activity_is_scoped_to_embedded_session` | Partly | Unit of private `_provider_turn_state`/`_any_provider_turn_active`. Observable scoping: commands/test_a_read_only_task_beside_other_active_work_runs_as_a_sidecar, commands/test_a_busy_foreground_provider_is_steered_instead_of_a_sidecar. Not covered: a command's turn state ignoring another session's record (e.g. fallback not waiting on another session's active turn). |
| `test_completion_hook_separates_later_identical_manual_prompt_for_both_app_providers` | Internal | Hook binding/dedup: hook turns: TurnLifecycleContract.test_repeated_prompt_submit_for_one_turn_binds_once, TurnLifecycleContract.test_second_stop_for_a_finished_turn_is_ignored, TurnLifecycleContract.test_manual_terminal_submission_opens_and_closes_a_manual_turn. |
| `test_completion_hook_reads_provider_native_active_context_fields` | Internal | Hook transcript token parsing: hook compaction: ClaudeCompaction.test_context_is_input_plus_cache_tokens_of_the_newest_assistant_message, ClaudeCompaction.test_newer_compact_boundary_reports_its_post_compaction_tokens, CodexCompaction.test_context_is_the_last_token_usage_of_the_newest_token_count. |
| `test_compaction_diagnostics_are_bounded_and_distinguish_lifecycle` | Internal | Hook compaction diagnostics: hook compaction: CompactionContract.test_prompt_submit_and_stop_record_the_observed_context, CompactionContract.test_pre_compact_records_a_started_attempt, ClaudeCompaction.test_stop_failure_records_the_failed_turn. |
| `test_unconfirmed_compaction_remains_retryable_per_session` | Internal | Hook compaction attempt state: hook compaction: CompactionContract.test_post_compact_without_a_reduction_is_unconfirmed, CompactionContract.test_later_event_below_the_threshold_confirms_an_unconfirmed_compaction, CompactionContract.test_each_pre_compact_advances_the_attempt_of_its_session. |
| `test_completion_hook_rapid_turns_deliver_only_current_final` | Internal | Hook: hook turns: TurnLifecycleContract.test_newer_command_supersedes_the_active_turn (late Stop for the older turn publishes nothing). |
| `test_provider_hook_binds_recovered_and_middle_deliverable_intents` | Partly | restart/test_a_delivered_unclaimed_command_is_delivered_again, restart/test_queued_commands_are_delivered_again_in_order; commands/test_a_provider_turn_in_the_ledger_acknowledges_a_claim. Not covered: after restart, recovered and middle intents acked via ledger turns and three queued items draining in order. |
| `test_restart_restores_recovered_reply_currentness_and_monotonic_sequence` | Covered | restart/test_a_delivered_unclaimed_command_is_delivered_again, restart/test_a_reply_after_a_restart_is_still_spoken, restart/test_sequence_numbers_continue_after_a_restart |
| `test_explicit_restart_retires_only_unacknowledged_claim_and_drains_queue` | Gap | Needed: `continuity_provider_ready` with `discard_unacknowledged_claim: true` for a claimed-unacked intent makes the row `cancelled` (`user_restart_skipped_uncertain`) and delivers the queued item; an ordinary or stale-generation replacement leaves it `claimed`. |
| `test_retained_bridge_adopts_exact_app_owned_provider_replacement_and_drains_in_order` | Partly | restart/test_provider_ready_for_the_exact_replacement_is_accepted (observation only). Not covered: the bridge then adopts the new provider session (ledger turns/completions with new `provider_session_id`/gate ack claims and are spoken), three queued items drain in order, duplicate completion spoken once. |
| `test_provider_session_replacement_rejects_stale_foreign_and_ambiguous_evidence` | Partly | restart/test_provider_ready_for_a_mismatched_replacement_is_refused covers foreign session/app, stale generation, wrong claim, empty gate. Not covered: refusal for a cancelled or `all_work`-replaced claim; a new-session ledger record with a foreign gate not counting as acknowledgement. |
| `test_pump_releases_terminal_recovered_claim_without_waiting_for_old_reply` | Gap | Needed: restart where a claimed-unacked intent's provider turn is already `completed_final` in `provider_turns`; expect `acked` (not `review_required`), no `inbox_recovery_blocker`, next intent delivered. |
| `test_terminal_empty_predecessor_does_not_strand_next_intent` | Partly | commands/test_a_provider_turn_in_the_ledger_acknowledges_a_claim (with an `active` record). Not covered: a terminal `empty` predecessor turn releasing the next queued intent to the mailbox. |
| `test_manual_relay_bridge_claim_ack_advances_two_command_queue` | Partly | commands/test_a_manual_bridge_uses_the_legacy_mailbox_paths covers one command to `acked`. Not covered: two queued commands — second stays `pending` on claim, delivered to the legacy mailbox on ack, ack file removed, no turn ledger written. |
| `test_app_owned_stale_turn_drops_final_until_newer_claim_is_injected` | Internal | Calls the completion hook in-process: hook turns: TurnLifecycleContract.test_stop_for_a_superseded_command_is_dropped_as_stale, TurnLifecycleContract.test_newer_command_supersedes_the_active_turn. |
| `test_completion_hook_does_not_guess_unidentified_stop_with_multiple_active_turns` | Internal | Completion hook behaviour; nearest hook cases TurnLifecycleContract.test_stop_with_an_unknown_turn_id_is_rejected, TurnLifecycleContract.test_stop_with_a_rotated_prompt_id_completes_the_sole_active_turn (multi-active no-id Stop is a hook-contract gap). |
| `test_completion_hook_drops_only_cancelled_item_from_shared_source_turn` | Internal | Completion hook: hook turns: TurnLifecycleContract.test_stop_for_a_cancelled_intent_is_dropped_as_stale (surviving sibling publish not a hook case). |
| `test_completion_hook_stop_delivers_only_correlated_provider_final` | Internal | Completion hook payload/ledger: hook turns: TurnLifecycleContract.test_stop_publishes_the_final_reply. |
| `test_completion_hook_empty_stop_delivers_bounded_warning_signal` | Internal | Completion hook: hook turns: TurnLifecycleContract.test_stop_without_final_text_reports_an_empty_completion. |
| `test_provider_completion_control_deduplicates_after_explicit_reply` | Covered | replies/test_reply_then_completion_for_one_command_is_spoken_once |
| `test_provider_completion_control_rejects_superseded_command` | Covered | replies/test_reply_for_a_superseded_command_is_dropped (reply and completion after "stop everything", neither spoken). |
| `test_provider_completion_control_preserves_reply_for_newer_continue_current` | Partly | replies/test_reply_preserved_by_a_newer_conversation_turn_is_spoken uses the reply helper only. Not covered: a `__RELAY_COMPLETION__` for a preserved older command spoken with source `completion`. |
| `test_preserved_completion_falls_back_to_tts_after_messenger_advances` | Partly | Messenger-rejection routing is internal; the observable outcome (preserved command's completion still spoken after a newer turn) is covered only for the reply helper (replies/test_reply_preserved_by_a_newer_conversation_turn_is_spoken). |
| `test_preserved_completion_stays_fresh_in_speech_coordinator` | Partly | replies/test_reply_preserved_by_a_newer_conversation_turn_is_spoken. Not asserted: `speak` carries the older command's seq and `work_disposition.intent_id`; the completion path is not exercised. |
| `test_provider_completion_control_routes_empty_completion_to_warning` | Covered | replies/test_project_work_fallback_says_worker_updates_still_come, replies/test_empty_completion_speaks_the_missing_reply_fallback |
| `test_durable_broker_deduplicates_authoritative_effect_after_bridge_restart` | Gap | Needed: a reply spoken before a restart and resent after is not spoken twice (one `delivered` `provider_turn_effects` row), and a `provider_terminated`/`app_teardown` turn event moves the `provider_turns` row to `terminated`. |
| `test_interrupted_claude_turns_cancel_once_per_interrupt_in_one_session` | Gap | Needed: `__PROVIDER_TURN_EVENT__` `provider_turn_cancelled` (reason `provider_interrupted`, non-empty `event_id`) cancels the broker turn once per event id, is refused without event id / other reason, and a later reply for that turn is dropped. |
| `test_real_delivery_paths_reject_revocation_between_reserve_and_submission` | Internal | Needs a fault injected between `_reserve_foreground_reply_delivery` and submission (race). |
| `test_real_delivery_paths_reject_revocation_before_reservation` | Partly | replies/test_reply_for_a_cancelled_intent_is_dropped, replies/test_reply_for_a_superseded_command_is_dropped; replies/test_no_fallback_once_the_command_is_superseded. Not covered: no fallback after a scoped item cancellation; no `provider_turn_effects` rows. |
| `test_provider_completion_control_arms_missing_final_after_terminal_event` | Covered | replies/test_empty_completion_speaks_the_missing_reply_fallback, replies/test_a_reply_before_the_fallback_fires_cancels_it (delayed, cancellable fallback). |
| `test_provider_completion_recovery_fallback_publishes_waiting_preview` | Covered | replies/test_without_the_messenger_a_reply_goes_straight_to_speech and replies/test_a_replys_display_text_has_its_whitespace_collapsed: the final goes straight to speech with its `display_text`. The `message_waiting` datagram is then the speech service's (speech-service-protocol.md). |
| `test_pending_messenger_outcome_poll_delivers_and_acks_trace` | Covered | replies/test_daemon_outcomes_are_spoken_and_marked_delivered |
| `test_pending_messenger_outcome_preserves_full_lifecycle_detail` | Covered | replies/test_an_outcomes_whole_lifecycle_detail_reaches_the_messenger |
| `test_pending_messenger_outcome_poll_batches_recovered_backlog` | Partly | replies/test_several_outcomes_at_once_are_summarised_in_one_update, replies/test_daemon_outcomes_are_spoken_and_marked_delivered (`limit=50`). Not checked: summary kind `run-health-warning`, "N tickets" count, `ticket_ids`. |
| `test_pending_messenger_outcome_rejection_is_not_marked_delivered` | Gap | Needed: when the messenger cannot accept an outcome trace, the bridge posts `/v1/messenger/outcomes/<id>/attempt` and never `/delivered`. |
| `test_orchestration_trace_drops_after_command_superseded` | Covered | replies/test_trace_for_a_superseded_command_is_dropped |
| `test_build_bundle_includes_runtime_service_dependencies` | Internal | Build bundle layout (`scripts/build-dmg.sh`), not bridge runtime. |
| `test_build_bundle_includes_swiftterm_metal_resources` | Internal | Build bundle layout, not bridge runtime. |
| `test_tts_dismissal_does_not_supersede_claimed_command` | Partly | fifo/test_cancel_dismisses_speech_without_starting_a_command covers `skip`/`user_stop` and unchanged seq for an unclaimed command. Not covered: after a claim, the mailbox is not re-created and the state file is unchanged. |
| `test_acknowledgement_does_not_revoke_dispatch_authorization` | Partly | commands/test_authorizations_follow_the_turns_relationship (ticket grant; question registers none). Not covered: an "okay" after a dispatch leaves the dispatch grant `active`, relationship `conversation`. |
| `test_negated_stop_status_composes_as_additive_for_codex_and_claude` | Covered | classification/test_a_negated_stop_asking_for_status_preserves_the_current_work (without other active work; the turn's disposition does not depend on it here). |
| `test_busy_pm_receives_even_explicit_sidecar_voice_requests` | Covered | commands/test_a_read_only_task_beside_other_active_work_runs_as_a_sidecar, commands/test_a_busy_foreground_provider_is_steered_instead_of_a_sidecar |
| `test_demo_self_explanation_is_provider_neutral_conversation` | Covered | classification/test_a_demo_explanation_is_conversation |
| `test_information_query_voice_metadata_never_authorizes_project_mutation` | Partly | commands/test_conversation_is_not_fanned_out_to_the_daemon, commands/test_authorizations_follow_the_turns_relationship (one generic question). Not covered: RR-id status/inspect phrasings (`inspect_ticket`, relationship `inspection`, `requires_ticket: false`), `.orchestrator/` `next_id` unchanged. |
| `test_explicit_mutation_voice_metadata_retains_authority_for_both_providers` | Partly | commands/test_project_work_is_queued_on_the_ticket_path_and_fanned_out, commands/test_authorizations_follow_the_turns_relationship (one `create_ticket` phrasing). Not covered: `update_ticket`/`dispatch_ticket` phrasings ("Fix RR-325", "Have the worker fix RR-325"). |
| `test_mixed_query_and_mutation_stays_one_non_mutating_clarification` | Partly | classification/test_a_question_followed_by_a_change_asks_one_clarification checks one of the eight phrasings; the rest are classifier inputs for `command_actions.py`'s own tests. |
| `test_ordered_mutation_clauses_without_a_query_retain_authority` | Partly | commands/test_a_turn_with_two_requests_becomes_two_ordered_items (split into two ordered items). Not covered: "Fix RR-325, then dispatch RR-325" → `update_ticket` then `dispatch_ticket`, both `queue_project_work` with grants and fan-out. |
| `test_real_same_turn_work_resolves_to_two_provider_neutral_deliveries` | Partly | commands/test_a_turn_with_two_requests_becomes_two_ordered_items (split text, orders 1/2, same seq, both providers). Not asserted: each item's action kind (`create_ticket`). |
| `test_partial_leased_cancellation_requeues_survivor_for_codex_and_claude` | Partly | commands/test_a_scoped_cancellation_cancels_only_the_queued_item_it_names (pending item of another command). Not covered: cancelling the delivered-unclaimed item 1 of a two-item turn delivers item 2 in its place, `preempt_provider: false`. |
| `test_replacement_language_revokes_only_resolved_item_for_both_providers` | Gap | Needed: with two active ticket items, "Replace that with export" is item-scoped to the newest item (`target_intent_ids`, `provider_preempt_intent_ids`) and revokes only that item's grant. |
| `test_redirect_revokes_dispatch_authorization` | Partly | commands/test_authorizations_follow_the_turns_relationship (`redirect` revocation by "stop everything"). Not covered: "actually dispatch RR-8 instead" revokes the earlier dispatch grant, holds its own active grant, state shows `authorization_relationship: redirect`. |
| `test_published_command_records_exact_agent_prompt_for_voice_origin` | Partly | fifo/test_user_turn_starts_a_command_for_speech_messenger_and_mailbox, commands/test_mailbox_holds_the_agent_prompt_and_its_metadata (`.meta` `agent_prompt` == prompt). State file `agent_prompt` not asserted. |
| `test_explicit_interrupt_still_supersedes_claimed_command` | Partly | fifo/test_interrupt_stops_speech_and_publishes_an_interrupt_command (no prior command). Not covered: interrupt after a claimed command takes seq+1 and interrupts the messenger. |
| `test_explicit_replace_releases_cancelled_inbox_transport_lease` | Partly | commands/test_cancelling_everything_cancels_all_queued_work_and_preempts (pending queued intent cancelled). Not covered: the delivered-unclaimed intent cancelled, mailbox overwritten by the replacement, `deliverable_commands` lists only it. |
| `test_app_owned_sidecar_uses_lane_without_foreground_mailbox_deferral` | Partly | commands/test_a_read_only_task_beside_other_active_work_runs_as_a_sidecar (no mailbox, lane launch, spoken result). Not covered: inbox row `run_sidecar` `pending→claimed→acked`; `sidecar-started`/`sidecar-completed` messenger traces. |
| `test_sidecar_final_uses_work_valid_lifecycle_speech_after_newer_turn` | Partly | commands/test_a_read_only_task_beside_other_active_work_runs_as_a_sidecar (authoritative lifecycle final). Not covered: still spoken after a newer turn, `freshness_scope: work`, sidecar command's seq/id. |
| `test_sidecar_outcome_crosses_messenger_and_coordinator_for_both_providers` | Partly | commands/test_a_read_only_task_beside_other_active_work_runs_as_a_sidecar (text, source, kind, authoritative, command id). `freshness_scope: work` and `realization_decision: full` not asserted. |
| `test_barge_in_holds_pending_coordinated_speech_until_the_next_turn` | Internal | SpeechCoordinator queue hold; speech service contract owns it: speech playback: BargeInTests.test_stop_with_nothing_playing_holds_the_queue, NewTurnTests.test_new_turn_releases_a_held_queue. Bridge part: fifo/test_tts_stop_stops_playback_as_a_barge_in. |
| `test_newer_pending_project_work_does_not_create_visible_tickets` | Partly | commands/test_project_work_is_queued_on_the_ticket_path_and_fanned_out (no `.orchestrator/` created, but no board exists). Not covered: with an existing board two ticket turns leave `next_id` and files unchanged; prompt `ticket_id: null` + "Create or refine a visible ticket now"; no `ticket_id` in `.meta`. |
| `test_project_work_is_durably_queued_for_foreground_pm` | Partly | commands/test_project_work_is_queued_on_the_ticket_path_and_fanned_out, commands/test_conversation_is_not_fanned_out_to_the_daemon. Not covered: a direct action ("open Chrome") is `direct_action` and not fanned out. |
| `test_private_command_event_log_is_bounded` | Partly | commands/test_private_command_log_keeps_only_the_newest_events, commands/test_private_command_log_records_each_intents_states (file 0600). Log directory mode 0700 not asserted. |
| `test_private_command_event_log_serializes_concurrent_captures` | Internal | Eight concurrent in-process writer threads (race); the bridge's single FIFO reader cannot reproduce it black-box. |
| `test_delivery_failed_recovery_names_the_actual_outcome` | Covered | process/test_a_command_whose_delivery_failed_is_reported_at_startup |
| `test_generated_provider_skills_share_preemption_contract` | Internal | Generated provider skills text (`scripts/relay-bridge`), not bridge runtime. |
| `test_generated_provider_skills_preserve_bridge_context_after_response` | Internal | Generated provider skills text (`scripts/relay-bridge`), not bridge runtime. |
| `test_build_bundle_includes_provider_completion_hook_service` | Internal | Build bundle layout (`scripts/build-dmg.sh`), not bridge runtime. |

### Gaps

These are observable at the bridge's boundary and not yet checked here. Most need multi-item turn ledgers or a restart with a recorded provider effect, and the sandbox can already set both up:

- `test_missing_foreground_reply_fallback_waits_for_pending_command_behind_active_turn`: Needed: the fallback's command still undelivered in `voice_cmd_ready` behind an older active turn; assert no fallback until the mailbox drains, then exactly one.
- `test_multi_item_orphaned_sibling_cancels_missing_final_for_both_providers`: Needed: a two-item command where item 2's ledger record is `orphaned`/`source_superseded` by a manual turn; an empty completion for item 1 speaks no missing-reply fallback. (stderr `decision=` diagnostics are internal.)
- `test_missing_final_waits_for_pending_sibling_then_warns_when_it_is_cancelled`: Needed: two-item command, item 1 empty, item 2 pending: no fallback while item 2 is pending, exactly one after item 2 is cancelled.
- `test_duplicate_empty_sibling_completions_emit_one_source_warning`: Needed: a two-item command where both items finish empty; exactly one missing-reply fallback for the command (FallbackContract is single-item only).
- `test_source_arbitration_ignores_other_embedded_provider_session`: Needed: ledger with this session's turn `empty` plus an `active` manual turn from another provider session; the fallback must still be spoken.
- `test_sibling_takeover_terminalizes_only_the_replaced_intent`: Needed: two-item command, item 1 `orphaned`/`sibling_superseded` by item 2, item 2 `empty`; exactly one fallback.
- `test_explicit_restart_retires_only_unacknowledged_claim_and_drains_queue`: Needed: `continuity_provider_ready` with `discard_unacknowledged_claim: true` for a claimed-unacked intent makes the row `cancelled` (`user_restart_skipped_uncertain`) and delivers the queued item; an ordinary or stale-generation replacement leaves it `claimed`.
- `test_pump_releases_terminal_recovered_claim_without_waiting_for_old_reply`: Needed: restart where a claimed-unacked intent's provider turn is already `completed_final` in `provider_turns`; expect `acked` (not `review_required`), no `inbox_recovery_blocker`, next intent delivered.
- `test_durable_broker_deduplicates_authoritative_effect_after_bridge_restart`: Needed: a reply spoken before a restart and resent after is not spoken twice (one `delivered` `provider_turn_effects` row), and a `provider_terminated`/`app_teardown` turn event moves the `provider_turns` row to `terminated`.
- `test_interrupted_claude_turns_cancel_once_per_interrupt_in_one_session`: Needed: `__PROVIDER_TURN_EVENT__` `provider_turn_cancelled` (reason `provider_interrupted`, non-empty `event_id`) cancels the broker turn once per event id, is refused without event id / other reason, and a later reply for that turn is dropped.
- `test_pending_messenger_outcome_rejection_is_not_marked_delivered`: Needed: when the messenger cannot accept an outcome trace, the bridge posts `/v1/messenger/outcomes/<id>/attempt` and never `/delivered`.
- `test_replacement_language_revokes_only_resolved_item_for_both_providers`: Needed: with two active ticket items, "Replace that with export" is item-scoped to the newest item (`target_intent_ids`, `provider_preempt_intent_ids`) and revokes only that item's grant.

## Not covered

- **`RELAY_SPEECH_SERVICE_MODE=legacy`**: the one-release rollback that runs speech inside the bridge. It needs a voice model and audio device, so a sandbox cannot run it.
- **`VOICE_ACKNOWLEDGEMENT`**: one of several acknowledgement texts picked by a seed from the transcript, so no case can predict which is shown.
- **`FOREGROUND_REPLY_HARD_CEILING_SECONDS`** (900 s) and **`FOREGROUND_REPLY_TRACE_ACTIVE_SECONDS`** (60 s): fallback limits only reached after a minute or more of activity.
- **Config and credential locations** (`XDG_CONFIG_HOME`, `CLAUDE_CONFIG_DIR`, `ANTHROPIC_*`, `RELAY_CODEX_MODEL_LIST_JSON`, `RELAY_CORRELATION_ID`): read by imported modules with their own tests; the suite passes `--config` and controls `HOME`.
- **`SIGTERM`** cleanup and legacy non-`--relay` direct mode.
- **The fixed continuity reply path** under `/tmp`, which `RELAY_BRIDGE_RUNTIME_DIR` does not move.

## The stub check

Acceptance requires that the suite fails against a bridge that ignores its input. With

```bash
RELAY_BRIDGE_CONTRACT_WAIT_SECONDS=2 \
RELAY_VOICE_BRIDGE_CMD="python3 -c 'import time; time.sleep(3600)'" \
  python3 -m unittest discover -s tests/contract -p 'test_bridge_contract*.py'
```

a process that never reads its FIFO or creates its sockets, every one of the 287 cases fails (`FAILED (failures=287)`, each a timeout waiting for the bridge to come up), and the harness kills every stub it started. The shorter wait only makes the check quicker; it does not change what fails.
