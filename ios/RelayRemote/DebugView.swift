import RelayRemoteKit
import RelayRemoteProtocol
import SwiftUI

/// Debug surface: the Remote mode switch (RR-454), the Mac's session with
/// Start and Stop (RR-456), connection state, the voice controls (RR-429), a
/// field for typed utterances, and the frames that crossed the wire.
struct DebugView: View {
    let model: AppModel
    let session: RemoteSession
    let mac: PairedMac
    @State private var text = ""
    @State private var confirmingForget = false
    @State private var chosenProject: String?

    var body: some View {
        List {
            Section {
                Toggle(isOn: Bindable(model).remoteMode) {
                    Label("Remote mode", systemImage: model.remoteMode ? "iphone.radiowaves.left.and.right" : "desktopcomputer")
                        .font(.headline)
                }
            } footer: {
                Text(model.remoteMode
                     ? "This iPhone listens and speaks. Your Mac stays quiet and awake."
                     : "Your Mac listens and speaks. Replies show here as text.")
            }

            MacSessionSection(session: session, chosenProject: $chosenProject)

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
                    Picker("Playback", selection: Bindable(model).playbackMode) {
                        ForEach(PlaybackMode.allCases, id: \.self) { Text(Self.playbackLabel($0)).tag($0) }
                    }
                    readinessRow(voice.readiness)
                    LabeledContent("Activity", value: Self.activityLabel(voice.activity))
                    if let reply = voice.waitingReply {
                        HStack(alignment: .firstTextBaseline) {
                            Text(reply)
                            Spacer()
                            Button("Play", systemImage: "play.fill") { voice.play() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    if !voice.transcript.isEmpty {
                        Text(voice.transcript).italic()
                    }
                    Group {
                        if voice.mode == .pushToTalk {
                            HoldToTalkButton(isHeld: voice.isListening, began: voice.pressToTalkBegan,
                                             ended: voice.pressToTalkEnded)
                        } else {
                            Toggle("Listen", isOn: Binding(get: { voice.isListening },
                                                           set: { $0 ? voice.startListening() : voice.stopListening() }))
                        }
                    }
                    .disabled(!voice.remoteMode)
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
        case .connectedToApp: return "Connected to Relay Runner, no session"
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
        case .buffering: return "Buffering"
        case .speaking: return "Speaking"
        }
    }

    static func playbackLabel(_ mode: PlaybackMode) -> String {
        switch mode {
        case .autoPlay: return "Auto-play"
        case .onDemand: return "Play on demand"
        }
    }

    static func summary(_ frame: Frame) -> String {
        switch frame {
        case .hello(let hello): return "resume after \(hello.resumeAfterSeq.map(String.init) ?? "none")"
        case .utterance(let utterance): return utterance.text
        case .control(let control): return control.action.rawValue
        case .remoteMode(let mode): return mode.enabled ? "on" : "off"
        case .sessionCommand(let command):
            return command.action.rawValue + (command.projectId.map { " \($0)" } ?? "")
        case .sessionState(let state):
            guard state.appRunning else { return "Relay Runner not running" }
            return ([state.session.rawValue] + [state.projectName, state.error].compactMap { $0 }).joined(separator: " · ")
        case .welcome(let welcome):
            return "\(welcome.sessionState), server seq \(welcome.serverSeq)\(welcome.dropped ? ", updates dropped" : "")"
        case .accepted(let accepted): return "command \(accepted.relayCommandSeq)"
        case .speech(let speech):
            return "#\(speech.seq) \(speech.kind.rawValue)\(speech.spokenBy == .mac ? " (Mac)" : "") · \(speech.text)"
        case .speechAudio(let audio): return "#\(audio.seq) audio part \(audio.part)\(audio.last == true ? " (last)" : "")"
        case .speechControl(let control): return "#\(control.seq) \(control.action.rawValue) \(control.reason ?? "")"
        case .status(let status): return "#\(status.seq) \(status.text)"
        case .error(let error): return "\(error.code): \(error.message)"
        case .ack(let ack): return "#\(ack.seq)"
        case .ping(let ping): return "\(ping.t)"
        case .pong(let pong): return "\(pong.t)"
        }
    }
}

/// RR-456: pick a project registered on the Mac and start its session, or stop
/// the running one. Once it is ready the session reconnects and attaches by
/// itself. The Mac's provider, model and effort defaults apply.
struct MacSessionSection: View {
    let session: RemoteSession
    @Binding var chosenProject: String?
    @State private var confirmingStop = false

    var body: some View {
        let status = MacSessionStatus(session)
        Section {
            Label(Self.title(status), systemImage: Self.symbol(status.phase))
            if let error = status.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if status.phase == .noSession || status.phase == .failed {
                if status.projects.isEmpty {
                    Text("No projects are registered on this Mac.").foregroundStyle(.secondary)
                } else {
                    Picker("Project", selection: Binding(
                        get: { status.startProject(chosen: chosenProject) ?? "" },
                        set: { chosenProject = $0 }
                    )) {
                        ForEach(status.projects, id: \.projectId) { project in
                            Text(project.isAvailable ? project.displayName : "\(project.displayName) (unavailable)")
                                .tag(project.projectId)
                                .selectionDisabled(!project.isAvailable)
                        }
                    }
                }
                Button("Start session", systemImage: "play.fill") {
                    session.send(sessionCommand: .start, projectID: status.startProject(chosen: chosenProject))
                }
                .disabled(!status.canStart(chosen: chosenProject))
            }
            if status.canStop {
                Button("Stop session", systemImage: "stop.fill", role: .destructive) { confirmingStop = true }
            }
        } header: {
            Text("Mac session")
        }
        .confirmationDialog("Stop the session on the Mac?", isPresented: $confirmingStop) {
            Button("Stop session", role: .destructive) { session.send(sessionCommand: .stop) }
        }
    }

    static func title(_ status: MacSessionStatus) -> String {
        switch status.phase {
        case .unreachable: return "Mac unreachable"
        case .connecting: return "Connecting to the Mac"
        case .appNotRunning: return "Relay Runner is not running on the Mac"
        case .noSession: return "No session running"
        case .starting: return "Starting \(status.projectName ?? "a session")"
        case .ready: return status.projectName.map { "\($0) is ready" } ?? "Session ready"
        case .failed: return "Could not start \(status.projectName ?? "the session")"
        }
    }

    static func symbol(_ phase: MacSessionStatus.Phase) -> String {
        switch phase {
        case .unreachable: return "wifi.slash"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .appNotRunning: return "desktopcomputer.trianglebadge.exclamationmark"
        case .noSession: return "pause.circle"
        case .starting: return "hourglass"
        case .ready: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
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
