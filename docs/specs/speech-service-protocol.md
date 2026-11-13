# Speech service protocol

**Status:** Implemented (RR-480)

In a Relay session, speech runs in its own process. `services/speech_service.py` hosts `SpeechCoordinator`, `TTSWorker` and `SpeechPlayer`; the voice bridge starts it, supervises it and talks to it through `services/speech_client.py`. This document describes the protocol between the two and the files and sockets the service owns, as checked by the black-box suite in `tests/contract/`. The suite starts the service as an opaque command and imports nothing from `services/`, so a replacement written in another language is accepted against the same cases.

The process split does not change what is spoken or when. The queueing, replacement, barge-in and replay rules below are the rules `SpeechCoordinator` already applied inside the bridge.

## Running the suite

```bash
python3 -m unittest discover -s tests/contract -p 'test_speech_contract*.py'
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `RELAY_SPEECH_SERVICE_CMD` | `<python> services/speech_service.py` | The service under test. Split like a shell command line; `--socket <path> --config <path>` are appended. The bridge reads the same variable. |
| `RELAY_SPEECH_CONTRACT_WAIT_SECONDS` | `10` | How long a case waits for something the service should do promptly. |

The suite needs macOS (`/usr/bin/afconvert` for Relay Remote audio) and Python 3.10 or newer. Each case starts its own service in test mode inside a temporary folder and passes only the variables listed under [Environment](#environment), so it never touches the sockets, files or audio device of a running Relay Runner session.

## Process

```
speech_service --socket <path> [--config <path>]
```

- `--socket` is the Unix stream socket the service listens on. It defaults to `RELAY_SPEECH_SERVICE_SOCK`, then `/tmp/relay_speech_service.sock`. The service removes a leftover file at that path, creates the socket readable and writable by its owner only, and listens before it loads the voice, so a client can connect at once and wait for the answer to `hello`.
- `--config` is the `config.toml` to read. The service uses `[tts]` `voice`, `rate`, `chime` and `auto_play`, with the defaults of `services/config.py`.
- The service accepts **one** connection for its whole life. After accepting it, the service closes the listening socket and removes its path. The client refuses a socket whose other end belongs to another user.
- The service exits with status 0 after a `shutdown` request, when its client's connection ends, when its parent process exits, and on `SIGTERM` or `SIGINT`. In each case it first stops speech and releases its sockets. It exits with status 1 when it cannot listen on the socket path.
- stderr carries free-form diagnostics. stdout is unused.

### Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `VOICE_COMMAND_STATE_FILE` | `/tmp/voice_command_state.json` | The newest Relay command, written by the bridge (input). See [Freshness](#freshness). |
| `SPEECH_EVENT_LOG` | `/tmp/relay_speech_events.jsonl` | The speech event log (output). |
| `TTS_CONTROL_SOCK` | `/tmp/tts_control.sock` | The datagram socket for play controls (bound by the service). |
| `VOICE_STATE_SOCK` | `/tmp/voice_state.sock` | The overlay's datagram socket that state updates are sent to. |
| `VOICE_MODELS_DIR` | unset | A folder whose `kokoro/` holds the voice model, searched before `~/.local/share/kokoro`. |
| `HOME` | | Locates `~/Library/Application Support/relay-runner/voice-audio.lock` and the default `config.toml`. |
| `RELAY_SPEECH_TEST_MODE` | unset | `1` selects the [test mode](#test-mode). |
| `RELAY_SPEECH_TEST_PLAYBACK_LOG` | unset | Test mode only: the playback log (output). |
| `RELAY_SPEECH_TEST_MS_PER_CHAR` | `20` | Test mode only: milliseconds of silence rendered per character. |

The bridge starts the service with its own environment plus the first three variables set to the paths it resolved for the session.

## Transport

Both sides send UTF-8 JSON objects, one per line, each ended by `\n`. A line is at most 1 MiB. There are five kinds of message:

| Kind | Direction | Shape |
| --- | --- | --- |
| Request | client to service | `{"id": <number or string>, "op": "<name>", ...}` |
| Response | service to client | `{"id": <same>, "ok": true, "result": {...}}` or `{"id": <same>, "ok": false, "error": {"code": "...", "message": "..."}}` |
| Event | service to client | `{"event": "<name>", ...}` |
| Call | service to client | `{"call": <number>, "op": "<name>", ...}` |
| Reply | client to service | `{"reply": <same>, "ok": true, "result": {...}}` or `{"reply": <same>, "ok": false, ...}` |

Unknown fields are ignored. Error messages never contain reply text.

Error codes: `hello_required`, `unsupported_protocol`, `unknown_op`, `invalid_request` (a required field is missing or has the wrong type), `internal_error`. A line that is not a JSON object, or is neither a request nor a reply, produces an `error` event with code `invalid_message`; a line over the limit is skipped and produces `line_too_long`. Neither ends the connection. A reply that matches no call is ignored.

## Ordering

1. Requests are applied one at a time, in the order received. Each request gets exactly one response, and responses are sent in request order.
2. A `state` event for a change a request made is sent **before** that request's response. The first `state` event is sent before the response to `hello`.
3. `state` events are snapshots sent only when the snapshot changed, in the order the snapshots were taken. A change made by no request, such as a datagram on the control socket, is reported within a fraction of a second.
4. `playback` events of one utterance arrive in lifecycle order (see [Events](#events)). `playback` events of different utterances arrive in the order they happened.
5. While the service waits for the reply to a call it still reads the connection, and it sends nothing that depends on the reply. A call is made from inside the request or playback step that needs it, so the client must answer calls without waiting for any response.

## Requests

Every request except `hello` fails with `hello_required` until `hello` succeeded. A result is `{}` unless listed.

### Session

| `op` | Fields | Result | Effect |
| --- | --- | --- | --- |
| `hello` | `protocol` (must be `1`), optional `client`, `pid` | `protocol`, `service`, `instance_id`, `pid`, `test_mode` | Opens the session once the voice is loaded. `instance_id` is new for every service process. |
| `status` | | The `state` snapshot | Reads the queue. |
| `reload_config` | | | Re-reads `config.toml`. A changed voice or rate stops the current playback; the reply returns to the head of the queue. |
| `shutdown` | | | Stops speech, answers, then exits 0. |

### Speaking

| `op` | Fields | Result | Effect |
| --- | --- | --- | --- |
| `speak` | `text`, plus the intent fields below | `accepted`, `utterance_id` | Proposes one speech intent. See [Queue rules](#queue-rules). |
| `read_out` | `text`, optional `session_key` | `accepted` | Speaks explicit text now, such as a stored reply: queues it as a replayable reply and plays it. Empty text is refused. |
| `arm_waiting_playback` | `command_seq`, `command_id`, optional `kind` (`final`) | | Binds the next play gesture to the speech of this command. `speak` with `waiting_playback_kind` does the same atomically. |

Intent fields of `speak`. Only `text` is required; `null` and absent mean the default.

| Field | Default | Meaning |
| --- | --- | --- |
| `text` | | What is synthesised. Empty text is refused. |
| `display_text` | `text` | What the overlay shows. |
| `command_seq`, `command_id` | none | The Relay command this speech belongs to. |
| `source` | `fallback` | `messenger`, `orchestrator`, `lifecycle`, `completion` or `fallback`. |
| `kind` | `fallback` | `handoff`, `progress`, `clarification`, `final`, `fallback` or `control`. `clarification`, `final` and `fallback` are **replies**; the others are **status speech**. |
| `authoritative` | `false` | The provider's own outcome, not a stand-in. |
| `priority` | by `kind` | Only compared between speech of the same command. The default is `control` 100, `clarification` 80, `final` 70, `fallback` 60, `handoff` 20, `progress` 10, plus 5 when `authoritative`. |
| `dedup_key` | derived | Speech with a key already accepted is refused. A `final` or `fallback` of a command defaults to one key per command, so a command has one real final and one fallback. |
| `utterance_id` | a new UUID | The identity used in events and state datagrams. |
| `expires_at` | none | Unix time after which the intent is no longer spoken. |
| `freshness_scope` | `conversation` | `work` exempts a `lifecycle` `final` from command freshness. |
| `work_disposition` | none | Carries `intent_id` for the preserved-command rule. |
| `replayable` | `kind == "final"` | Whether `replay` may repeat it. |
| `lifecycle_role` | by `kind` | `acknowledgement`, `progress`, `result`, `failure`, `blocker`, `decision`, `conversation` or `control`. Recorded in the event log and returned by `played_coverage`. |
| `covered_facts` | the `semantic_brief`, else `text` | List of strings returned by `played_coverage`. |
| `realization_decision`, `suppression_reason` | `full`, `""` | `full`, `delta` or `suppress`, and why. Recorded in the event log. |
| `semantic_brief` | `display_text` | A short description used for `covered_facts` and the derived `dedup_key`. |
| `session_key` | `""` | The app session the speech belongs to. |
| `waiting_playback_kind` | none | See `arm_waiting_playback`. |

A value outside a field's list is treated as that field's default.

### Playback control

| `op` | Fields | Result | Effect |
| --- | --- | --- | --- |
| `play` | | | Plays the reply waiting at the head of the queue, releases a held queue, and brings the next queued reply forward to play when nothing is waiting. Does nothing while audio is playing or when the queue is empty. |
| `play_or_replay` | | `handled` | `play` when a reply is waiting or queued, otherwise `replay`. |
| `replay` | | `accepted` | Speaks the newest replayable reply again as a new utterance whose `replay_of` names the original. `false` when there is none. The request also acts as `play`: with nothing at the head the replay plays at once; with a reply waiting at the head, that reply plays and the replay is next, ahead of everything else queued. |
| `pause` | | | Speech-only barge-in: stops the audio and **holds** the queue. The reply that was playing returns to the head of the queue and plays from its start on the next `play`. |
| `stop_playback` | optional `reason` (`user_stop`) | | Stops the reply that is playing. With `recording_barge_in` the reply counts as heard: it leaves the queue, stays replayable, and nothing else comes forward until `new_turn` or `play`. With any other reason the reply returns to the head of the queue and the queue is held. With nothing playing it acts as `pause`. |
| `skip` | optional `reason` (`user_stop`) | | Removes the reply that is playing, or else the one waiting at the head; it stays replayable. The next queued reply comes forward, except with `focus_switch`, `wheel_stop` or `recording_barge_in`, which bring nothing forward. The bridge sends `focus_switch` when the user changes session. |
| `new_turn` | `command_seq`, `command_id` | | A new user turn: releases a held queue, stops a playing reply of an older command (it returns to the head of the queue), and drops queued status speech of older commands. Queued replies stay. |

### Sessions

| `op` | Fields | Result | Effect |
| --- | --- | --- | --- |
| `session_playback_states` | optional `waiting_session_key` | `states`: session key to `play`, `stop` or `replay` | What each session's control would do now. |
| `control_session` | `session_key`, `action` (`play`, `stop` or `replay`), optional `waiting_session_key` | `handled` | Acts for one session only. `stop` stops its playing reply with the reason `wheel_stop`: the reply returns to the head and the queue is held. `play` plays its reply waiting at the head, or brings its queued reply forward and plays it; a reply that was waiting at the head is `cancelled`, keeps its `utterance_id`, and is `queued` again when it returns to the head. `replay` replays its newest reply. `false` when the action does not apply to that session, including `play` while another session's reply is playing. |

`waiting_session_key` names the session whose reply the client announced with `arm_waiting_playback` and has not proposed yet. While that play is armed, the session reports `play`, and a `control_session` `play` for it is kept for the reply.

### Diagnostics

| `op` | Fields | Result | Effect |
| --- | --- | --- | --- |
| `played_coverage` | `command_seq`, `command_id` | `coverage`: list of `utterance_id`, `lifecycle_role`, `covered_facts`, `spoken_text` | What finished playing for a command, newest last, at most 8. |
| `note_play_control` | optional `option_detected_at`, `fifo_received_at` | | Records play-gesture timing in the event log. |
| `note_visual_acknowledgement` | `option_detected_at`, `acknowledged_at` | | Same, for the overlay's acknowledgement. |
| `record_realization` | `command_seq`, `command_id`, `lifecycle_role`, `decision`, `reason` | | Writes a `realization` record. |
| `record_messenger_stage` | `stage`, `command_seq`, `command_id`, optional `at`, `provider`, `outcome` | | Writes a messenger timing record named after `stage`: `user_turn_received`, `messenger_submitted`, `messenger_provider_started`, `messenger_first_semantic_output`, `messenger_failed` or `messenger_unavailable`. Another `stage` is ignored. `provider` is recorded when it is `codex` or `claude`. |
| `record_missing_outcome` | `command_seq`, `command_id`, `reason`, optional `signals` | `recorded` | Writes one `missing_outcome` record per command; `false` when the command has an accepted reply or was already recorded. |

### Relay Remote

A Relay Remote device session lives in the client. The client tells the service which devices exist; the service reaches them through calls.

| `op` | Fields | Result | Effect |
| --- | --- | --- | --- |
| `remote_attach` | `device_id`, `role` (`sink` or `mirror`, default `sink`) | | `sink`: the device becomes the speech output instead of the Mac's speaker. `mirror`: the Mac keeps speaking and the device is sent the text of each reply. Attaching a device as `sink` ends its `mirror` role. |
| `remote_detach` | `device_id`, `role`, optional `reason` | | Ends the role. Replies a sink had not acknowledged return to the Mac queue. |
| `remote_ack` | `device_id`, `seq`, `played` | `known` | The device acknowledged the frame `seq`. `played: true` counts the reply as heard. |

Calls the service makes. Each names `device_id` and `role`.

| `op` | Fields | Reply result | Meaning |
| --- | --- | --- | --- |
| `remote_routable` | | `routable` | Whether the device can take speech now. A sink that is not routable is detached. |
| `remote_speech` | `kind`, `source`, `text`, `relay_command_seq`, and `audio` (sink) or `spoken_by: "mac"` (mirror) | `seq` | Send one `speech` frame; `seq` is the number the device session gave it. A failed reply means the frame was not sent, and `speak` answers `accepted: false`. |
| `remote_speech_control` | `action` (`stop` or `skip`), `reason` | `seq` | Send one `speech_control` frame. |
| `remote_speech_audio` | `seq`, `part`, `parts`, `last`, `data`, `format`, `sample_rate` | | Send one audio part of the `speech` frame `seq`. |

**Remote synthesis.** While a sink is attached and routable, an accepted `speak` is not queued for the Mac's speaker. The service calls `remote_speech`, with `audio: true` when it can voice the reply itself. It then renders the reply sentence by sentence without opening an audio device, encodes each sentence as AAC-LC in ADTS framing at 24 kHz, and sends it as `remote_speech_audio` parts: `part` counts from 0 across the whole reply, `data` is base64, `parts` is 0 until the last sentence and then the total, and `last` is `true` on the final part only. A failure ends the stream with an empty final part. A `remote_ack` for the frame, or a `remote_speech_control` that covers it, stops the remaining audio.

**Stopping.** A device drops every frame it received before a `remote_speech_control`. While a sink has frames it has not acknowledged, `pause` and `stop_playback` send it one `stop` and `skip` sends one `skip`, with the reason of the request (`speech_only_barge_in` for `pause`; `newer_command` is sent as `superseded`). `new_turn` sends `stop` with the reason `superseded` when the sink holds status speech of an older command, unless a reply it has not acknowledged would be dropped with it. With no unacknowledged frame, no control is sent.

## Events

### `state`

The queue in playing order. Sent when it changes; also the result of `status`.

| Field | Meaning |
| --- | --- |
| `speaking` | Audio is playing or a reply is waiting. |
| `playing` | Audio is playing. |
| `held` | A stop is holding the queue until `play` or `new_turn`. |
| `queue_depth` | Replies not yet heard: the queue, plus frames a Relay Remote sink has not acknowledged. |
| `queue` | `{"utterance_id", "original_utterance_id"}` per item, head first. A reply that returned to the queue has a new `utterance_id` and keeps its `original_utterance_id`. |

### `playback`

One utterance's progress. Fields: `phase`, `utterance_id`, `original_utterance_id`, `relay_command_seq`, `relay_command_id`, `kind`, `source`, `session_key`, `replay_of`.

| `phase` | Meaning |
| --- | --- |
| `queued` | The utterance is at the head of the queue and waits for `play` (or plays at once with `auto_play`). |
| `preparing` | Play was requested. |
| `ready` | The first sentence is synthesised. |
| `started` | Playback started. |
| `chunk_started` | One sentence was handed to the output. Sent once per sentence. |
| `completed` | Every sentence played. |
| `cancelled` | It was stopped, skipped, replaced or found stale. |
| `failed` | Synthesis or the output failed. |

Only an utterance that reached the head of the queue has `playback` events; one that is replaced, dropped or found stale while still behind the head just leaves the `queue` of the next `state` event. An attempt ends with exactly one of `completed`, `cancelled` or `failed`. Those three carry `stop_reason` (the reason of the stop or skip that ended a reply while it was playing, otherwise `null`) and `requeued_as` (the `utterance_id` under which the reply returned to the queue, otherwise `null`). The one case in which an `utterance_id` is `queued` again after `cancelled` is the reply `control_session` moved back.

A stop, skip or replacement should end a playing attempt with `cancelled`. The Python worker deviates when the stop lands while it takes the audio lease for a sentence: just after `started`, before the first sentence's `chunk_started`, or between two sentences. The lease then reports the stop as an error, and the attempt ends `failed`, with a `playback_failed` error, instead of `cancelled`. A reply that the stop should have returned to the head of the queue leaves the queue instead. The worker can also lose a `play` that arrives after a reply ends but before the reply that comes forward is `queued`: that reply then waits for another `play`. Both were so before the split, and the suite does not check either. A case stops a reply only once a sentence is at the output, and that sentence plays far longer than the case takes to act. It plays a reply that came forward only after its `queued`.

### `reply_finished`

`{"event": "reply_finished", "reason": "completed" | "user_stop"}`. A reply ended and nothing else is queued. The bridge uses it to bring forward the next unheard reply of a background session.

### `error`

`{"event": "error", "code": "..."}`. `playback_failed` (with `utterance_id`) accompanies a `failed` phase; `invalid_message` and `line_too_long` report a line the service could not use.

## Queue rules

There is one queue for every session. `speak` answers `accepted: false`, and the intent is never spoken, when:

- `text` is empty, or `expires_at` has passed;
- the intent is stale (see [Freshness](#freshness));
- its `dedup_key` was accepted before, or it is a fallback for a command whose real final was accepted;
- the queue already holds 50 items.

An accepted intent goes to the back of the queue, with these exceptions:

- **Supersede.** A `clarification`, `final` or `fallback` replaces the same command's `handoff` or `progress` speech that has not started, wherever it is queued. Speech with a higher `priority` likewise replaces the same command's `progress` or `control` speech waiting at the head.
- **Replace.** An authoritative `final` from `completion` or `orchestrator` replaces the same command's fallback outcome, even while that fallback is playing.
- **Newer command.** Speech of a newer command stops the older command's status speech at the head. A reply is never removed by a newer command.

The head of the queue is published as waiting and plays on `play`; with `auto_play` it plays at once. When it ends, the next item becomes the head. A reply leaves the queue only by playing to its end, by `skip`, by a `recording_barge_in` stop, or by being replaced; a reply that was only stopped returns to the head.

The newest 32 replayable replies that played, were skipped or were stopped form the replay history.

## Freshness

The service reads `VOICE_COMMAND_STATE_FILE` whenever it must decide whether a command is still the user's current one. The bridge replaces that file atomically. Its top-level `relay_command_seq` and `relay_command_id` name the current command; an unreadable or missing file names none.

An intent is fresh when any of these holds:

- it has no `command_seq` and `command_id`;
- its command is the current command;
- it is an explicit replay, or a `lifecycle` `final` with `freshness_scope: "work"`;
- it is a reply that was already accepted;
- it is an authoritative `final` or `fallback` whose command is **preserved**: the current command is newer, its `work_disposition` has `route: "continue_current"`, `authorization_effect: "preserve"` and a `cancellation_scope` of `none` or absent, and the intent's `work_disposition.intent_id` is not in `cancelled_intent_ids`.

Freshness is checked when an intent is proposed, when it reaches the head of the queue, and before each sentence is played.

## Surfaces the service owns

These existed before the split and are unchanged.

- **`TTS_CONTROL_SOCK`** receives datagrams: `play` and `toggle` act as `play`, `replay` as `replay`, `skip` and `cancel` as `skip`, `pause` and `stop` as `pause`.
- **State datagrams** to `VOICE_STATE_SOCK` are JSON objects with `source: "tts"` and `state` of `message_waiting`, `preparing`, `speaking`, `idle` or `failed`, the utterance's identity, and the display text where there is one. A datagram is at most 2048 bytes; longer text is shortened. A reply stopped while it plays should end with `idle` carrying its `stop_reason`. The Python worker often sends no `idle` at all in that case, because its playback thread finishes while the stop is still fading the audio; this was so before the split, and the suite does not check it.
- **`SPEECH_EVENT_LOG`** gets one JSON object per line for every proposal, decision and playback stage. It never holds reply text.
- **`voice-audio.lock`** is held with `flock` while audio plays, so a Settings voice preview and a reply never overlap.

`/tmp/tts_in.fifo` and `/tmp/voice_bridge.sock` stay with the bridge, which turns their input into the requests above. The tutorial's standalone mode (`tts_worker.py` reading stdin) and `preview_voice.py` are separate programs and do not use the service.

## Restarts

**The service keeps nothing on disk.** A new service process starts with an empty queue, no replay history, no accepted keys, no held state and no devices, binds its sockets again, and reports a new `instance_id`. An intent the old process had accepted is accepted again.

When the service ends without being asked to, the client:

1. fails the requests that were waiting for a response;
2. starts a new service, at most three times a minute, then stops trying and treats every request as refused;
3. clears the overlay's speech state, attaches its Relay Remote devices again, and sends again every `speak` whose reply the last `state` event still listed, in queue order. They are ordinary `speak` requests, so a reply whose command is no longer fresh is dropped. Replay history, `read_out` text and frames a Relay Remote sink had not acknowledged are not restored.

**The service never outlives its client.** When the connection ends, or the parent process exits before connecting, the service stops speech at once and exits. A restarted bridge starts a new service; nothing queued carries over, exactly as when speech ran inside the bridge. The old service may still be stopping when the new one binds `TTS_CONTROL_SOCK`, so a service removes that path on exit only while it is still the socket it bound.

## Rollback

`RELAY_SPEECH_SERVICE_MODE=legacy` in the bridge's environment keeps speech inside the bridge process, as before RR-480. It will be removed one release after the service ships. If the service cannot be started at all, the bridge logs the reason and uses the in-process path for that session.

## Test mode

`RELAY_SPEECH_TEST_MODE=1` replaces the two things a test cannot observe, and nothing else:

- **Synthesis.** No model is loaded. Each sentence becomes 24 kHz mono 16-bit silence lasting `RELAY_SPEECH_TEST_MS_PER_CHAR` milliseconds per character, and at least 20 ms.
- **Output.** No audio device is opened. A timer consumes the audio at the speed a device would, `rate` times real time. The chime is not played.

Everything else runs as in a session: the queue, the sockets, the state datagrams, the event log, the audio lease, and Relay Remote encoding through `afconvert`.

`RELAY_SPEECH_TEST_PLAYBACK_LOG` receives what would have reached the speaker, one JSON object per line, each with `event` and `at` (Unix time):

| `event` | Fields | Meaning |
| --- | --- | --- |
| `synthesized` | `text`, `seconds`, `voice` | A sentence was rendered. Replies are synthesised ahead of play. |
| `chunk_started` | `utterance_id`, `text`, `seconds`, `rate` | A sentence was handed to the output. |
| `chunk_finished` | `utterance_id`, `text`, `completed` | The sentence played to its end (`true`) or was cut off (`false`). |
| `output_started` | `sample_rate`, `rate` | The output device would have started. |
| `output_stopped` | | The output device would have stopped. |
| `chime` | | The waiting chime would have played. |

## Contract cases

`tests/contract/speech_contract_support.py` is the harness. Every case is a method of one of the classes below, and its docstring quotes the rule it checks. File names are relative to `tests/contract/`.

| File | Class | Checks |
| --- | --- | --- |
| `test_speech_contract_protocol.py` | `ProcessTests` | [Process](#process): the socket, its one connection, exit statuses, signals, a parent that exits |
| | `TransportTests` | [Transport](#transport): `hello`, error codes, request ids, unknown fields, lines that are not messages, the line limit |
| | `OrderingTests` | [Ordering](#ordering) rules 1 to 4 |
| | `SessionRequestTests` | [Session](#session): `reload_config`, `shutdown` |
| | `DiagnosticsTests` | [Diagnostics](#diagnostics): every request |
| | `OwnedSurfaceTests` | [Surfaces the service owns](#surfaces-the-service-owns): control socket, state datagrams, event log, audio lease |
| | `TestModeTests` | [Test mode](#test-mode): silence length, the playback log |
| `test_speech_contract_queue.py` | `QueueOrderTests` | [Queue rules](#queue-rules): queueing in order, refusals, deduplication |
| | `SupersedeAndReplaceTests` | [Queue rules](#queue-rules): Supersede, Replace, Newer command |
| | `QueueCapTests` | [Queue rules](#queue-rules): the 50-item cap |
| | `FreshnessTests` | [Freshness](#freshness): stale intents, preserved commands, the three points of checking |
| `test_speech_contract_playback.py` | `PlaybackEventTests` | [Events](#events): `playback`, `state`, `reply_finished` |
| | `AutoPlayTests`, `RateTests` | [Process](#process): `[tts]` `auto_play` and `rate` |
| | `BargeInTests` | [Playback control](#playback-control): `stop_playback` (barge-in), `pause` and resume, `play` |
| | `SkipTests` | [Playback control](#playback-control): `skip` and its reasons |
| | `NewTurnTests` | [Playback control](#playback-control): `new_turn` |
| | `ReplayTests`, `ReplayHistoryTests` | [Playback control](#playback-control): `replay`, `play_or_replay`, `read_out`; the 32-reply history |
| | `WaitingPlaybackTests` | [Speaking](#speaking): `arm_waiting_playback`, `waiting_playback_kind` |
| | `SessionTests` | [Sessions](#sessions): `session_playback_states`, `control_session` |
| `test_speech_contract_remote.py` | `RemoteSinkTests` | [Relay Remote](#relay-remote): a remote synthesis request, acknowledgement, stop, detach, [Ordering](#ordering) rule 5 |
| | `RemoteMirrorTests` | [Relay Remote](#relay-remote): the `mirror` role |
| | `RemoteRequestTests` | [Relay Remote](#relay-remote): request fields |
| `test_speech_contract_restart.py` | `RestartTests` | [Restarts](#restarts): a service restart with queued speech |
| | `ClientGoneTests`, `OverlapTests` | [Restarts](#restarts): a client that disappears, an old service still stopping |

The bridge's side of a restart, its device calls and its start-up code are covered by `tests/test_speech_service_client.py`, which is not part of the contract.
