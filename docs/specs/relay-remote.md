# Relay Remote

**Status:** Proposed

Proposed direction, 22 October 2026. Source inspected at Relay commit `7341421d7d63eb2e1fd6baab2e28e7a9427ba02b`.

Relay Remote is the proposed path for a native iOS app to drive a Relay Runner voice session on the user's own Mac. Speech-to-text and text-to-speech stay on the phone; only text crosses the link, inside an SSH connection to the Mac's built-in OpenSSH server. It sits beside [Relay Actions](relay-actions.md) and [Relay Vision](relay-vision.md), which keep owning screen manipulation and observation on the Mac. Relay Remote owns nothing on screen: it adds a second voice input and output device to the existing voice contract and routes replies back to whichever device asked.

## Validation of the SSH and TCP proposal

**Verdict.** The proposal is sound and is the recommended shape. The Mac already ships an SSH server (Remote Login), the phone can hold one authenticated SSH connection and multiplex text both ways over it, and nothing in the path needs a hosted service, an account, or a third-party relay. The two pieces Relay has to build are an iOS client and a small, restricted entry point on the Mac that joins the SSH connection to the running voice session.

**What "serverless" means here.** No cloud intermediary and no Relay-operated service. The Mac still runs a server process, `sshd`, but it is Apple's, it already exists on every Mac, and the user controls it from System Settings. Relay never stands up its own listening TCP port on the Mac's network interfaces; the only network listener in the design is `sshd` itself.

**Why SSH rather than a bespoke TCP protocol.** A bespoke protocol would have to reinvent what SSH already gives for free: mutual authentication (per-device keys plus a pinned host key), confidentiality and integrity on an untrusted Wi-Fi or cellular path, a per-key policy that confines a device to one program on the Mac, and key revocation by deleting a line. OpenSSH's `authorized_keys` options make that confinement explicit: `command="..."` runs a fixed program regardless of what the client asked for (the client's request is only exposed as `SSH_ORIGINAL_COMMAND`), `restrict` disables PTY allocation, port forwarding, agent forwarding, X11 and `~/.ssh/rc`, and `expiry-time=` lets a pairing key expire on its own. TCP is still the transport underneath, so the friend's description "SSH and TCP" is exactly right.

**Two channel shapes.** The recommended shape is an SSH exec channel whose forced command is a Relay helper speaking newline-delimited JSON over its stdin and stdout; the SSH channel carries that byte stream and nothing else. The alternative is a `direct-tcpip` channel (SSH local port forwarding) to a loopback-only TCP listener on the Mac, which would need `restrict,port-forwarding,permitopen="127.0.0.1:<port>"` on the key and a Relay-owned TCP listener bound to loopback. The exec shape is preferred because it needs no Relay network listener at all, it works unchanged with `restrict`, and the process-per-connection boundary makes the helper trivially restartable. The `direct-tcpip` shape stays documented as the fallback if the iOS SSH library turns out to handle exec channels poorly.

## Goals

- A paired iPhone on the home network, or on the user's tailnet, can send a spoken request to the Mac's running Relay session and hear the reply, with speech recognition and synthesis on the phone and text only on the wire.
- The phone's text enters the exact command pipeline the Mac microphone uses: command identity, intent inbox, claim files, stale-output suppression and reply ownership all behave as they do today.
- Replies, messenger speech, clarifications and worker lifecycle speech that would have been spoken by the Mac's Kokoro worker are instead delivered to the phone that asked, and the Mac stays silent while the phone is the active device.
- Pairing is a one-time, Mac-confirmed action; revocation is deleting one line the app wrote.
- Codex and Claude sessions see identical behavior.

## Non-goals

- No hosted relay, account, push notification service or Relay-operated server. Push notifications would require a server and are out of scope.
- No audio on the wire in either direction, and no streaming of the Mac's microphone or speakers.
- No remote screen viewing or screen control from the phone. Relay Actions and Relay Vision remain Mac-local.
- No starting of a Relay session from the phone in the first version; the phone attaches to a session that is already running.
- No multi-user access. One Mac login user, that user's keys, that user's session.
- No waking of a sleeping Mac. A sleeping or logged-out Mac is unreachable by design.

## Architecture

```
iPhone (Relay Remote app)
  mic -> on-device STT -> NDJSON frames ----\
  on-device TTS <- speech frames <----------+-- one SSH connection, one exec channel, port 22
                                            |
Mac                                         v
  sshd (Remote Login) -> authorized_keys forced command
      -> relay-remote-shell --device <device_id>          (bundled Swift helper, stdin/stdout)
          <-> /tmp/relay_remote.sock                       (Unix stream socket, bridge-owned)
              services/relay_remote.py inside voice_bridge.py
                 - utterances  -> bridge ingress queue -> command pipeline -> PM session
                 - controls    -> existing __TTS_STOP__ / __INTERRUPT__ / __CANCEL__ / __PLAY__ / __REPLAY__
                 - speech      <- SpeechCoordinator remote sink (instead of the Kokoro worker)
  Relay Runner.app
     - pairing UI, authorized_keys writer, /tmp/relay_remote_pair.sock
     - microphone and speaker gate while a remote device is active, status, keep-awake
```

| Component | Lives in | Responsibility |
| --- | --- | --- |
| Relay Remote iOS app | new `ios/` project in this repo plus a shared SwiftPM protocol target | Capture speech, transcribe on device, hold the SSH connection, speak reply frames, pair and store the device key |
| `relay-remote-shell` | new Swift executable target, embedded and signed by `scripts/build-dmg.sh` | The forced command. Copies NDJSON between the SSH channel and the local Unix socket, enforces frame limits, exits when either side closes |
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
{"type":"hello","protocol":1,"device_id":"...","device_name":"iPhone","app_version":"0.1","resume_after_seq":41}
{"type":"utterance","client_id":"...","text":"move RR-120 to ready","captured_at":"2026-10-22T09:14:03Z"}
{"type":"control","client_id":"...","action":"stop"}           stop | interrupt | cancel | play | replay
{"type":"ack","seq":44,"played":true}
{"type":"ping","t":1761124443}

Mac -> phone
{"type":"welcome","protocol":1,"session_state":"running","server_seq":44,"resumed_from":41,"dropped":false}
{"type":"accepted","client_id":"...","relay_command_seq":812,"relay_command_id":"4711-1761124443123456789-812"}
{"type":"speech","seq":45,"kind":"handoff","source":"messenger","text":"Looking at RR-120 now.","relay_command_seq":812}
{"type":"speech","seq":46,"kind":"final","source":"orchestrator","text":"RR-120 is in ready and dispatching.","relay_command_seq":812}
{"type":"speech_control","seq":47,"action":"stop","reason":"superseded"}
{"type":"status","seq":48,"text":"worker RR-120 started"}
{"type":"error","code":"no_session","message":"Relay Runner is not running a session"}
{"type":"pong","t":1761124443}
```

- `accepted` is the phone's receipt that an utterance entered the intent inbox, the remote equivalent of the notch's visual receipt. The phone shows it; it does not speak it.
- `speech` mirrors `SpeechIntent` from `services/speech_coordinator.py`: the same `kind` values (`handoff`, `progress`, `clarification`, `final`, `fallback`, `control`) and `source` values (`messenger`, `orchestrator`, `lifecycle`, `completion`, `fallback`). The phone speaks it with its own synthesizer and answers `ack` with `played` so the coordinator's realization record and played coverage stay truthful.
- `speech_control` carries the coordinator's stop and skip decisions, including stale-output suppression when a newer command exists.
- The Mac keeps a bounded replay buffer per device (the last 200 frames or five minutes). A `hello` with `resume_after_seq` replays what the phone missed, or sets `dropped: true` so the phone can say that updates were missed rather than pretending nothing happened. Frames the phone has acknowledged are trimmed.
- Controls map one-to-one onto the FIFO tokens the bridge already dispatches: `stop` to `__TTS_STOP__`, `interrupt` to `__INTERRUPT__`, `cancel` to `__CANCEL__`, `play` to `__PLAY__`, `replay` to `__REPLAY__`. No new control semantics are introduced.
- `SSH_ORIGINAL_COMMAND` is ignored except for an allow-listed `status` subcommand that returns one `status` frame and exits, used by the phone's connection check.

## Mac-side integration with the voice contract

| Surface | Current behavior and work required |
| --- | --- |
| Text ingress | The Mac microphone path writes newline-delimited text to `/tmp/voice_in.fifo` through `Sources/relay-runner/STT/FIFOWriter.swift`, and the bridge's FIFO select loop turns each line into a command. Remote utterances do not go through the FIFO: macOS pipes guarantee atomic writes only up to 512 bytes, and a long sentence could interleave with microphone text. `relay_remote.py` instead pushes each utterance onto a bridge-owned queue and wakes the same select loop through a pipe, so microphone and remote text share one ordering, one `relay_command_seq` counter and one handler. |
| Command metadata | `_begin_relay_command` in `services/voice_bridge.py` records seq, id, source text, receipt time and recovery generation, and `RelayCommandMetadata` in `services/pm_frontstage.py` carries seq, id, provider and source text. Neither has an origin field. Both gain `input_source` (`mac-mic`, `relay-remote`, `manual`) and `device_id`, written through to the spool `.meta` and the state file so the PM session and the reply path can see where a command came from. Existing readers ignore unknown keys. |
| Controls | The `__`-prefixed control map and dispatch in `voice_bridge.py` stay as they are. The remote module submits the mapped token for a `control` frame through the same queue, so a phone tap behaves exactly like the Mac hotkey. |
| Speech egress | The bridge constructs `SpeechCoordinator` with a Kokoro `tts_executor`. The coordinator gains a remote sink: when the command's `input_source` is `relay-remote`, or when a device is the active output device for lifecycle and messenger speech, `read_out` serializes the intent (`to_worker_payload()` subset) into a `speech` frame instead of running Kokoro, `stop_playback` and skip become `speech_control` frames, and the device's `ack` feeds `record_realization`. When the device is disconnected, speech is held in the replay buffer rather than spoken on the Mac, for up to the buffer window. |
| Mac microphone and speaker | `STTEngine.suspendForReferenceAudio()` already returns a token that silences `writeVoiceOutput` while custom-voice reference audio is recorded. That becomes a reason-based suspension with a `remoteInput` reason. The bridge posts `remote_device` events on `/tmp/voice_state.sock`; `StateEventBus` hands them to `AppState`, which suspends the microphone while a phone is the active input and resumes it when the phone disconnects or the user takes over on the Mac. Kokoro is not started for remote-routed speech, so `VoiceAudioLease` is untouched. |
| Status | The notch and menu bar show `Remote: <device name>` while a device is active, mirroring the existing recording state surfaces. |
| Keep-awake | While at least one device is connected the app holds a prevent-idle-system-sleep power assertion. A closed lid or a manual sleep still disconnects, and the phone says so. |
| Reply ownership | `services/relay_reply.py` and its foreground ownership checks are unchanged. The PM session replies exactly as today; routing happens after the coordinator accepts the reply. |
| Manual bridges | A manual `relay-bridge` session without the app has the bridge-owned socket and therefore remote ingress and egress, but no pairing, no microphone gate and no status; pairing requires the app. |

## iOS app

**Transport.** swift-nio-ssh over swift-nio-transport-services, which is the Network.framework-backed event loop iOS needs. The client opens one exec channel per connection and writes utterance frames to the channel's stdin side. Host key validation is a custom validator that accepts only the fingerprints pinned at pairing; the `.acceptAnything()` validator in library examples is never used. Citadel is an optional convenience layer whose `executeCommand` variants expose stdin only with a PTY, which `restrict` forbids, so if Citadel is used at all it is for connection management while the exec channel is driven with swift-nio-ssh directly.

**Keys.** The permanent device key is a Secure Enclave P-256 key wrapped by `NIOSSHPrivateKey(secureEnclaveP256Key:)`; the private key never leaves the phone and the public key is exported in OpenSSH `ecdsa-sha2-nistp256` form for `authorized_keys`. A Keychain-stored Ed25519 key is the fallback where the Secure Enclave is unavailable, such as the simulator.

**Speech.** Two candidates per direction, chosen by the engine spike below:

| Direction | Candidate | Notes |
| --- | --- | --- |
| STT | FluidAudio Parakeet TDT v3, Parakeet EOU (streaming, end-of-utterance), or Phonon-2 | Same vendor and model family as the Mac, so vocabulary and punctuation behave alike; iOS 18 baseline for newer models; model download on first run |
| STT | Apple `SpeechAnalyzer` with `SpeechTranscriber` | On device, no model download, iOS 26 minimum, no custom vocabulary |
| TTS | `AVSpeechSynthesizer` | No model download, well-behaved with the audio session and lock screen, voice differs from the Mac's Kokoro |
| TTS | FluidAudio Kokoro on iOS | Voice parity with the Mac; FluidAudio states physical-iOS inference for its Kokoro ANE path is unvalidated |

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
- `/tmp/relay_remote.sock` and `/tmp/relay_remote_pair.sock` are mode 600 and the listeners verify the peer's uid with `getpeereid`; the forced command runs as the login user, so the check passes without any secret in the environment.
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
- Whether Kokoro on a physical iPhone is fast and stable enough to justify voice parity over `AVSpeechSynthesizer`.
- How long an exec channel actually survives with the screen locked while audio is playing, measured on a physical device, and whether the audio session interruption path reconnects cleanly.
- Whether to allow `status` or `start_session` from the phone when no session is running, which would move session start into the app-owned socket.
- Whether per-command routing (reply to the device that asked) or per-session routing (one active output device) feels right when the user moves between phone and Mac mid-conversation. The spec starts with per-command routing for replies and active-device routing for lifecycle speech.

## Verification targets

- Protocol codec round-trips, replay trimming and `client_id` dedupe pass identical golden vectors in Swift and Python tests.
- The `authorized_keys` writer is idempotent against a temporary `HOME`, never touches foreign lines, and refuses unsafe permissions.
- Remote utterances carry `input_source` and `device_id` through `_begin_relay_command`, the spool `.meta` and the state file, in order with microphone utterances.
- The coordinator's remote sink records realization from device `ack` frames and suppresses Kokoro for remote-routed speech, with the speech event log showing the sink.
- A per-user `sshd -D -f <temporary config> -p <high port>` with a temporary host key and `authorized_keys` runs the real helper end to end on a Mac, with no privileged setup.
- On a physical iPhone: pair by QR, send an utterance, hear the reply, lock the phone during a reply, reconnect and receive the replayed frames; repeat over Tailscale from cellular.

Push notifications, a hosted relay, multi-user access, remote screen viewing or control, audio streaming in either direction, starting a session remotely and waking a sleeping Mac are not capabilities of this proposal.

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

The bridge posts `remote_device` connected, active and disconnected events on `/tmp/voice_state.sock`; `AppState` suspends the microphone through a reason-based extension of `suspendForReferenceAudio` while a phone is active and resumes on disconnect or user takeover; the notch and menu bar show `Remote: <device>`; a prevent-idle-sleep assertion is held while a device is connected.

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
