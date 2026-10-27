# Relay Remote (iOS)

The iPhone app for Relay Remote ([spec](../docs/specs/relay-remote.md); until it merges, `git show 2a64cc0d:docs/specs/relay-remote.md`): text frames between the phone and the user's Mac over one SSH connection to the Mac's own OpenSSH server. The transport and debug screen came with RR-428; speech on the phone (RR-429) turns a spoken request into an `utterance` frame and speaks the Mac's `speech` frames while the Mac stays silent.

## Decisions

- **Project:** `project.yml` (XcodeGen) is the source of truth. The generated `RelayRemote.xcodeproj` is committed so the app opens without XcodeGen. After editing `project.yml`, run `xcodegen generate` in `ios/` and commit both. Do not edit the project in Xcode.
- **Deployment target: iOS 26.** RR-421 chose `SpeechAnalyzer` and `AVSpeechSynthesizer` for RR-429, and `SpeechAnalyzer` requires iOS 26. Nothing in the transport needs more than iOS 18, so a lower floor would only have to be revisited for speech.
- **Layout:** `RelayRemoteKit/` is a local SwiftPM package holding all transport, pairing and session logic. It depends on the repository root package for `RelayRemoteProtocol` (RR-422). `swift` fetches only what that product needs; Xcode also resolves the root package's Mac dependencies (FluidAudio, Sparkle and others) but builds none of them. The app target `RelayRemote/` is a thin SwiftUI shell.
- **Transport:** swift-nio-ssh over swift-nio-transport-services, pinned to the revisions the RR-420 spike read (`149f32ff`, `f85ed684`). Each connection has one `session` channel with an `exec` request, an empty command and no PTY. The `authorized_keys` `command=` runs `relay-remote-shell`, which accepts only an empty `SSH_ORIGINAL_COMMAND` or `status`. Remote EOF closes the channel because it means the helper exited.
- **Host key pinning:** `validateHostKey` accepts only the `SHA256:` fingerprints from the pairing code. There is no trust-on-first-use path. A mismatch fails during key exchange, before user authentication. No frame is written, no other address is tried, and the session stops in a visible error state until the user taps Try again.
- **Device key:** a Secure Enclave P-256 key (`NIOSSHPrivateKey(secureEnclaveP256Key:)`, exported as `ecdsa-sha2-nistp256`) when `SecureEnclave.isAvailable`. Otherwise an Ed25519 key stored in the Keychain. The Secure Enclave key is persisted only as its enclave-wrapped `dataRepresentation` in the Keychain. Items use `AfterFirstUnlockThisDeviceOnly`, so a locked phone can reconnect and nothing syncs or migrates. The iOS 26 simulator on Apple silicon has a Secure Enclave, so the Ed25519 fallback is covered by tests rather than by the simulator.
- **Logging:** the kit logs only through `RemoteLogger` with fixed event names and error codes. Key material, fingerprints, tokens, the pairing code and utterance text never reach it. A test captures the sink across pairing and a session and checks that none of them appear. Fingerprints are shown only in the UI.
- **Session:** `hello` carries `resume_after_seq`. Every sequenced Mac frame gets exactly one `ack`, sent by the playback queue in seq order: `played: true` after the synthesizer finished the text, `played: false` for a frame that was stopped, skipped or never speaks (`status`, `speech_control`). The Mac honours only the first ack per seq, so nothing is acknowledged on arrival. A frame at or below the acknowledged watermark is ignored. Acks that cannot be sent during a disconnect wait in an outbox and go out after the next `welcome`, except ones above the Mac's `server_seq`, which belong to a sequence that no longer exists. Utterances stay queued until `accepted` and are resent with their original `client_id` after each `welcome`; they are dropped after five minutes rather than run late. The first ping after `welcome` acts as the replay barrier. A bridge restart, where `resume_after_seq` is greater than `server_seq`, adopts the new sequence.
- **Speech (RR-429):** STT is `SpeechAnalyzer` with `SpeechTranscriber` (`.progressiveTranscription`, on device, model installed through `AssetInventory` on first use). One analyzer serves one utterance: push to talk finalizes on release; hands-free keeps the microphone open and the kit's `UtteranceEndpointer` (an energy detector over the tap's dBFS levels with an adaptive noise floor, 0.9 s trailing silence, 20 s cap) decides where an utterance ends. The transcript is sent through `RemoteSession.send(text:)`, so it gets the same `client_id` and `captured_at` handling as a typed request. TTS is `AVSpeechSynthesizer`, preferring a Premium or Enhanced voice for the device language when one is installed; `SpeechPlaybackQueue` in the kit plays `speech` frames in seq order, honours `speech_control` stop and skip, and owns the acks. Capture pauses while the phone speaks. The audio session (`playAndRecord`) is active only while recording or playing; `UIBackgroundModes` declares `audio`, so a reply keeps playing with the screen locked, and the app stops the session only once audio is idle in the background. An interruption pauses playback and resumes it when the system says so; losing the output route ends the open utterance. Stop, Replay and Cancel send `control` frames; Stop and Cancel also silence the phone at once.
- **Reconnect:** exponential backoff with equal jitter: attempt `n` waits a random time in `[c/2, c]` where `c = min(30 s, 0.5 s × 2ⁿ)`. The backoff resets only after a connection stays welcomed for 15 s, so a flapping Mac is not hammered. A network path change skips the remaining wait.
- **Liveness:** swift-nio-ssh has no client keepalive API. The app pings every 15 s and closes after 40 s without an inbound line. TCP keepalive is idle 30 s, interval 10 s, count 3. sshd's `ClientAliveInterval` covers the Mac side. These are first values and need device measurement.
- **Network changes:** Network.framework does not drop an unviable connection (Apple DTS, forum thread 746449). The transport closes on `ViabilityUpdate(false)` and `BetterPathAvailable`, then reconnects and resumes.
- **Lifecycle:** foreground-first. Leaving the foreground saves `resume_after_seq` and closes the channel, which the Mac sees as a clean disconnect and buffers for. Returning reconnects and replays. Background audio is RR-429's decision.
- **Reachability:** a Bonjour `_ssh._tcp` browse for 1.5 s, keeping the service whose `DNSServiceResolve` host target is the paired `LocalHostName.local`. Then stored addresses: Tailscale (`100.64.0.0/10`), LAN, then `.local` names.
- **Network restriction:** "Only from my home network and Tailscale" on the Mac's pairing confirmation adds a `from=` list to the device's `authorized_keys` line, fixed at pairing time. Home means every Mac interface that holds a private IPv4 address (`10/8`, `172.16/12`, `192.168/16`): its IPv4 subnet, its IPv6 link-local range and its unique-local (`fc00::/7`) and global IPv6 `/64` prefixes. Tailscale means `100.64.0.0/10` and `fd7a:115c:a1e0::/48`. Loopback, public IPv4 addresses and interfaces without a private IPv4 address (for example a VPN tunnel) are left out. sshd compares a link-local client address together with its interface scope, so a bare `fe80::/10` never matches. The range is written per interface as `fe80::%en0/10` and matches only peers on that link; this was checked against a throwaway OpenSSH 10.3 `sshd` (RR-433). If the LAN's global IPv6 prefix or the Mac's interfaces change after pairing, pair again to refresh the list.
- **Refused key:** the phone tries every candidate address in order. A refused host key stops at once. A refused device key moves on to the next address, since a restricted key can be refused on one address and accepted on another (for example on IPv6 but not over the stored LAN IPv4 address). The session stops with "pair again" only when no address connected and every address that answered refused the key; unreachable addresses do not count as answers, so a revoked key still stops while Tailscale is down.
- **Pairing:** QR scan with VisionKit, or paste of the copied code. The phone connects with the one-time Ed25519 key from the code, pins its host keys, and sends `pair` with the token, a new device id, the device name and the device public key. It then waits up to ten minutes for the user to allow the device on the Mac. Forget this Mac clears only the phone; unpair in Relay Runner's Settings to remove the key from the Mac.

## Build and test

Simulator, all app and kit tests:

```bash
cd ios
xcodebuild test -project RelayRemote.xcodeproj -scheme RelayRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

macOS, the kit alone, including the end-to-end SSH tests:

```bash
cd ios/RelayRemoteKit
swift test
```

`SSHTransportIntegrationTests` (macOS only) needs no privileges and does not need Remote Login. It starts a per-user `sshd` on a loopback high port with a temporary host key and `authorized_keys`. It compiles and runs the real `relay-remote-shell` forced command, and runs the real `services/relay_remote.py` bridge module with a scripted ingress. It covers the exec channel, Secure Enclave and Ed25519 authentication, host-key refusal before the forced command runs, rejection of an unknown key, pairing with the ephemeral key, and replay after a reconnect. It is skipped when `sshd` or `python3` is missing.

## Device builds

Create `ios/Config/Signing.local.xcconfig` (gitignored) containing `DEVELOPMENT_TEAM = <team id>`, then run the `RelayRemote` scheme on a connected iPhone.

Physical-device checks (RR-428 acceptance), with Remote Login on for the current user and Relay Runner running a session:

1. Pair: Relay Runner Settings, Relay Remote, Pair a device; scan the code; compare the fingerprint; Allow.
2. Type a request on the debug screen; it gets `accepted` and the Mac session handles it; reply frames appear.
3. Lock the phone while a reply is pending, then unlock. The app reconnects with `resume_after_seq` and shows the replayed frames without a missed-updates notice.
4. With Tailscale connected on both devices, turn off Wi-Fi. The app reconnects over the Tailscale address on cellular, and again when Wi-Fi returns.
5. Network restriction: pair with "Only from my home network and Tailscale" on. On the home Wi-Fi the app connects (over Bonjour IPv6 link-local or LAN IPv4). With Tailscale off on the phone, from a network that can reach the Mac but is outside its home subnets (for example a guest Wi-Fi on another subnet routed to the Mac's LAN), `sshd` logs the key as not from a permitted host and the app shows the refused-key error.
6. In Console, filter subsystem `com.relayrunner.remote` and confirm only event names and codes appear.

Speech checks (RR-429 acceptance), with the Mac session's microphone gate letting the phone own the turn:

7. Push to talk: hold the button, speak a request, release. The transcript appears, the Mac handles the command, and the reply is spoken on the phone while the Mac stays silent. Frames show `utterance`, `accepted`, `speech`.
8. Lock the phone during a long spoken reply. Playback continues, and the Mac's diagnostics record `played` acks for every frame; after unlock no frame is spoken twice.
9. Hands-free: turn on Listen, speak, pause; the request goes out without touching the screen, and the phone does not transcribe its own reply. Press Stop mid-reply: the phone falls silent at once and the Mac receives a `control` frame.

Also watch for reconnect loops from `BetterPathAvailable` over the Tailscale tunnel, and measure idle NAT timeouts to tune the ping and keepalive values.
