# Relay Remote

**Status:** Proposed

Proposed direction, 22 October 2026. Source inspected at Relay commit `7341421d7d63eb2e1fd6baab2e28e7a9427ba02b`.

Relay Remote is the proposed path for a native iOS app to drive a Relay Runner voice session on the user's own Mac. Speech-to-text stays on the phone and only text travels from the phone to the Mac. Replies travel back as text and, in Remote mode, as audio in the Mac's own configured voice, synthesised on the Mac and streamed sentence by sentence (RR-457). Both directions run inside an SSH connection to the Mac's built-in OpenSSH server. It sits beside [Relay Actions](relay-actions.md) and [Relay Vision](relay-vision.md), which keep owning screen manipulation and observation on the Mac. Relay Remote owns nothing on screen: it adds a second voice input and output device to the existing voice contract and routes replies back to whichever device asked.

## Validation of the SSH and TCP proposal

**Verdict.** The proposal is sound and is the recommended shape. The Mac already ships an SSH server (Remote Login), the phone can hold one authenticated SSH connection and multiplex text both ways over it, and nothing in the path needs a hosted service, an account, or a third-party relay. The two pieces Relay has to build are an iOS client and a small, restricted entry point on the Mac that joins the SSH connection to the running voice session.

**What "serverless" means here.** No cloud intermediary and no Relay-operated service. The Mac still runs a server process, `sshd`, but it is Apple's, it already exists on every Mac, and the user controls it from System Settings. Relay never stands up its own listening TCP port on the Mac's network interfaces; the only network listener in the design is `sshd` itself.

**Why SSH rather than a bespoke TCP protocol.** A bespoke protocol would have to reinvent what SSH already gives for free: mutual authentication (per-device keys plus a pinned host key), confidentiality and integrity on an untrusted Wi-Fi or cellular path, a per-key policy that confines a device to one program on the Mac, and key revocation by deleting a line. OpenSSH's `authorized_keys` options make that confinement explicit: `command="..."` runs a fixed program regardless of what the client asked for (the client's request is only exposed as `SSH_ORIGINAL_COMMAND`), `restrict` disables PTY allocation, port forwarding, agent forwarding, X11 and `~/.ssh/rc`, and `expiry-time=` lets a pairing key expire on its own. TCP is still the transport underneath, so the friend's description "SSH and TCP" is exactly right.

**Two channel shapes.** The recommended shape is an SSH exec channel whose forced command is a Relay helper speaking newline-delimited JSON over its stdin and stdout; the SSH channel carries that byte stream and nothing else. The alternative is a `direct-tcpip` channel (SSH local port forwarding) to a loopback-only TCP listener on the Mac, which would need `restrict,port-forwarding,permitopen="127.0.0.1:<port>"` on the key and a Relay-owned TCP listener bound to loopback. The exec shape is preferred because it needs no Relay network listener at all, it works unchanged with `restrict`, and the process-per-connection boundary makes the helper trivially restartable. The `direct-tcpip` shape stays documented as the fallback if the iOS SSH library turns out to handle exec channels poorly.

## Goals

- A paired iPhone on the home network, or on the user's tailnet, can send a spoken request to the Mac's running Relay session and hear the reply in the Mac's own voice, with speech recognition on the phone, text from the phone to the Mac, and the Mac's synthesised reply audio streamed back.
- The phone's text enters the exact command pipeline the Mac microphone uses: command identity, intent inbox, claim files, stale-output suppression and reply ownership all behave as they do today.
- Replies, messenger speech, clarifications and worker lifecycle speech that would have been spoken by the Mac's Kokoro worker are instead synthesised on the Mac without opening its speaker and delivered to the phone that asked, as text followed by audio, and the Mac stays silent while the phone is the active device.
- Pairing is a one-time, Mac-confirmed action; revocation is deleting one line the app wrote.
- Codex and Claude sessions see identical behavior.

## Non-goals

- No hosted relay, account, push notification service or Relay-operated server. Push notifications would require a server and are out of scope; instead the phone posts local notifications for replies while it is alive in the background with its audio session active (RR-532, design `docs/design/relay-remote-ios/README.md`).
- No audio from the phone to the Mac: the phone sends text only. From the Mac to the phone, audio is limited to synthesised reply speech (RR-457 retired the earlier text-only rule for that direction). The Mac's microphone and speaker output are never streamed.
- No remote screen viewing or screen control from the phone. Relay Actions and Relay Vision remain Mac-local.
- No choice of provider from the phone, and no switching projects while a session runs. The phone attaches to a running session, or starts one for a registered project, or for the built-in general-tasks project when it names none, when none is running (RR-456, RR-532, [Session control](#session-control)); that session uses the Mac's current defaults, and starting a different project is refused until the running one is stopped. Since RR-532 the phone can read the provider and change the orchestrator model, effort, sub-agent sizing and speech speed ([Settings](#settings)).
- No multi-user access. One Mac login user, that user's keys, that user's session.
- No waking of a sleeping Mac. A sleeping or logged-out Mac is unreachable by design.

## Architecture

```
iPhone (Relay Remote app)
  mic -> on-device STT -> NDJSON frames ----\
  audio player <- speech + speech_audio <--+-- one SSH connection, one exec channel, port 22
                                            |
Mac                                         v
  sshd (Remote Login) -> authorized_keys forced command
      -> relay-remote-shell --device <device_id>          (bundled Swift helper, stdin/stdout)
          <-> /tmp/relay_remote.sock                       (Unix stream socket, bridge-owned)
              services/relay_remote.py inside voice_bridge.py
                 - utterances  -> bridge ingress queue -> command pipeline -> PM session
                 - controls    -> existing __TTS_STOP__ / __INTERRUPT__ / __CANCEL__ / __PLAY__ / __REPLAY__
                 - speech      <- SpeechCoordinator remote sink (Kokoro synthesises; the Mac speaker stays closed)
          <-> /tmp/relay_session_control.sock              (Unix stream socket, app-owned, RR-456)
                 - session_command -> list projects, start, stop, state
                 - workspace_command, settings_command (RR-532) -> Workspace feed, settings
  Relay Runner.app
     - pairing UI, authorized_keys writer, /tmp/relay_remote_pair.sock
     - microphone and speaker gate while a remote device is active, status, keep-awake
     - session control: /tmp/relay_session_control.sock while the app runs
```

| Component | Lives in | Responsibility |
| --- | --- | --- |
| Relay Remote iOS app | new `ios/` project in this repo plus a shared SwiftPM protocol target | Capture speech, transcribe on device, hold the SSH connection, play the Mac's reply audio or speak text frames that carry none, pair and store the device key |
| `relay-remote-shell` | new Swift executable target, embedded and signed by `scripts/build-dmg.sh` | The forced command. Copies NDJSON between the SSH channel and the bridge socket, or the session-control socket when no bridge listens; enforces frame limits, exits when either side closes |
| Relay Remote server | Rust module `rust/relay-rs/src/remote/` (RR-491), hosted in-process by the voice bridge (`relay-rs bridge`); it replaced `services/relay_remote.py`, removed in RR-487 | Owns `/tmp/relay_remote.sock`, device sessions, sequence numbers and the replay buffer; feeds utterances into the bridge's ingress; is the speech coordinator's remote sink |
| Pairing and gate | `Sources/relay-runner` | Pairing flow and `~/.ssh/authorized_keys` management, Remote Login detection, suspending the Mac microphone and Kokoro output while a phone is active, status in the notch and menu bar, no-idle-sleep assertion |
| `RelayRemoteProtocol` | SwiftPM library target (macOS 14, iOS 18) with a Rust twin | Frame schema, codec and golden test vectors shared by the helper, the iOS app and the bridge |

**Why the bridge owns the device session.** `services/voice_bridge.py` already owns command identity (`_begin_relay_command`), the intent inbox, the claim and state files, and the `SpeechCoordinator` that decides what is spoken and when. Putting the remote session next to those keeps one ordering of commands and one freshness policy. The Swift app owns only what needs the UI or the user's home directory: pairing, the authorized-keys file, the microphone gate and status.

**Why a separate helper rather than pointing `command=` at Python.** The forced command runs under `sshd` with none of the app's environment, so it must find the socket deterministically, start fast, and fail with a structured error when no session is running. A small Swift binary bundled with the app does that without depending on the bridge's environment being resolvable from an SSH login. The `authorized_keys` line points at a stable per-user shim, `~/Library/Application Support/relay-runner/bin/relay-remote-shell`, that the app rewrites at launch to exec the binary inside the current bundle, so moving or updating the app does not break paired devices.

## Pairing and trust

1. The user opens Settings in Relay Runner and chooses Relay Remote, then Pair a device. The app checks that `sshd` is listening by connecting to `127.0.0.1:22` and reading the `SSH-2.0-OpenSSH` banner. If it is not, the app deep-links to System Settings, General, Sharing, Remote Login and explains that only the current user needs access; the app never changes Remote Login itself because that requires administrator rights.
2. The app generates a pairing id, a one-time token and an ephemeral Ed25519 keypair, and installs the ephemeral public key in `~/.ssh/authorized_keys` as `command="<shim> --pair <pairing_id>",restrict,expiry-time="<now+10 minutes, UTC>"`.
3. The app shows a QR code containing the protocol version, reachable host candidates (Bonjour host name, LAN addresses, tailnet name if present), the SSH port, the SHA-256 fingerprints of the Mac's host keys, the pairing id, the ephemeral private seed and the token. A copy-as-text fallback exists for Universal Clipboard. The QR is shown on the Mac's own screen only and is single use.
4. The phone scans the QR, creates its permanent device key in the Secure Enclave (P-256, exposed to SSH as `ecdsa-sha2-nistp256`), connects with the ephemeral key, verifies the host key against the pinned fingerprints, and sends a `pair` frame with the token, its public key, a device id and a display name.
5. The helper in `--pair` mode forwards that frame to the app over `/tmp/relay_remote_pair.sock`. The app verifies the token and shows a confirmation sheet naming the device and its key fingerprint. Only after the user clicks Allow does the app append `command="<shim> --device <device_id>",restrict <public key> relay-remote:<device_id>` and remove the ephemeral line. The phone receives `paired`, discards the ephemeral key, and from then on authenticates with its own key only.
6. Unpairing, on either side, removes that device's line. The app also offers an optional `from="<home CIDR>,<tailnet CIDR>"` restriction per device.

The app manages only lines carrying its `relay-remote:<device_id>` comment marker, writes the file atomically (temporary file plus rename), creates `~/.ssh` with mode 700 and the file with mode 600 when missing, and refuses to proceed when the directory or file is group- or world-writable because `sshd` would reject the key under `StrictModes`. `scripts/relay-runner.entitlements` carries no App Sandbox entitlement, so the app can write under `~/.ssh` directly.

## Wire protocol

One connection per device, one exec channel, newline-delimited UTF-8 JSON in both directions, one object per line, 64 KiB per frame. The helper closes the connection on an oversized or unparsable line; the phone reconnects. Frames the Mac sends carry a per-device monotonically increasing `seq`; frames the phone sends carry a `client_id` UUID so a retry after a reconnect never produces a second command.

```
phone -> Mac
{"type":"hello","protocol":1,"device_id":"...","device_name":"iPhone","app_version":"0.1","resume_after_seq":41,"remote_mode":true}
{"type":"utterance","client_id":"...","text":"move RR-120 to ready","captured_at":"2026-10-22T09:14:03Z","agent":"george"}
{"type":"control","client_id":"...","action":"stop","agent":"george"}           stop | interrupt | cancel | play | replay
{"type":"remote_mode","client_id":"...","enabled":false}
{"type":"session_command","client_id":"...","action":"start","project_id":"...","agent":"george"}   list_projects | start | stop | state
{"type":"workspace_command","client_id":"...","action":"list"}
{"type":"workspace_command","client_id":"...","action":"get","project_id":"...","ticket_id":"RR-120"}
{"type":"settings_command","client_id":"...","action":"get"}
{"type":"settings_command","client_id":"...","action":"set","model":"sonnet","speech_speed_percent":150}
{"type":"ack","seq":44,"played":true}
{"type":"ping","t":1761124443}

Mac -> phone
{"type":"welcome","protocol":1,"session_state":"running","server_seq":44,"resumed_from":41,"dropped":false}
{"type":"accepted","client_id":"...","relay_command_seq":812,"relay_command_id":"4711-1761124443123456789-812","agent":"george"}
{"type":"speech","seq":45,"kind":"handoff","source":"messenger","text":"Looking at RR-120 now.","relay_command_seq":812}
{"type":"speech","seq":46,"kind":"final","source":"orchestrator","text":"RR-120 is in ready and dispatching.","relay_command_seq":812,"spoken_by":"phone","audio":true}
{"type":"speech_audio","seq":46,"part":0,"parts":0,"format":"aac","sample_rate":24000,"data":"//FgQB/7/N4CAExhdmP+vw=="}
{"type":"speech_audio","seq":46,"part":1,"parts":2,"format":"aac","sample_rate":24000,"data":"//FgQAuf/CEQBA==","last":true}
{"type":"speech_control","seq":47,"action":"stop","reason":"superseded"}
{"type":"status","seq":48,"text":"worker RR-120 started"}
{"type":"error","code":"no_session","message":"Relay Runner is not running a session"}
{"type":"pong","t":1761124443}
{"type":"session_state","app_running":true,"session":"none","projects":[{"project_id":"...","display_name":"relay-runner","availability":"available"}]}
{"type":"session_state","app_running":true,"session":"ready","project_id":"...","project_name":"relay-runner","active_agent":"george","running_agents":["puck","george"]}
{"type":"session_state","app_running":false,"session":"none"}
{"type":"session_state","app_running":true,"session":"ready","project_id":"...","project_name":"relay-runner","active_agent":"george","running_agents":["puck","george"],"agents":[{"agent":"puck","running":true,"state":"working","working_on":"RR-120 review"},{"agent":"isabella","running":false,"state":"off"},{"agent":"george","running":true,"state":"playing"},{"agent":"sky","running":false,"state":"off"}]}
{"type":"workspace_state","projects":[{"id":"...","name":"relay-runner"}],"tickets":[{"id":"RR-120","title":"...","status":"in_progress","project_id":"...","agent":"puck"},{"id":"RR-121","title":"...","status":"queued","project_id":"..."}],"truncated":true}
{"type":"workspace_ticket","project_id":"...","ticket_id":"RR-120","title":"...","status":"in_progress","agent":"puck","markdown":"## Description\n\n...","truncated":true}
{"type":"workspace_ticket","project_id":"...","ticket_id":"RR-999","error":"That ticket no longer exists."}
{"type":"settings_state","speech_speed_percent":130,"provider":"claude","model":"opus","effort":"medium","sizing":"orchestrator_decides","model_options":[{"value":"opus","label":"Opus"}],"effort_options":[{"value":"medium","label":"Medium"}],"sizing_options":[{"value":"orchestrator_decides","label":"Orchestrator decides"}]}
```

Every frame above has golden vectors in `tests/RelayRemoteProtocolTests/Vectors`: `frames.json` holds the frames before RR-532, which carry none of its fields, and `frames_extended.json` the RR-532 frames and fields; `invalid.json` holds the refusals of both. The Swift codec (`Sources/RelayRemoteProtocol`) and its Rust twin (`rust/relay-rs/src/remote/protocol.rs`) must encode and decode all of them byte for byte.

- `accepted` is the phone's receipt that an utterance entered the intent inbox, the remote equivalent of the notch's visual receipt. The phone shows it; it does not speak it.
- `speech` mirrors `SpeechIntent` from `services/speech_coordinator.py`: the same `kind` values (`handoff`, `progress`, `clarification`, `final`, `fallback`, `control`) and `source` values (`messenger`, `orchestrator`, `lifecycle`, `completion`, `fallback`). With `audio: true` the Mac's voice for that text follows in `speech_audio` frames and the phone plays it; with `audio: false`, or no `audio` key, the phone speaks the text with its own synthesizer. Either way the phone answers `ack` with `played` once the frame has played, so the coordinator's realization record and played coverage stay truthful.
- `speech_audio` (RR-457) carries the Mac's voice for the `speech` frame whose `seq` it repeats. The TTS worker synthesises each sentence with the configured Kokoro voice, encodes it with `afconvert` as AAC-LC, 24 kHz mono, 48 kbps constant bit rate, in ADTS framing (about 6.3 KB/s measured on Kokoro speech), and the coordinator sends it before the next sentence is synthesised. The parts of one seq are consecutive slices of one ADTS stream, numbered from 0, each at most 32 KiB of base64, so every frame stays well inside the 64 KiB line limit. `parts` is 0 until the final sentence is encoded and then the total, and the final part carries `last: true`. Each sentence is encoded on its own, so encoder priming and padding add up to about 130 ms of silence per sentence. `opus` is accepted by the codecs but not sent today.
- The text frame always leaves first so the phone can show it at once. Synthesis for the phone never uses the Mac's speech player or `VoiceAudioLease`, so no Mac audio device opens. `new_turn`, `stop`, `stop_playback` and `skip` send `speech_control` as before and cancel synthesis for every frame before it, because the phone drops those frames; the phone's `ack` for a frame and the sink detaching cancel it too.
- Fallback: if no voice is loaded or `afconvert` is missing, the text frame says `audio: false` and the phone uses its own voice. If synthesis or encoding fails partway through a reply, the Mac ends that stream with an empty final part (`data: ""`, `last: true`) and logs `remote_audio_failed`; after an encoding failure every later reply carries `audio: false` for the rest of the bridge session. A phone that receives no audio before such an empty final part speaks the text itself.
- `speech_audio` takes no seq of its own and is never acknowledged; the phone acknowledges the `speech` frame once its audio has played. The replay buffer keeps the parts with their text frame, replays them straight after it, trims them with it on ack or expiry, and does not count them towards the 200-frame window. A phone that lost the end of a stream to a disconnect resumes from the seq before that frame and drops the parts it already has by `seq` and `part`.
- Protocol version 1 is unchanged. Both decoders ignore unknown keys, and a phone built before the audio player logs the unknown `speech_audio` type, speaks the text with its own voice and acknowledges as before, which cancels the rest of the Mac's synthesis for that frame. The Mac never receives `speech_audio`; its decoder knows the type and the server answers `unexpected_frame`.
- Each reply's time from coordinator submit to its first emitted audio part is logged as `remote_first_audio` with `submit_to_first_audio_ms` in the speech event log, and `scripts/speech-latency-report.py` lists it per reply with p50 and p95 under `remote_audio_latency`, so Wi-Fi, Tailscale and cellular can be compared.
- `remote_mode` is the phone's Remote mode switch (RR-454), and `hello` carries its current value so a reconnect restores it; an absent value means on. On, the phone owns the microphone and speaker: the device is the coordinator's speech sink, the bridge posts `remote_device` `active`, the Mac microphone gate is suspended and the Mac is kept awake. Off, the bridge detaches the sink without closing the connection, posts `inactive`, Kokoro speaks on the Mac and the Mac microphone is live; each intent Kokoro speaks is also sent as `speech` with `spoken_by: mac` and no audio, which the phone shows without synthesising and acknowledges `played: true` at once. Disconnecting posts `disconnected`; the replay window below applies only while the mode was on. Protocol version 1 is unchanged: both decoders ignore unknown keys, and an older Mac answers the new frame type with an `unknown_type` error that the phone logs and survives.
- `speech_control` carries the coordinator's stop and skip decisions, including stale-output suppression when a newer command exists.
- The Mac keeps a bounded replay buffer per device (the last 200 frames or five minutes). A `hello` with `resume_after_seq` replays what the phone missed, or sets `dropped: true` so the phone can say that updates were missed rather than pretending nothing happened. Frames the phone has acknowledged are trimmed.
- Controls map one-to-one onto the FIFO tokens the bridge already dispatches: `stop` to `__TTS_STOP__`, `interrupt` to `__INTERRUPT__`, `cancel` to `__CANCEL__`, `play` to `__PLAY__`, `replay` to `__REPLAY__`. No new control semantics are introduced.
- `SSH_ORIGINAL_COMMAND` is ignored except for an allow-listed `status` subcommand that returns one `status` frame and exits, used by the phone's connection check.
- `session_command` and `session_state` (RR-456) are described under [Session control](#session-control). Neither carries a `seq` or is replayed. Protocol version 1 is unchanged: both decoders ignore unknown keys, the phone logs an unknown frame type and continues, and the helper hands `session_command` to the app, so a voice bridge never receives it.
- RR-532 adds [agent addressing and per-agent state](#agents), the [Workspace feed](#workspace-feed) and [settings](#settings). Every addition is an optional field or a new frame type, so protocol version 1 is unchanged and a peer that sends none of them behaves exactly as before.

### Which side serves each command

| Phone frame | Served by | Answer |
| --- | --- | --- |
| `hello`, `utterance`, `control`, `remote_mode`, `ack`, `ping` | Voice bridge (`rust/relay-rs/src/remote/server.rs`) | `welcome`, `accepted`, `speech`, `speech_audio`, `speech_control`, `status`, `pong` |
| `session_command` | App, `/tmp/relay_session_control.sock` (`RelaySessionControl.swift`) | `session_state` |
| `workspace_command` (RR-532) | App, `RelayRemoteWorkspaceFeed.swift` | `workspace_state`; RR-551: `get` is answered with `workspace_ticket` |
| `settings_command` (RR-532) | App, `RelayRemoteSettings.swift` | `settings_state` |

The app serves the Workspace and settings because it owns the project registry, the boards and the configuration; the bridge sees none of them. `relay-remote-shell` sends all three app commands to the session-control socket, opening it beside an attached bridge on the first one, and answers `app_unavailable` when the app is not running. None of them carries a `seq` or is replayed; `client_id` is checked as a UUID. On a session-control channel the app also ignores `utterance` and `control` frames, as it always has: there is no bridge to take them.

**Older peers.** A phone built before RR-532 never sends the new frames or fields and ignores the new keys it receives; the Mac sends `workspace_state` and `settings_state` only in answer to a command. A Mac built before RR-532 ignores `agent` and delivers to the focused agent, sends no `agents`, refuses a `start` without `project_id` with "Choose a project to start.", and answers `workspace_command` and `settings_command` with an `unknown_type` error from an attached bridge, or not at all on a session-control channel. The phone treats either as "not available on this Mac".

**Older peers, ticket text (RR-551).** A phone built before RR-551 never sends `get` and ignores `workspace_ticket`; the Mac sends it only in answer to a `get`. A Mac built before RR-551 rejects the unknown `get` action as an `invalid_field` error (the frame fails validation, so it never becomes a list request); the phone, which has a `get` outstanding, shows the single line "Ticket text is not available on this Mac." instead of a spinner and offers no retry. It asks again the next time a ticket is opened.

### Agents

The Mac runs up to four named agents, by slug `puck`, `isabella`, `george` and `sky` (table order, `RelayRemoteProtocol.agents`). The codecs accept any string as a slug so that a later agent does not break an older peer; the Mac refuses or ignores one it does not know.

- **Addressing.** `utterance` and `control` carry an optional `agent`: the agent the request or control is for. Absent means the agent focused on the Mac, today's behaviour. `accepted`, `speech`, `speech_audio`, `speech_control` and `status` carry an optional `agent` naming the agent the frame belongs to; absent means the focused agent, and on `speech_control` every agent's speech, as before. A `speech_audio` part carries the same `agent` as the `speech` frame it voices.
- **Per-agent state.** `session_state` carries an optional `agents` list, one entry per agent in table order, running or not: `agent`, `running`, `state`, an optional short `working_on` and the agent's `work_style` (`auto`, `direct` or `orchestrated`; absent from an older Mac). `state` is `off` (not running), `starting`, `ready` (running and idle), `working` (running a turn), `listening` (taking the user's speech) or `playing` (its reply is playing). The Mac includes it in every `session_state` once it reports per-agent state, so the app's once-a-second push carries every change; absent means a Mac that does not report it.
- **What ships in RR-532.** The codecs, the kit and the seams. RR-534 routes by agent, tags the frames and fills `agents`, as below.
- **Addressed delivery (RR-534).** The bridge (`rust/relay-rs/src/bridge/remote_agents.rs`) delivers an `utterance` that names an agent to that agent's own voice target: the live session whose spool's `session_agent` is that slug. The command is written into that session's mailbox with `voice_target_session_key` set to it, so it is authorised against that session's mutation grants, not the focused one's, and it keeps its `input_source` (`remote`), `device_id`, `relay_command_seq` and `relay_command_id` exactly as an unaddressed one does. Delivery never moves voice focus: the session the Mac's microphone and `__FOCUS__` follow stays the one the user chose. An utterance without `agent` goes to the focused session, as before. The server refuses a slug the Mac does not run with an `error` frame, code `unknown_agent`.
- **Addressed controls.** A `control` with `agent` acts on that agent's session only: `stop` stops its speech (as `__TTS_STOP__` does, but only for that session), `cancel` dismisses its current reply, `play` plays its waiting reply or else replays it, `replay` replays its newest reply, and `interrupt` stops its speech and publishes `__INTERRUPT__` into its mailbox. Another agent's speech is untouched. A control for an agent with no session does nothing. A control without `agent` is its FIFO token, as before.
- **Tagged frames.** `accepted` names the agent whose session received the command (for an unaddressed utterance, the focused session's agent). `speech` names the agent of the session the speech belongs to, including a reply from an agent that is in the background on the Mac; the speech service passes that session's key with each remote call ([speech-service-protocol.md](speech-service-protocol.md)), and the bridge maps it to the session's agent. Speech that belongs to no session, such as a notice from the bridge itself, carries no `agent`. A `speech_audio` part carries its `speech` frame's agent. A `speech_control` scoped to one session (an addressed control, or the session wheel's per-session stop) names that session's agent and covers only that agent's earlier frames; one that is not scoped carries no `agent` and covers every frame, as before. The only `status` the Mac sends is the connection check's session probe, which belongs to no agent and so carries none. Which device a reply reaches is unchanged: the device that asked, or the Remote-mode sink.
- **State values and their source (RR-534).** The app builds `agents` from what drives the desktop notch glyph (`NotchSessionStatus.resolve` in `Sources/relay-runner/Overlay/NotchStatusController.swift`), attributed to the agent each status is about: `listening` is the agent the Mac recording is delivered to, `playing` the agent whose reply is playing (the speech presentation's session), and `working` the active agent while the notch shows Working, plus any agent whose own provider turn is active (its spool's provider session in the provider turn ledger). `starting` is an agent whose launch was accepted and whose provider is not ready, or any live agent while the session itself is still starting; `ready` is a running agent doing none of these; `off` is an agent with no session. `working_on` is the agent card's "Currently working on" description, present only while the card shows it for the running session. Changes are pushed on the app's one-second tick, so rapid changes coalesce into at most one `session_state` a second, and an agent becoming ready is pushed at once.
- **Message to start (RR-534).** An utterance addressed to an agent with no session is held by the bridge, which asks the app to start that agent (a `{"source":"remote_agent","state":"start","agent":…}` datagram on the app's state socket). The app starts it exactly as a phone `start` naming that agent and no project does ([Session control](#session-control)). Starting an agent focuses it on the Mac, as every start does; once the agent is ready the Mac's focus returns to the agent that was focused before, so local microphone input goes where the user chose. The app tells the bridge a session is still starting with `"ready": false` in its `__FOCUS__` payload, and pushes the agent's `ready` state to the phone before it clears that flag, so the phone sees `starting`, then `ready`, then the `accepted` for its message. The held message is delivered once, in order with any later message to the same agent; a retry with the same `client_id`, including after a reconnect during the start, is not queued again and gets the `accepted` when the message is delivered. A message whose agent is not ready within two minutes is dropped with an `error` frame, code `agent_unavailable`. With no session at all the phone is on the session-control channel, where utterances are not sent; it starts the agent with `session_command` `start` and sends its queued message after `welcome`.

### Workspace feed

`workspace_command` with `action: "list"` asks the Mac for its Workspace and is answered with one `workspace_state`:

- `projects`: every registered project, `id` and `name`, in the order the Mac lists them, general-tasks included when it is registered.
- `tickets`: the open tickets the phone groups by lane: `id` (for example `RR-120`), `title`, `status` (`in_progress`, `queued` or `backlog`), `project_id` (an `id` from `projects`) and an optional owning `agent` slug.
- `error`: optional, why the lists are empty when the Mac could not read them.
- `truncated`: optional, `true` when the Mac held more open tickets than it sent.

Both lists are always present, even when empty. The feed is read-only: the phone cannot create, edit or dispatch a ticket.

**Source.** `RelayRemoteWorkspaceFeed` reads the daemon's program dashboard (`GET /v1/program/dashboard`, without its ready sweep), the same source the Mac's Workspace board reads, so the two agree. The lanes map one to one: the board's In progress lane (which includes verification-blocked tickets) is `in_progress`, Queued (ready, waiting on dependencies or a worker slot) is `queued` and Backlog is `backlog`. Done and cancelled tickets are never sent. A ticket is sent only under a registered project, matched by path.

**Owner.** `agent` is the slug of a running agent that wrote or dispatched the ticket, from the daemon's `GET /v1/agent-presence`; when two agents list it, the more recently active one. A ticket nobody is recorded against, one an agent that has since stopped worked on, and any ticket in general-tasks (which presence never records) carry no `agent`. A presence failure sends the list without owners rather than failing it.

**Pushes.** The `list` subscribes that phone's connection. While at least one phone is subscribed the Mac reads the board every 2 seconds and sends a fresh `workspace_state` to each subscriber whose last one differs, so a burst of changes is one push and an unchanged board sends none. The subscription ends when the phone disconnects; a phone that reconnects sends `list` again. The phone already accepts a `workspace_state` at any time.

**Limits.** At most 200 tickets are sent, newest activity first, each title cut to 120 characters, and the frame is kept under 60 KB (the line limit is 64 KB), dropping the oldest tickets first; either cut sets `truncated`. The Mac answers within 8 seconds: a workspace service that is not running, does not answer or fails is an otherwise empty `workspace_state` whose `error` says so ("Relay Runner's workspace service is not running on this Mac.", "The Mac's workspace service did not answer in time." or "The Workspace could not be read on this Mac right now."), with `projects` still listed.

**Privacy boundary.** Only the fields above leave the Mac. A ticket body, a description, a worker branch or activity line, a file path and a repository path are never sent, nor is the daemon's own error text, which can name a path. A Mac built before RR-535 answers every list with the RR-532 "not available" error and never pushes.

#### One ticket's text (RR-551)

`workspace_command` with `action: "get"`, a `project_id` (an `id` from `workspace_state.projects`) and a `ticket_id` asks for one ticket's text. It is answered with one `workspace_ticket` addressed to that connection alone: it does not subscribe the phone to pushes, and a body is never pushed. Both ids are optional in the codecs, as `session_command`'s are; a `get` without them is answered with an `error` ticket.

- `project_id`, `ticket_id`: the ticket asked for, always present.
- `title`, `status` (`in_progress`, `queued`, `backlog`, or `done` for a ticket that finished while the phone had it open) and `agent` (the owning agent's slug, when there is one): present when the ticket was found.
- `markdown`: the ticket's body, everything after its frontmatter, unchanged, at most 64 KB of UTF-8, cut on a character boundary. `truncated` is `true` when it was cut. JSON escaping can make a frame longer than its text, so the Mac cuts further when a 64 KB body would not fit in one 64 KB frame line; `truncated` says so either way.
- `error`: in place of `markdown` when the ticket cannot be served: "That project is not available on this Mac.", "That ticket no longer exists.", "That ticket could not be read on this Mac right now.", or, for the daemon, the same unreachable and timeout lines as the list. The reply is always a well-formed `workspace_ticket`, within 8 seconds.

**Source.** The Mac reads the ticket the way the desktop Workspace shows an open ticket (`ProgramTicketDetail`, the ticket file under the project's `.orchestrator/`), found on the program dashboard in the same lanes as the list plus Done. A ticket is served only when it is in a registered, available project and the `list` would expose it, or it is Done; a cancelled ticket, an unknown id and an unregistered project are errors.

**Privacy boundary (replaces RR-535's "no ticket bodies leave the Mac").** A body is sent only for the one ticket the phone asks for, and only for a ticket in a registered project that the list would also expose, or one that has since become Done. It is never in `workspace_state`, in the list or in a push. The frontmatter is not sent, and the Mac adds no filesystem or repository path. Text the ticket's author wrote in the body is sent as written, including any path they typed there. The daemon's own error text is still never passed on.

### Settings

`settings_command` with `action: "get"` reads the Mac's settings; `action: "set"` changes only the keys it carries and leaves the rest alone. Either is answered with one `settings_state`. The keys are:

| Key | Meaning | In `set` |
| --- | --- | --- |
| `speech_speed_percent` | The desktop TTS rate in hundredths: 130 is 1.3x. The phone's slider runs 50 to 200 in steps of 10. Integers keep the canonical encoding identical in Swift and Rust | yes |
| `provider` | The orchestrator provider, `codex` or `claude` | no, read-only from the phone |
| `model` | The orchestrator model, one of `model_options` | yes |
| `effort` | The orchestrator effort, one of `effort_options` | yes |
| `sizing` | The sub-agent sizing policy, one of `sizing_options` (`orchestrator_decides`, `user_default`) | yes |
| `agent`, `work_style` | One agent's work style (`auto`, `direct` or `orchestrated`), sent together. It is saved as the agent card's picker saves it (`[agents.<slug>] work_style`), applies from that agent's next request, and shows in its `session_state.agents` entry; `settings_state` does not carry it | yes |

`settings_state` also carries `model_options`, `effort_options` and `sizing_options`, each a list of `{value, label}` from the Mac's own catalogue for the current provider and model (`GeneralConfig` in `Config.swift`), so the phone never hard-codes it and a Mac update needs no phone update. A `set` the Mac refuses is answered with the unchanged values and an `error` saying why. Every field of `settings_state` is optional, so a Mac that cannot serve settings answers with only `error`. RR-536 applies each `set` through the same validation and save path as Relay App's `set_settings` (`RelayAppSettings.applying`, then `AppState.saveConfig`), so the Settings window and any running session react as they do to a change on the Mac, and a retried `client_id` re-applies the same values harmlessly.

**Validation.** Only `speech_speed_percent`, `model`, `effort`, `sizing`, `agent` and `work_style` are accepted; `provider`, or any other key, is refused (the Mac answers with a `settings_state` carrying an `error` and the unchanged values). Speech speed must be 50 to 200 in steps of 10 and is saved as the desktop rate (130 becomes 1.3). `model` must be one of `model_options` for the current provider. `effort` must be valid for the model in effect after the same `set`. Changing `model` alone keeps the effort when the new model has it and otherwise corrects it, as the desktop's model picker does, and the returned `effort_options` are those of the new model. `sizing` must be one of `sizing_options`. `work_style` needs a known `agent` and one of the three styles. A refused `set` saves nothing and is answered with the unchanged values and an `error`.

**Push.** While a phone is connected, the Mac sends an unsolicited `settings_state` whenever one of these values or option lists changes from a source other than that phone's own `set` (for example the Mac's Settings window or Relay App). The first check after startup only records a baseline.

### Kit client API

`ios/RelayRemoteKit` exposes the RR-532 frames to the iPhone app (RR-540, RR-543 and RR-544 build on these names):

- `RemoteSession.send(text:agent:)` and `send(control:agent:)` address a named agent; nil is the focused agent. A queued utterance keeps its agent when it is resent.
- `Frame.agent` is the agent any agent-addressed frame names, for frames from `onInbound` or `records`.
- `RemoteSession.agents` and `MacSessionStatus.agents` (with `agent(_:)`) publish the Mac's per-agent state; empty from a Mac that does not report it, and in `MacSessionStatus` while the Mac is not reached.
- `RemoteSession.requestWorkspace()` asks for the feed, which lands in `workspace`.
- RR-551: `RemoteSession.requestWorkspaceTicket(projectID:ticketID:)` asks for one ticket's text; the reply lands in `workspaceTickets` (keyed by `SessionCore.ticketKey`) and stays until `forgetWorkspaceTicket(projectID:ticketID:)`. `ticketUnsupported` is set by a Mac that rejects `get`. `WorkspaceTicketReading` turns the tapped row, the latest list and the reply into the modal's header and body states, and `MarkdownBlocks.parse` splits a body into headings, paragraphs, lists (with task items) and code blocks.
- `RemoteSession.requestSettings()` and `updateSettings(speechSpeedPercent:model:effort:sizing:)` read and change settings; the answer lands in `settings`, and a refusal's reason in `settingsError`, cleared by the next settings command.
- `send(sessionCommand: .start, projectID: nil, agent:)` starts in the general-tasks project.

Each returns false when no channel is up, so a request the user made earlier is not sent later; they work on a bridge channel and on a session-control channel alike.

### Session control

Relay Runner listens on `/tmp/relay_session_control.sock` whenever the app runs, with or without a session (RR-456). The socket is created mode 600, every connection's uid is checked with `getpeereid`, and its phone-side client is `relay-remote-shell`, which only a paired device's forced command runs. The same socket also carries [Relay App](relay-app.md)'s `app_command` lines (RR-459); a connection whose first line is `identify`, as every helper connection's is, is refused app commands, so a phone can only reach `session_command`.

- **Routing.** `relay-remote-shell --device` connects to `/tmp/relay_remote.sock` when a session's bridge listens, as before. When it does not, the helper connects to the session-control socket instead; the app answers the helper's `identify` with `session_state` and the project list, ignores `hello` and answers `ping`. While attached to a bridge, the helper opens the session-control socket on the phone's first app command (`session_command`, and since RR-532 `workspace_command` and `settings_command`) and sends every app command there, so Stop and the running project's name work from an attached session; without the app it answers `app_unavailable`. When neither socket listens the helper writes `session_state` with `app_running: false` and exits. An SSH failure remains "Mac unreachable" on the phone. The `status` and `--pair` modes never fall back.
- **Commands.** `list_projects` and `state` report. `start` with a registered, available `project_id` calls `AppState.newSession(workingDirectory:)` with that project's path, the path the Workspace Start button uses, without raising the Workspace; the session uses the Mac's provider, model and effort defaults and behaves exactly like one started on the Mac, including its voice-command authority. `stop` calls `AppState.endSession()`. RR-532: a `start` without `project_id` starts in the built-in general-tasks project, the project the Mac's own Start Session uses by default, and is otherwise the same as a start that names it; RR-534: while a session runs, a `start` naming an agent and no `project_id` starts that agent beside the running ones in the running project, as the Mac's "+" does; "Choose a project to start." remains only for a Mac whose registry cannot provide that project. A `start` while another project's session runs is refused with an `error` naming it; starting the running project again only reports it. RR-523: `start` carries an optional `agent` slug (`puck`, `isabella`, `george`, `sky`); a named agent not yet running in the project starts beside the running ones, and an unknown one is refused. A `start` without `agent`, from an older phone build, starts the most recently active agent, or Puck if none has run. `session_state` reports `active_agent` and `running_agents` (table order) while a session runs. `client_id` de-duplicates a retried command.
- **States.** `none`, then `starting` from the accepted start until the bridge's Relay Remote socket answers `status` with `running`, then `ready`; `failed` with an `error` when the app refuses the start or the session ends before it is ready. The app pushes each change to connected helpers once a second. A `stop` reports `none` at once.
- **Attach.** On a session-control channel, `ready` closes the channel and the phone reconnects at once, so the helper attaches to the new bridge and `hello` carries the Remote mode as usual. If the channel reports `ready` on arrival, the phone reconnects after its normal backoff instead. Utterances typed before the session existed stay queued and are sent after `welcome`. After each `welcome` the phone sends `session_command` `state` to learn the running project.

## Mac-side integration with the voice contract

| Surface | Current behavior and work required |
| --- | --- |
| Text ingress | The Mac microphone path writes newline-delimited text to `/tmp/voice_in.fifo` through `Sources/relay-runner/STT/FIFOWriter.swift`, and the bridge's FIFO select loop turns each line into a command. Remote utterances do not go through the FIFO: macOS pipes guarantee atomic writes only up to 512 bytes, and a long sentence could interleave with microphone text. `relay_remote.py` instead pushes each utterance onto a bridge-owned queue and wakes the same select loop through a pipe, so microphone and remote text share one ordering, one `relay_command_seq` counter and one handler. |
| Command metadata | `_begin_relay_command` in `services/voice_bridge.py` records seq, id, source text, receipt time and recovery generation, and `RelayCommandMetadata` in `services/pm_frontstage.py` carries seq, id, provider and source text. Neither has an origin field. Both gain `input_source` (`mac-mic`, `relay-remote`, `manual`) and `device_id`, written through to the spool `.meta` and the state file so the PM session and the reply path can see where a command came from. Existing readers ignore unknown keys. |
| Controls | The `__`-prefixed control map and dispatch in `voice_bridge.py` stay as they are. The remote module submits the mapped token for a `control` frame through the same queue, so a phone tap behaves exactly like the Mac hotkey. |
| Speech egress | The bridge constructs `SpeechCoordinator` with a Kokoro `tts_executor`. The coordinator gains a remote sink: when the command's `input_source` is `relay-remote`, or when a device is the active output device for lifecycle and messenger speech, `read_out` serializes the intent (`to_worker_payload()` subset) into a `speech` frame instead of playing it through the Mac's speaker; when remote audio is available the TTS worker then synthesises it in a synthesise-only mode and the coordinator streams each sentence as `speech_audio` parts (RR-457), `stop_playback` and skip become `speech_control` frames and cancel that synthesis, and the device's `ack` feeds `record_realization`. When the device is disconnected, speech is held in the replay buffer rather than spoken on the Mac, for up to the buffer window. |
| Mac microphone and speaker | `STTEngine.suspendForReferenceAudio()` already returns a token that silences `writeVoiceOutput` while a Settings voice preview plays. That becomes a reason-based suspension with a `remoteInput` reason. The bridge posts `remote_device` events on `/tmp/voice_state.sock`; `StateEventBus` hands them to `AppState`, which suspends the microphone while a phone is the active input and resumes it when the phone disconnects or the user takes over on the Mac. Kokoro synthesises remote-routed speech without the speech player, so no Mac audio device opens and `VoiceAudioLease` is untouched. |
| Status | The notch and menu bar show `Remote: <device name>` while a device is active, mirroring the existing recording state surfaces. |
| Keep-awake | While at least one device is connected the app holds a prevent-idle-system-sleep power assertion. A closed lid or a manual sleep still disconnects, and the phone says so. |
| Reply ownership | `services/relay_reply.py` and its foreground ownership checks are unchanged. The PM session replies exactly as today; routing happens after the coordinator accepts the reply. |
| Manual bridges | A manual `relay-bridge` session without the app has the bridge-owned socket and therefore remote ingress and egress, but no pairing, no microphone gate and no status; pairing requires the app. |

## iOS app

**Transport.** swift-nio-ssh over swift-nio-transport-services, which is the Network.framework-backed event loop iOS needs. The client opens one exec channel per connection and writes utterance frames to the channel's stdin side. Host key validation is a custom validator that accepts only the fingerprints pinned at pairing; the `.acceptAnything()` validator in library examples is never used. Citadel is an optional convenience layer whose `executeCommand` variants expose stdin only with a PTY, which `restrict` forbids, so if Citadel is used at all it is for connection management while the exec channel is driven with swift-nio-ssh directly.

**Keys.** The permanent device key is a Secure Enclave P-256 key wrapped by `NIOSSHPrivateKey(secureEnclaveP256Key:)`; the private key never leaves the phone and the public key is exported in OpenSSH `ecdsa-sha2-nistp256` form for `authorized_keys`. A Keychain-stored Ed25519 key is the fallback where the Secure Enclave is unavailable, such as the simulator.

**Screens (RR-532 to RR-551).** The shipped app follows `docs/design/relay-remote-ios/README.md`. First launch walks splash, permissions (microphone, local network, camera, notifications), pairing (scan or paste, then compare the Mac's fingerprint) and a tutorial on the real dock; later launches open the app, or pairing when the phone is not paired. The app has three tabs. **Agents** has a tab per agent (Puck, Isabella, George, Sky), each with its own chat, glyph state and dock (message field, Talk, Stop, Replay). **Workspace** lists the Mac's open tickets by lane, filtered by project, and opens one in a modal that reads its text. **Settings** has Voice, Orchestrator, Mac and Pairing sections. There is no debug screen, no hands-free mode, no project picker and no page title on Workspace or Settings: the phone starts a session by messaging a stopped agent (a `start` frame with no project, which the Mac sends to general-tasks) and switches nothing else. The debug-launch arguments that reach each screen are listed in `ios/README.md`.

**Speech.** Two candidates per direction, chosen by the engine spike below. Since RR-457 the phone plays the Mac's own voice, so the TTS candidates only speak text frames that carry no audio:

| Direction | Candidate | Notes |
| --- | --- | --- |
| STT | FluidAudio Parakeet TDT v3, Parakeet EOU (streaming, end-of-utterance), or Phonon-2 | Same vendor and model family as the Mac, so vocabulary and punctuation behave alike; iOS 18 baseline for newer models; model download on first run |
| STT | Apple `SpeechAnalyzer` with `SpeechTranscriber` | On device, no model download, iOS 26 minimum, no custom vocabulary |
| TTS | `AVSpeechSynthesizer` | No model download, well-behaved with the audio session and lock screen, voice differs from the Mac's Kokoro |
| TTS | FluidAudio Kokoro on iOS | Superseded by RR-457: the Mac streams its own voice. FluidAudio states physical-iOS inference for its Kokoro ANE path is unvalidated |

**Playback (RR-458).** `SpeechPlaybackQueue` in RelayRemoteKit plays an `audio: true` frame through `AudioQueueSpeechPlayer` (`AudioFileStream` parses the ADTS slices, cut anywhere, and one `AudioQueue` per reply decodes and plays them gaplessly), appending parts in part order as they arrive and acknowledging the frame once after the stream has played. If no audio reaches it within 5 s of the frame's turn (the Mac can take about 3 s to voice the start of a long reply), or the Mac's stream ends with an empty final part before any audio, or the player cannot decode it, the phone speaks the text with `AVSpeechSynthesizer` and logs it. A stream that delivers nothing new for 15 s ends with what it has and is acknowledged `played: false`, as is one ended by an empty final part after some audio. The queue reports idle, buffering (waiting for the first audio) and playing for the state label. A persisted Playback setting chooses **Auto-play** (default) or **Play on demand**: on demand, replies wait unplayed and unacknowledged, the screen shows the newest one with a Play button, and Play plays it and acknowledges older waiting replies `played: false`. Stop, Cancel and starting to talk silence the player as they silence the synthesizer, and Replay plays the replayed reply at once in either mode. While a reply's audio is incomplete the reconnect `resume_after_seq` sits one below that frame, so a drop mid-reply replays it with its parts and the queue drops what it already has.

**Foreground and background.** The app is designed as foreground-first with resume. It uses the audio background mode only while it is genuinely recording or playing, which keeps the connection alive during a long spoken reply with the screen locked. Apple's guidance and developer reports agree that arbitrary sockets do not survive suspension, so the client expects disconnects and relies on `resume_after_seq` plus idempotent `client_id` retries rather than on a permanently open socket. Nothing in the design depends on background execution beyond audio playback, except the opt-in Reply notifications below.

**Reply notifications (RR-545).** Local notifications only: no APNs, no push service and no cloud relay. With the phone's Reply notifications preference on and iOS notification permission granted, leaving the foreground holds the audio session (`playback` mixed with other audio, playing silence) so the app keeps running and keeps the channel to the Mac open. Each agent reply that ends while the app is not in the foreground posts one local notification: the title is the agent's name, the body the reply's `speech` frames for one `relay_command_seq` joined and trimmed, threaded per agent. Tapping it opens that agent's chat. Whether the reply is also spoken follows Remote mode and the Replies setting as before. If the connection drops in the background and the normal reconnects fail, the phone posts "Lost connection to your Mac. Open to reconnect." once, releases the audio session and stops reconnecting until it is opened. With the preference off or permission denied the phone backgrounds as described above. Accepted trade-offs: nothing arrives after the app is swiped away, killed or the phone reboots, and battery use is higher while the app waits in the background. The Mac and the wire protocol are unchanged.

**Discovery and permissions.** On the home network the app browses Bonjour for `_ssh._tcp`, which macOS Remote Login advertises, filtered to the paired Mac's host name, so no Relay-owned advertiser is needed. This requires `NSLocalNetworkUsageDescription` and `NSBonjourServices` containing `_ssh._tcp` in the app's Info.plist, plus the microphone and camera usage strings. There is no speech-recognition usage string: `SpeechTranscriber` runs on device and needs only the microphone permission, and nothing in the app uses `SFSpeechRecognizer` (RR-538; confirm once on a device). Away from home the app connects to the paired tailnet name or address.

**Project layout.** The iOS app lives in this repository under `ios/` as a committed Xcode project, because an iOS app target cannot be expressed in the root SwiftPM package. Shared frame code lives in the SwiftPM `RelayRemoteProtocol` target so `swift build` and `swift test` on macOS keep covering it, and the iOS project depends on the repository package locally. A separate repository is the alternative; the single board and shared protocol tests argue for one repository.

## Reachability

- **Home Wi-Fi.** Direct connection to the Mac's port 22 via Bonjour discovery. Requires Remote Login enabled for the user and the Mac awake with the user logged in.
- **Away from home, recommended.** Tailscale on both devices. Plain `sshd` over the tailnet works unchanged and `authorized_keys` is untouched; Tailscale SSH itself is not used, and the App Store and GUI Mac builds cannot host it anyway. Tailscale relays carry only encrypted WireGuard traffic. The phone's Tailscale app must have the tunnel up before Relay Remote connects.
- **Away from home, unmanaged alternative.** Router port forward with dynamic DNS to the Mac's port 22. Only acceptable with password and keyboard-interactive authentication disabled in `sshd`; carrier-grade NAT makes it impossible for many home connections. Documented, not recommended.
- **Sleep.** A sleeping Mac drops every path. The keep-awake assertion covers an idle Mac while a phone is connected; Energy settings or `caffeinate` cover the rest, and the docs say so plainly.

## Security model

- Authentication is public-key only for Relay's keys. Each device key is bound to `command="<shim> --device <device_id>",restrict`, so even a stolen phone key yields one program, no shell, no PTY, no forwarding. Device identity comes from the `authorized_keys` line that `sshd` matched, never from anything the phone claims.
- The host key is pinned at pairing. There is no trust-on-first-use path in the client.
- `/tmp/relay_remote.sock`, `/tmp/relay_remote_pair.sock` and `/tmp/relay_session_control.sock` are mode 600 and the listeners verify the peer's uid with `getpeereid`; the forced command runs as the login user, so the check passes without any secret in the environment. The session-control socket starts and stops sessions only through the app's own Start and End Session paths.
- Pairing keys expire by `expiry-time=` and are removed on completion; a permanent key is installed only after a click on the Mac that shows the device's fingerprint.
- Relay never prints key material, tokens or fingerprints into logs, run logs or tickets. The QR payload is rendered once and is not persisted.
- Enabling Remote Login exposes `sshd` password authentication for the Mac user by default. Relay Remote does not need it. The user guide shows the one-time, administrator-run drop-in `/etc/ssh/sshd_config.d/01-relay-remote.conf` with `PasswordAuthentication no` and `KbdInteractiveAuthentication no`, notes that macOS upgrades can reset `/etc/ssh/sshd_config` but keep the drop-in directory, and recommends leaving "Allow full disk access for remote users" off. The app does not edit `/etc`.
- Privacy posture per `docs/privacy.md`: utterance and reply text transit only the user's SSH tunnel between the phone and the Mac. No new data leaves the Mac to any third party; the provider sees the same text it sees from the Mac microphone.

## Provider parity

Codex and Claude receive the same remote utterances, the same command metadata with `input_source` and `device_id`, the same reply ownership rules and the same speech routing; the PM session cannot tell a phone turn from a microphone turn except by reading that metadata. Provider differences are limited to the existing provider CLI registration and data policies; nothing in Relay Remote is provider-specific.

## Verified upstream inputs

| Input | Candidate pin / constraint |
| --- | --- |
| [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) | Main at commit `149f32ffacda5770e513cb41bd175e3d6ef77ce3` on 22 October 2026. `Sources/NIOSSH/Keys And Signatures/NIOSSHPrivateKey.swift` offers Ed25519, P-256, P-384, P-521 and `SecureEnclave.P256` initializers. Exec, shell and subsystem channels, `direct-tcpip` and remote forwarding, public-key and password authentication. Releases 0.13.0 and 0.14.0 target Swift 6.1. Apple describes it as building blocks rather than a finished client; Swift Forums threads report channel reuse and close edge cases on iOS that the transport ticket must exercise. |
| [Citadel](https://github.com/orlandos-nl/Citadel) | MIT, latest release seen 0.7.2 (April 2024). `executeCommand`, `executeCommandPair`, `executeCommandStream`, `createDirectTCPIPChannel`, jump hosts, reconnect option. Writable stdin only through `withPTY` or `withTTY`. README host-key example is `.acceptAnything()`. Optional dependency only. |
| OpenSSH on the inspected Mac | OpenSSH_10.3p1, LibreSSL 3.3.6, macOS 27.0.1 (26A434); `/etc/ssh/sshd_config.d/` holds only `100-macos.conf`. `authorized_keys` options `command=`, `restrict`, `expiry-time=`, `from=`, `permitopen=` and the `SSH_ORIGINAL_COMMAND` contract per the OpenBSD `sshd(8)` manual. |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Pinned in `Package.swift` at `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7`. Supports macOS and iOS; Parakeet TDT v3, Parakeet EOU streaming, Phonon-2 for STT; Kokoro 82m and others for TTS with the note that physical-iOS inference for the Kokoro ANE path is unvalidated; newer models require macOS 15 or iOS 18. |
| Apple Speech | `SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber` and `SpeechDetector` are on device and require iOS 26; custom vocabulary remains an `SFSpeechRecognizer` feature. |
| iOS background execution | Apple Developer Forums threads 750136, 841760, 792235, 840808, 841590, 709953 and 799259: sockets do not survive suspension, the audio background mode keeps a process alive only while audio is actually running, and listening sockets should close on background. |
| Tailscale | KB 1065: App Store and GUI Mac builds cannot host Tailscale SSH; plain `sshd` over the tailnet works unchanged. |
| Relay entitlements | `scripts/relay-runner.entitlements` grants audio input and Apple Events only; no App Sandbox, so the app can manage `~/.ssh/authorized_keys`. |

No iOS code, SSH prototype or model inference was run while preparing this spec. Library claims come from the pinned sources above; Relay behavior claims come from the inspected commit.

## Open questions

- Which iOS STT engine ships first: FluidAudio for vocabulary parity with the Mac, or `SpeechAnalyzer` for zero model download at the cost of an iOS 26 minimum. The engine spike decides.
- How first-audio latency for the Mac's streamed voice compares on Wi-Fi, Tailscale and cellular; `remote_audio_latency` in the speech latency report records it per reply. Kokoro on the iPhone is no longer needed for voice parity.
- How long an exec channel actually survives with the screen locked while audio is playing, measured on a physical device, and whether the audio session interruption path reconnects cleanly.
- Whether per-command routing (reply to the device that asked) or per-session routing (one active output device) feels right when the user moves between phone and Mac mid-conversation. The spec starts with per-command routing for replies and active-device routing for lifecycle speech.

## Verification targets

- Protocol codec round-trips, replay trimming and `client_id` dedupe pass identical golden vectors in Swift and Rust tests, including the RR-532 vectors in `frames_extended.json` and `invalid.json`.
- The `authorized_keys` writer is idempotent against a temporary `HOME`, never touches foreign lines, and refuses unsafe permissions.
- Remote utterances carry `input_source` and `device_id` through `_begin_relay_command`, the spool `.meta` and the state file, in order with microphone utterances.
- The coordinator's remote sink records realization from device `ack` frames, keeps the Mac's speaker closed for remote-routed speech while streaming its synthesised audio, and cancels that synthesis on every stop, with the speech event log showing the sink and first-audio latency.
- A per-user `sshd -D -f <temporary config> -p <high port>` with a temporary host key and `authorized_keys` runs the real helper end to end on a Mac, with no privileged setup.
- On a physical iPhone: pair by QR, send an utterance, hear the reply in the Mac's voice, lock the phone during a reply, reconnect and receive the replayed frames; repeat over Tailscale from cellular.
- RR-551: the Swift and Rust codecs share the `get` and `workspace_ticket` vectors, valid and invalid; the app tests cover a `get` answered with the body and no frontmatter, a body over the cap cut on a character boundary and marked `truncated`, a body that escapes large still fitting one frame, the error replies (unknown project, unknown ticket, daemon unreachable or silent), the list still carrying no body, and, through the real socket, a `get` answered without subscribing the phone; the helper test covers `get` reaching the app and `workspace_ticket` coming back; the kit tests cover the round trip, an older Mac's refusal, the modal's header and body states and the Markdown mapping.
- RR-535: the app tests cover the lane mapping, owners, the 200-ticket cap with `truncated`, the frame budget, the privacy boundary (no body, branch, activity or path in the frame), the error replies for an unreachable and an unanswering daemon, and, through the real session-control socket, a `list` answered and a burst of board changes pushed once. The Swift and Rust codecs share the `truncated` vectors.
- RR-532: the kit tests cover sending to a named agent, agent-tagged speech, per-agent state updates, a Workspace round trip and settings get and set including a refused set against the scripted Mac; the app tests cover each new command reaching its own handler with a well-formed reply and a start without a project; the helper test covers the new commands reaching the app beside a bridge; the bridge test covers an agent-tagged utterance and control being delivered as before.
- RR-534: the bridge tests cover an agent-tagged item reaching the bridge with its agent, an unknown agent refused, tagged `accepted`, `speech`, `speech_audio` and scoped `speech_control` frames, and a held message to a stopped agent being started, delivered once when ready and in order, or expired; the speech service tests cover session keys on remote frames and session-scoped stops and skips that leave another session's frames alone; the app tests cover `agents` through off, starting, ready, working, playing and ready pushed without a poll, a background agent's own turn, a start naming an agent and no project beside a running session, the bridge's start request and the `__FOCUS__` `ready` flag.
- Session control (RR-456): unit tests cover the app handler, the helper's socket order and the codec vectors, and a kit loopback test runs the real helper against a scripted session-control socket that brings up the real bridge module. On a physical iPhone, with Relay Runner running and no session: the phone lists the Mac's projects, Start shows starting then ready, the phone attaches by itself and a typed or spoken request is answered, Stop ends the session on the Mac, and with Relay Runner quit the phone says it is not running.

Push notifications, a hosted relay, multi-user access, remote screen viewing or control, audio from the phone to the Mac, streaming of the Mac's microphone or speaker output, choosing the provider from the phone and waking a sleeping Mac are not capabilities of this proposal. Choosing the orchestrator model, effort and sub-agent sizing and the speech speed from the phone is in scope since RR-532 ([Settings](#settings)). Push notifications stay out; while the app is alive in the background with its audio session active it posts local notifications for replies instead.

## Proposed ticket breakdown

Draft only. None of these exist on the board yet. Once the spec is agreed they are created through the canonical ticket writer in `backlog`, refined, and promoted to `ready` one wave at a time: wave one is tickets 1 to 3 in parallel, wave two is 4, 6 and 9, wave three is 5, 7 and 8, wave four is 10 and 11. Nothing past wave one should be promoted before both spikes have reported. Sizing follows the worker-sizing rules in `CLAUDE.md`; every ticket is provider-neutral with `worker_provider_notes: none` unless noted.

### 1. Spike: iOS SSH transport decision

Read-only review of swift-nio-ssh and swift-nio-transport-services at pinned commits, Citadel, and Apple's background-execution documentation, answering: how an exec channel with writable stdin is opened without a PTY; which host-key validation hook to implement for fingerprint pinning; how the public half of `NIOSSHPrivateKey(secureEnclaveP256Key:)` is exported in OpenSSH `ecdsa-sha2-nistp256` form; whether Citadel adds anything over the raw library; and what the `direct-tcpip` fallback would cost on both sides.

- Mode: `spike`. No prototype; the writable prototype is ticket 9.
- Depends on: none.
- Sizing: `balanced` / `high`. Source and documentation reading only, but the answer fixes the channel shape for tickets 6 and 9.
- Done when: a structured report with pinned evidence recommends exec or `direct-tcpip`, names the APIs for each question above, and lists the iOS channel edge cases ticket 9 must test for.

### 2. Spike: iOS speech engine selection

Read-only comparison of FluidAudio on iOS (Parakeet TDT v3, Parakeet EOU, Phonon-2; Kokoro and PocketTTS; minimum OS per model; model download sizes; upstream statements about physical-device validation) against Apple `SpeechAnalyzer` with `SpeechTranscriber` and `AVSpeechSynthesizer`, with the Mac's current FluidAudio pin as the parity baseline.

- Mode: `spike`.
- Depends on: none.
- Sizing: `balanced` / `medium`. Bounded comparison with public evidence.
- Done when: the report recommends a first-ship STT engine, a TTS engine and a deployment target (iOS 18 or iOS 26), and names the parity gaps against the Mac path, each backed by pinned evidence.

### 3. RelayRemoteProtocol shared frame schema

Add a `RelayRemoteProtocol` SwiftPM library target (macOS 14, iOS 18) and a Python twin `services/relay_remote_protocol.py` implementing the frames in the wire protocol section: codec, the 64 KiB frame limit, per-device `seq`, `client_id` dedupe, and the replay buffer with trimming on `ack`. Golden JSON vectors live in one place and both test suites consume them.

- Mode: `implementation`.
- Depends on: none.
- Sizing: `balanced` / `medium`. Well-specified data code with tests on both sides and no runtime integration.
- Done when: `swift test` and the Python tests pass the same vectors, including resume-after-seq, dropped-window and duplicate `client_id` cases.

### 4. Bridge remote session module

Add `services/relay_remote.py`, owned by `voice_bridge.py`: the `/tmp/relay_remote.sock` listener with a peer-uid check, device sessions keyed by the `--device` id the helper passes, an ingress queue that wakes the existing FIFO select loop, `input_source` and `device_id` carried through `_begin_relay_command`, the spool `.meta`, the state file and `RelayCommandMetadata`, and `control` frames mapped to the existing `__` tokens. Microphone ordering is preserved and existing readers ignore the new fields.

- Mode: `implementation`.
- Depends on: 3.
- Sizing: `strong` / `high`. Touches command identity and ordering in the bridge, the highest blast radius in the voice path.
- Done when: a scripted device over the socket produces commands interleaved in order with FIFO text, the new fields appear in `.meta` and the state file, and the existing bridge tests pass unchanged.

### 5. SpeechCoordinator remote sink

Give `SpeechCoordinator` a per-device sink: `read_out` for remote-originated commands, and lifecycle and messenger speech for the active device, become `speech` frames instead of calls into the Kokoro executor; stop and skip become `speech_control` frames; device `ack` feeds `record_realization`; frames are held in the replay buffer while the device is disconnected; Kokoro is never started for remote-routed speech.

- Mode: `implementation`.
- Depends on: 4.
- Sizing: `strong` / `high`. Freshness, superseding and realization semantics are subtle and already under test; every existing coordinator test must stay green.
- Done when: coordinator tests cover remote routing, suppression on a newer command, ack-driven realization and disconnect buffering, and the speech event log names the sink.

### 6. relay-remote-shell forced-command helper and packaging

New Swift executable target: `--device <id>` mode copying NDJSON between stdin/stdout and `/tmp/relay_remote.sock`, `--pair <id>` mode for `/tmp/relay_remote_pair.sock`, an allow-listed `status` read from `SSH_ORIGINAL_COMMAND`, frame-size enforcement, a structured `error` frame when no socket is listening, and exit when either side closes. Embed and sign it in `scripts/build-dmg.sh` next to the existing SharedSupport launchers.

- Mode: `implementation`.
- Depends on: 3.
- Sizing: `balanced` / `medium`. Small single-purpose binary with a clear contract; the packaging step has precedent in the DMG script.
- Done when: unit tests cover both modes against a fake socket, the DMG build contains the signed helper, and a per-user `sshd -D -f <temporary config>` on a high port runs the helper end to end against a fake socket server without privileged setup.

### 7. Pairing flow and authorized_keys management

Settings section in the app: Remote Login detection via the SSH banner on loopback and a deep link to System Settings; QR pairing with an ephemeral Ed25519 key installed with `command="... --pair"`, `restrict` and `expiry-time=`; the `/tmp/relay_remote_pair.sock` listener; a confirmation sheet showing device name and key fingerprint; an atomic `~/.ssh/authorized_keys` writer scoped to `relay-remote:<device_id>` marker lines, creating `~/.ssh` as 700 and the file as 600 and refusing unsafe modes; unpair; the optional `from=` restriction; and the per-user shim at `~/Library/Application Support/relay-runner/bin/relay-remote-shell` rewritten at launch.

- Mode: `implementation`.
- Depends on: 6.
- Sizing: `strong` / `high`. Writes under `~/.ssh`, security-sensitive, and the UI must follow the RelayMotion conventions.
- Done when: writer tests against a temporary `HOME` prove idempotence, foreign-line preservation and permission refusal; a scripted phone completes pairing over the temporary `sshd` from ticket 6; the QR payload is never logged or persisted.

### 8. Mac microphone gate, status and keep-awake

The bridge posts `remote_device` active, inactive and disconnected events on `/tmp/voice_state.sock` as the phone's Remote mode switch changes (RR-454); `AppState` suspends the microphone through a reason-based extension of `suspendForReferenceAudio` while a phone is active and resumes on inactive, disconnect or user takeover; the notch and menu bar show `Remote: <device>` while Remote mode is active; a prevent-idle-sleep assertion is held only while Remote mode is active.

- Mode: `implementation`.
- Depends on: 4.
- Sizing: `balanced` / `medium`. Follows existing event and suspension patterns.
- Done when: tests cover the suspend and resume transitions and the assertion lifecycle, and the status surfaces animate per the motion kit.

### 9. iOS app skeleton and SSH transport

Create `ios/` with an Xcode project depending on the repository package for `RelayRemoteProtocol`; swift-nio-ssh over swift-nio-transport-services; the pinned host-key validator; a Secure Enclave P-256 device key with Keychain Ed25519 fallback; one exec channel with `hello`, `resume_after_seq`, reconnect with backoff and `client_id` retry; QR scan pairing; Bonjour `_ssh._tcp` discovery filtered to the paired host; Info.plist usage strings and `NSBonjourServices`; and a text-only debug screen that sends an utterance and shows frames before speech exists. (Shipped: the debug screen was replaced by the final design's screens in RR-533 to RR-546 and removed.)

- Mode: `implementation`.
- Depends on: 1, 3. Pairing end to end also needs 7.
- Sizing: `strong` / `xhigh`. A new platform target, a networking library with known iOS edge cases, key handling and background behavior in one ticket.
- Required inputs: confirmation that the app lives in this repository under `ios/`; an Apple Developer team for device signing; a physical iPhone and a Mac with Remote Login enabled for verification.
- Done when: simulator tests cover codec, reconnect and resume; on a physical iPhone the debug screen pairs, sends text, receives frames, survives lock and unlock with resume, and reconnects over Tailscale from cellular.

### 10. iOS speech integration

Wire the engines chosen by ticket 2: on-device STT with end-of-utterance detection feeding `utterance` frames; TTS speaking `speech` frames in `seq` order and answering `ack` with `played`; `speech_control` stop and skip; audio session configuration with the audio background mode only while recording or playing; push-to-talk and hands-free modes; controls for stop, replay and cancel. (Shipped: Hold and Toggle talk modes; the hands-free mode was dropped from the final design in RR-540.)

- Mode: `implementation`.
- Depends on: 2, 9, and 5 on the Mac side.
- Sizing: `strong` / `high`. Audio session and interruption handling on a real device dominate the effort.
- Required inputs: a physical iPhone for latency and audio-session verification.
- Done when: a spoken request on the phone produces a spoken reply from the Mac session with the Mac silent, and interruption, lock-screen playback and reconnect with replay behave as the wire protocol section states.

### 11. End-to-end Mac verification and user guide

A repeatable loopback test that starts a per-user `sshd` with a temporary config, host key and `authorized_keys`, runs the real helper, bridge module and coordinator sink with a scripted device, and asserts the full accepted, speech and ack cycle; plus `docs/relay-remote.md` for users covering Remote Login, the administrator drop-in that disables password authentication, Tailscale setup, the port-forward caveats, sleep behavior and unpairing.

- Mode: `implementation`.
- Depends on: 5, 7, 8.
- Sizing: `balanced` / `medium`. Assembly and documentation over finished parts.
- Done when: the loopback test runs in CI without privileges and the guide is linked beside the other feature docs.
