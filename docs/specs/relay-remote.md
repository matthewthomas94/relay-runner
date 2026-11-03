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

- No hosted relay, account, push notification service or Relay-operated server. Push notifications would require a server and are out of scope.
- No audio from the phone to the Mac: the phone sends text only. From the Mac to the phone, audio is limited to synthesised reply speech (RR-457 retired the earlier text-only rule for that direction). The Mac's microphone and speaker output are never streamed.
- No remote screen viewing or screen control from the phone. Relay Actions and Relay Vision remain Mac-local.
- No choice of provider, model or effort from the phone, and no switching projects while a session runs. The phone attaches to a running session, or starts one for a registered project when none is running (RR-456, [Session control](#session-control)); that session uses the Mac's current defaults, and starting a different project is refused until the running one is stopped.
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
  Relay Runner.app
     - pairing UI, authorized_keys writer, /tmp/relay_remote_pair.sock
     - microphone and speaker gate while a remote device is active, status, keep-awake
     - session control: /tmp/relay_session_control.sock while the app runs
```

| Component | Lives in | Responsibility |
| --- | --- | --- |
| Relay Remote iOS app | new `ios/` project in this repo plus a shared SwiftPM protocol target | Capture speech, transcribe on device, hold the SSH connection, play the Mac's reply audio or speak text frames that carry none, pair and store the device key |
| `relay-remote-shell` | new Swift executable target, embedded and signed by `scripts/build-dmg.sh` | The forced command. Copies NDJSON between the SSH channel and the bridge socket, or the session-control socket when no bridge listens; enforces frame limits, exits when either side closes |
| `services/relay_remote.py` | Python module imported by `services/voice_bridge.py` | Owns `/tmp/relay_remote.sock`, device sessions, sequence numbers and the replay buffer; feeds utterances into the bridge's ingress; is the `SpeechCoordinator` remote sink |
| Pairing and gate | `Sources/relay-runner` | Pairing flow and `~/.ssh/authorized_keys` management, Remote Login detection, suspending the Mac microphone and Kokoro output while a phone is active, status in the notch and menu bar, no-idle-sleep assertion |
| `RelayRemoteProtocol` | SwiftPM library target (macOS 14, iOS 18) with a Python twin | Frame schema, codec and golden test vectors shared by the helper, the iOS app and the bridge |

**Why the bridge owns the device session.** `services/voice_bridge.py` already owns command identity (`_begin_relay_command`), the intent inbox, the claim and state files, and the `SpeechCoordinator` that decides what is spoken and when. Putting the remote session next to those keeps one ordering of commands and one freshness policy. The Swift app owns only what needs the UI or the user's home directory: pairing, the authorized-keys file, the microphone gate and status.

**Why a separate helper rather than pointing `command=` at Python.** The forced command runs under `sshd` with none of the app's environment, so it must find the socket deterministically, start fast, and fail with a structured error when no session is running. A small Swift binary bundled with the app does that without depending on the Python virtual environment being resolvable from an SSH login. The `authorized_keys` line points at a stable per-user shim, `~/Library/Application Support/relay-runner/bin/relay-remote-shell`, that the app rewrites at launch to exec the binary inside the current bundle, so moving or updating the app does not break paired devices.

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
{"type":"utterance","client_id":"...","text":"move RR-120 to ready","captured_at":"2026-10-22T09:14:03Z"}
{"type":"control","client_id":"...","action":"stop"}           stop | interrupt | cancel | play | replay
{"type":"remote_mode","client_id":"...","enabled":false}
{"type":"session_command","client_id":"...","action":"start","project_id":"..."}   list_projects | start | stop | state
{"type":"ack","seq":44,"played":true}
{"type":"ping","t":1761124443}

Mac -> phone
{"type":"welcome","protocol":1,"session_state":"running","server_seq":44,"resumed_from":41,"dropped":false}
{"type":"accepted","client_id":"...","relay_command_seq":812,"relay_command_id":"4711-1761124443123456789-812"}
{"type":"speech","seq":45,"kind":"handoff","source":"messenger","text":"Looking at RR-120 now.","relay_command_seq":812}
{"type":"speech","seq":46,"kind":"final","source":"orchestrator","text":"RR-120 is in ready and dispatching.","relay_command_seq":812,"spoken_by":"phone","audio":true}
{"type":"speech_audio","seq":46,"part":0,"parts":0,"format":"aac","sample_rate":24000,"data":"//FgQB/7/N4CAExhdmP+vw=="}
{"type":"speech_audio","seq":46,"part":1,"parts":2,"format":"aac","sample_rate":24000,"data":"//FgQAuf/CEQBA==","last":true}
{"type":"speech_control","seq":47,"action":"stop","reason":"superseded"}
{"type":"status","seq":48,"text":"worker RR-120 started"}
{"type":"error","code":"no_session","message":"Relay Runner is not running a session"}
{"type":"pong","t":1761124443}
{"type":"session_state","app_running":true,"session":"none","projects":[{"project_id":"...","display_name":"relay-runner","availability":"available"}]}
{"type":"session_state","app_running":true,"session":"ready","project_id":"...","project_name":"relay-runner"}
{"type":"session_state","app_running":false,"session":"none"}
```

- `accepted` is the phone's receipt that an utterance entered the intent inbox, the remote equivalent of the notch's visual receipt. The phone shows it; it does not speak it.
- `speech` mirrors `SpeechIntent` from `services/speech_coordinator.py`: the same `kind` values (`handoff`, `progress`, `clarification`, `final`, `fallback`, `control`) and `source` values (`messenger`, `orchestrator`, `lifecycle`, `completion`, `fallback`). With `audio: true` the Mac's voice for that text follows in `speech_audio` frames and the phone plays it; with `audio: false`, or no `audio` key, the phone speaks the text with its own synthesizer. Either way the phone answers `ack` with `played` once the frame has played, so the coordinator's realization record and played coverage stay truthful.
- `speech_audio` (RR-457) carries the Mac's voice for the `speech` frame whose `seq` it repeats. The TTS worker synthesises each sentence with the configured voice (Kokoro, or a custom voice through the conversion runtime with the usual Kokoro fallback), encodes it with `afconvert` as AAC-LC, 24 kHz mono, 48 kbps constant bit rate, in ADTS framing (about 6.3 KB/s measured on Kokoro speech), and the coordinator sends it before the next sentence is synthesised. The parts of one seq are consecutive slices of one ADTS stream, numbered from 0, each at most 32 KiB of base64, so every frame stays well inside the 64 KiB line limit. `parts` is 0 until the final sentence is encoded and then the total, and the final part carries `last: true`. Each sentence is encoded on its own, so encoder priming and padding add up to about 130 ms of silence per sentence. `opus` is accepted by the codecs but not sent today.
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

### Session control

Relay Runner listens on `/tmp/relay_session_control.sock` whenever the app runs, with or without a session (RR-456). The socket is created mode 600, every connection's uid is checked with `getpeereid`, and its only client is `relay-remote-shell`, which only a paired device's forced command runs.

- **Routing.** `relay-remote-shell --device` connects to `/tmp/relay_remote.sock` when a session's bridge listens, as before. When it does not, the helper connects to the session-control socket instead; the app answers the helper's `identify` with `session_state` and the project list, ignores `hello` and answers `ping`. While attached to a bridge, the helper opens the session-control socket on the phone's first `session_command` and sends every `session_command` there, so Stop and the running project's name work from an attached session; without the app it answers `app_unavailable`. When neither socket listens the helper writes `session_state` with `app_running: false` and exits. An SSH failure remains "Mac unreachable" on the phone. The `status` and `--pair` modes never fall back.
- **Commands.** `list_projects` and `state` report. `start` with a registered, available `project_id` calls `AppState.newSession(workingDirectory:)` with that project's path, the path the Workspace Start button uses, without raising the Workspace; the session uses the Mac's provider, model and effort defaults and behaves exactly like one started on the Mac, including its voice-command authority. `stop` calls `AppState.endSession()`. A `start` while another project's session runs is refused with an `error` naming it; starting the running project again only reports it. `client_id` de-duplicates a retried command.
- **States.** `none`, then `starting` from the accepted start until the bridge's Relay Remote socket answers `status` with `running`, then `ready`; `failed` with an `error` when the app refuses the start or the session ends before it is ready. The app pushes each change to connected helpers once a second. A `stop` reports `none` at once.
- **Attach.** On a session-control channel, `ready` closes the channel and the phone reconnects at once, so the helper attaches to the new bridge and `hello` carries the Remote mode as usual. If the channel reports `ready` on arrival, the phone reconnects after its normal backoff instead. Utterances typed before the session existed stay queued and are sent after `welcome`. After each `welcome` the phone sends `session_command` `state` to learn the running project.

## Mac-side integration with the voice contract

| Surface | Current behavior and work required |
| --- | --- |
| Text ingress | The Mac microphone path writes newline-delimited text to `/tmp/voice_in.fifo` through `Sources/relay-runner/STT/FIFOWriter.swift`, and the bridge's FIFO select loop turns each line into a command. Remote utterances do not go through the FIFO: macOS pipes guarantee atomic writes only up to 512 bytes, and a long sentence could interleave with microphone text. `relay_remote.py` instead pushes each utterance onto a bridge-owned queue and wakes the same select loop through a pipe, so microphone and remote text share one ordering, one `relay_command_seq` counter and one handler. |
| Command metadata | `_begin_relay_command` in `services/voice_bridge.py` records seq, id, source text, receipt time and recovery generation, and `RelayCommandMetadata` in `services/pm_frontstage.py` carries seq, id, provider and source text. Neither has an origin field. Both gain `input_source` (`mac-mic`, `relay-remote`, `manual`) and `device_id`, written through to the spool `.meta` and the state file so the PM session and the reply path can see where a command came from. Existing readers ignore unknown keys. |
| Controls | The `__`-prefixed control map and dispatch in `voice_bridge.py` stay as they are. The remote module submits the mapped token for a `control` frame through the same queue, so a phone tap behaves exactly like the Mac hotkey. |
| Speech egress | The bridge constructs `SpeechCoordinator` with a Kokoro `tts_executor`. The coordinator gains a remote sink: when the command's `input_source` is `relay-remote`, or when a device is the active output device for lifecycle and messenger speech, `read_out` serializes the intent (`to_worker_payload()` subset) into a `speech` frame instead of playing it through the Mac's speaker; when remote audio is available the TTS worker then synthesises it in a synthesise-only mode and the coordinator streams each sentence as `speech_audio` parts (RR-457), `stop_playback` and skip become `speech_control` frames and cancel that synthesis, and the device's `ack` feeds `record_realization`. When the device is disconnected, speech is held in the replay buffer rather than spoken on the Mac, for up to the buffer window. |
| Mac microphone and speaker | `STTEngine.suspendForReferenceAudio()` already returns a token that silences `writeVoiceOutput` while custom-voice reference audio is recorded. That becomes a reason-based suspension with a `remoteInput` reason. The bridge posts `remote_device` events on `/tmp/voice_state.sock`; `StateEventBus` hands them to `AppState`, which suspends the microphone while a phone is the active input and resumes it when the phone disconnects or the user takes over on the Mac. Kokoro synthesises remote-routed speech without the speech player, so no Mac audio device opens and `VoiceAudioLease` is untouched. |
| Status | The notch and menu bar show `Remote: <device name>` while a device is active, mirroring the existing recording state surfaces. |
| Keep-awake | While at least one device is connected the app holds a prevent-idle-system-sleep power assertion. A closed lid or a manual sleep still disconnects, and the phone says so. |
| Reply ownership | `services/relay_reply.py` and its foreground ownership checks are unchanged. The PM session replies exactly as today; routing happens after the coordinator accepts the reply. |
| Manual bridges | A manual `relay-bridge` session without the app has the bridge-owned socket and therefore remote ingress and egress, but no pairing, no microphone gate and no status; pairing requires the app. |

## iOS app

**Transport.** swift-nio-ssh over swift-nio-transport-services, which is the Network.framework-backed event loop iOS needs. The client opens one exec channel per connection and writes utterance frames to the channel's stdin side. Host key validation is a custom validator that accepts only the fingerprints pinned at pairing; the `.acceptAnything()` validator in library examples is never used. Citadel is an optional convenience layer whose `executeCommand` variants expose stdin only with a PTY, which `restrict` forbids, so if Citadel is used at all it is for connection management while the exec channel is driven with swift-nio-ssh directly.

**Keys.** The permanent device key is a Secure Enclave P-256 key wrapped by `NIOSSHPrivateKey(secureEnclaveP256Key:)`; the private key never leaves the phone and the public key is exported in OpenSSH `ecdsa-sha2-nistp256` form for `authorized_keys`. A Keychain-stored Ed25519 key is the fallback where the Secure Enclave is unavailable, such as the simulator.

**Speech.** Two candidates per direction, chosen by the engine spike below. Since RR-457 the phone plays the Mac's own voice, so the TTS candidates only speak text frames that carry no audio:

| Direction | Candidate | Notes |
| --- | --- | --- |
| STT | FluidAudio Parakeet TDT v3, Parakeet EOU (streaming, end-of-utterance), or Phonon-2 | Same vendor and model family as the Mac, so vocabulary and punctuation behave alike; iOS 18 baseline for newer models; model download on first run |
| STT | Apple `SpeechAnalyzer` with `SpeechTranscriber` | On device, no model download, iOS 26 minimum, no custom vocabulary |
| TTS | `AVSpeechSynthesizer` | No model download, well-behaved with the audio session and lock screen, voice differs from the Mac's Kokoro |
| TTS | FluidAudio Kokoro on iOS | Superseded by RR-457: the Mac streams its own voice. FluidAudio states physical-iOS inference for its Kokoro ANE path is unvalidated |

**Playback (RR-458).** `SpeechPlaybackQueue` in RelayRemoteKit plays an `audio: true` frame through `AudioQueueSpeechPlayer` (`AudioFileStream` parses the ADTS slices, cut anywhere, and one `AudioQueue` per reply decodes and plays them gaplessly), appending parts in part order as they arrive and acknowledging the frame once after the stream has played. If no audio reaches it within 1.5 s of the frame's turn, or the Mac's stream ends with an empty final part before any audio, or the player cannot decode it, the phone speaks the text with `AVSpeechSynthesizer` and logs it. A stream that delivers nothing new for 15 s ends with what it has and is acknowledged `played: false`, as is one ended by an empty final part after some audio. The queue reports idle, buffering (waiting for the first audio) and playing for the state label. A persisted Playback setting chooses **Auto-play** (default) or **Play on demand**: on demand, replies wait unplayed and unacknowledged, the screen shows the newest one with a Play button, and Play plays it and acknowledges older waiting replies `played: false`. Stop, Cancel and starting to talk silence the player as they silence the synthesizer, and Replay plays the replayed reply at once in either mode. While a reply's audio is incomplete the reconnect `resume_after_seq` sits one below that frame, so a drop mid-reply replays it with its parts and the queue drops what it already has.

**Foreground and background.** The app is designed as foreground-first with resume. It uses the audio background mode only while it is genuinely recording or playing, which keeps the connection alive during a long spoken reply with the screen locked. Apple's guidance and developer reports agree that arbitrary sockets do not survive suspension, so the client expects disconnects and relies on `resume_after_seq` plus idempotent `client_id` retries rather than on a permanently open socket. Nothing in the design depends on background execution beyond audio playback.

**Discovery and permissions.** On the home network the app browses Bonjour for `_ssh._tcp`, which macOS Remote Login advertises, filtered to the paired Mac's host name, so no Relay-owned advertiser is needed. This requires `NSLocalNetworkUsageDescription` and `NSBonjourServices` containing `_ssh._tcp` in the app's Info.plist, plus microphone and speech-recognition usage strings. Away from home the app connects to the paired tailnet name or address.

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

- Protocol codec round-trips, replay trimming and `client_id` dedupe pass identical golden vectors in Swift and Python tests.
- The `authorized_keys` writer is idempotent against a temporary `HOME`, never touches foreign lines, and refuses unsafe permissions.
- Remote utterances carry `input_source` and `device_id` through `_begin_relay_command`, the spool `.meta` and the state file, in order with microphone utterances.
- The coordinator's remote sink records realization from device `ack` frames, keeps the Mac's speaker closed for remote-routed speech while streaming its synthesised audio, and cancels that synthesis on every stop, with the speech event log showing the sink and first-audio latency.
- A per-user `sshd -D -f <temporary config> -p <high port>` with a temporary host key and `authorized_keys` runs the real helper end to end on a Mac, with no privileged setup.
- On a physical iPhone: pair by QR, send an utterance, hear the reply in the Mac's voice, lock the phone during a reply, reconnect and receive the replayed frames; repeat over Tailscale from cellular.
- Session control (RR-456): unit tests cover the app handler, the helper's socket order and the codec vectors, and a kit loopback test runs the real helper against a scripted session-control socket that brings up the real bridge module. On a physical iPhone, with Relay Runner running and no session: the phone lists the Mac's projects, Start shows starting then ready, the phone attaches by itself and a typed or spoken request is answered, Stop ends the session on the Mac, and with Relay Runner quit the phone says it is not running.

Push notifications, a hosted relay, multi-user access, remote screen viewing or control, audio from the phone to the Mac, streaming of the Mac's microphone or speaker output, choosing the provider or model from the phone and waking a sleeping Mac are not capabilities of this proposal.

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

Create `ios/` with an Xcode project depending on the repository package for `RelayRemoteProtocol`; swift-nio-ssh over swift-nio-transport-services; the pinned host-key validator; a Secure Enclave P-256 device key with Keychain Ed25519 fallback; one exec channel with `hello`, `resume_after_seq`, reconnect with backoff and `client_id` retry; QR scan pairing; Bonjour `_ssh._tcp` discovery filtered to the paired host; Info.plist usage strings and `NSBonjourServices`; and a text-only debug screen that sends an utterance and shows frames before speech exists.

- Mode: `implementation`.
- Depends on: 1, 3. Pairing end to end also needs 7.
- Sizing: `strong` / `xhigh`. A new platform target, a networking library with known iOS edge cases, key handling and background behavior in one ticket.
- Required inputs: confirmation that the app lives in this repository under `ios/`; an Apple Developer team for device signing; a physical iPhone and a Mac with Remote Login enabled for verification.
- Done when: simulator tests cover codec, reconnect and resume; on a physical iPhone the debug screen pairs, sends text, receives frames, survives lock and unlock with resume, and reconnects over Tailscale from cellular.

### 10. iOS speech integration

Wire the engines chosen by ticket 2: on-device STT with end-of-utterance detection feeding `utterance` frames; TTS speaking `speech` frames in `seq` order and answering `ack` with `played`; `speech_control` stop and skip; audio session configuration with the audio background mode only while recording or playing; push-to-talk and hands-free modes; controls for stop, replay and cancel.

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
