import RelayRemoteKit
import RelayRemoteProtocol
import SwiftUI

/// Debug surface: connection state, the voice controls (RR-429), a field for
/// typed utterances, and the frames that crossed the wire.
struct DebugView: View {
    let model: AppModel
    let session: RemoteSession
    let mac: PairedMac
    @State private var text = ""
    @State private var confirmingForget = false

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("State", value: stateLabel)
                if let code = session.lastDisconnect {
                    LabeledContent("Last disconnect", value: code)
                }
                if case .failed(let failure) = session.state {
                    Label(failure.userMessage, systemImage: "lock.trianglebadge.exclamationmark")
                        .foregroundStyle(.red)
                    Button("Try again") { session.start() }
                }
                if session.missedUpdates {
                    HStack {
                        Label("Some updates were missed while disconnected.", systemImage: "exclamationmark.circle")
                        Spacer()
                        Button("Dismiss") { session.dismissMissedUpdates() }
                    }
                }
                if let error = session.lastError {
                    LabeledContent("Last Mac error", value: error.code)
                }
            }

            Section("Voice") {
                if let voice = model.voice {
                    Picker("Mode", selection: Bindable(voice).mode) {
                        ForEach(VoiceController.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    readinessRow(voice.readiness)
                    LabeledContent("Activity", value: Self.activityLabel(voice.activity))
                    if !voice.transcript.isEmpty {
                        Text(voice.transcript).italic()
                    }
                    if voice.mode == .pushToTalk {
                        HoldToTalkButton(isHeld: voice.isListening, began: voice.pressToTalkBegan,
                                         ended: voice.pressToTalkEnded)
                    } else {
                        Toggle("Listen", isOn: Binding(get: { voice.isListening },
                                                       set: { $0 ? voice.startListening() : voice.stopListening() }))
                    }
                    HStack {
                        Button("Stop", systemImage: "stop.fill") { voice.stop() }
                        Spacer()
                        Button("Replay", systemImage: "arrow.counterclockwise") { voice.replay() }
                        Spacer()
                        Button("Cancel", systemImage: "xmark", role: .destructive) { voice.cancel() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.state != .connected)
                    if let problem = voice.lastProblem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                }
            }

            Section("Send") {
                HStack {
                    TextField("Type a request", text: $text)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(session.pending) { item in
                    Label(item.utterance.text, systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                if session.expiredCount > 0 {
                    Text("\(session.expiredCount) request(s) expired before the Mac received them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Frames") {
                if session.records.isEmpty {
                    Text("No frames yet").foregroundStyle(.secondary)
                }
                ForEach(session.records.reversed()) { record in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: record.direction == .sent ? "arrow.up" : "arrow.down")
                            .foregroundStyle(record.direction == .sent ? .blue : .green)
                        VStack(alignment: .leading) {
                            Text(record.frame.typeName).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(Self.summary(record.frame)).font(.callout)
                        }
                    }
                }
            }

            Section {
                LabeledContent("Mac user", value: mac.user)
                LabeledContent("Addresses", value: mac.hosts.joined(separator: ", "))
                LabeledContent("Device ID", value: mac.deviceID)
                if let key = model.deviceKey {
                    VStack(alignment: .leading) {
                        Text("Device key").font(.caption).foregroundStyle(.secondary)
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                ForEach(mac.hostKeyFingerprints, id: \.self) { fingerprint in
                    VStack(alignment: .leading) {
                        Text("Pinned host key").font(.caption).foregroundStyle(.secondary)
                        Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Button("Forget this Mac", role: .destructive) { confirmingForget = true }
            } header: {
                Text("Pairing")
            } footer: {
                Text("Forgetting only clears this iPhone. Unpair the device in Relay Runner's Settings to remove its key from the Mac.")
            }
        }
        .navigationTitle("Relay Remote")
        .confirmationDialog("Forget this Mac?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { model.forget() }
        }
    }

    private var stateLabel: String {
        switch session.state {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .waiting(let delay): return String(format: "Retrying in %.1fs", delay)
        case .failed(let failure): return "Stopped (\(failure.code))"
        }
    }

    private func send() {
        if session.send(text: text) { text = "" }
    }

    @ViewBuilder
    private func readinessRow(_ readiness: SpeechRecognizer.Readiness) -> some View {
        switch readiness {
        case .downloading(let fraction):
            ProgressView("Downloading the speech model", value: fraction)
        case .unsupported:
            Label("On-device speech is not available for this language.", systemImage: "waveform.slash")
                .foregroundStyle(.secondary)
        case .microphoneDenied:
            Label("Microphone access is off. Allow it in Settings.", systemImage: "mic.slash")
                .foregroundStyle(.red)
        case .failed:
            Label("The speech model could not be installed.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .unknown, .ready:
            EmptyView()
        }
    }

    static func activityLabel(_ activity: VoiceController.Activity) -> String {
        switch activity {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .hearing: return "Hearing you"
        case .transcribing: return "Transcribing"
        case .speaking: return "Speaking"
        }
    }

    static func summary(_ frame: Frame) -> String {
        switch frame {
        case .hello(let hello): return "resume after \(hello.resumeAfterSeq.map(String.init) ?? "none")"
        case .utterance(let utterance): return utterance.text
        case .control(let control): return control.action.rawValue
        case .welcome(let welcome):
            return "\(welcome.sessionState), server seq \(welcome.serverSeq)\(welcome.dropped ? ", updates dropped" : "")"
        case .accepted(let accepted): return "command \(accepted.relayCommandSeq)"
        case .speech(let speech): return "#\(speech.seq) \(speech.kind.rawValue) · \(speech.text)"
        case .speechControl(let control): return "#\(control.seq) \(control.action.rawValue) \(control.reason ?? "")"
        case .status(let status): return "#\(status.seq) \(status.text)"
        case .error(let error): return "\(error.code): \(error.message)"
        case .ack(let ack): return "#\(ack.seq)"
        case .ping(let ping): return "\(ping.t)"
        case .pong(let pong): return "\(pong.t)"
        }
    }
}

/// Push to talk: recording runs while the finger is down and the utterance is
/// sent on release.
struct HoldToTalkButton: View {
    let isHeld: Bool
    let began: () -> Void
    let ended: () -> Void
    @State private var pressing = false

    var body: some View {
        Label(isHeld ? "Release to send" : "Hold to talk", systemImage: isHeld ? "mic.fill" : "mic")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(isHeld ? Color.red.opacity(0.85) : Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        began()
                    }
                    .onEnded { _ in
                        pressing = false
                        ended()
                    }
            )
            .accessibilityLabel("Hold to talk")
    }
}
