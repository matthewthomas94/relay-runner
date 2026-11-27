import Network
import RelayRemoteKit
import RelayRemoteProtocol
import SwiftUI
import UserNotifications

/// Settings (27): Voice, Orchestrator, Mac and Pairing, no page title.
/// Voice's phone-only rows work whatever the Mac is doing; speech speed and
/// the Orchestrator rows are the Mac's and disable when it is unreachable.
struct SettingsTabView: View {
    let model: AppModel

    var body: some View {
        if let session = model.session, let mac = model.paired {
            SettingsContent(model: model, session: session, mac: mac)
        } else {
            #if DEBUG
            if LaunchOptions.current.sampleSettings, let sample = SettingsSample.make() {
                SettingsContent(model: model, session: sample.session, mac: sample.mac, preview: sample.state)
            } else {
                TabPlaceholder(title: "Settings", detail: "Pair with your Mac to change its settings.")
            }
            #else
            TabPlaceholder(title: "Settings", detail: "Pair with your Mac to change its settings.")
            #endif
        }
    }
}

#if DEBUG
/// A never-connecting session and a made-up Mac, for the sample screenshot.
private enum SettingsSample {
    private struct NoTransport: RemoteTransport {
        func connect(to endpoint: NWEndpoint, credentials: SSHCredentials) async throws -> RemoteConnection {
            throw CancellationError()
        }
    }

    @MainActor static func make() -> (session: RemoteSession, mac: PairedMac, state: SettingsState)? {
        guard let key = try? DeviceKeyStore.loadOrCreate(in: InMemorySecretStore(), secureEnclaveAvailable: false)
        else { return nil }
        let mac = PairedMac(deviceID: "sample", deviceName: "Matthew’s MacBook Pro", user: "me", hosts: [], port: 22,
                            hostKeyFingerprints: ["SHA256:Q2v8aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789k1Rm"])
        let session = RemoteSession(
            configuration: SessionConfiguration(deviceID: "sample", deviceName: "iPhone", appVersion: "0",
                                                credentials: SSHCredentials(user: "me", privateKey: key.privateKey,
                                                                            pinnedHostKeys: []),
                                                resumeAfterSeq: nil, remoteMode: true),
            transport: NoTransport(), endpoints: StaticEndpoints([]))
        let state = SettingsState(
            speechSpeedPercent: 100, provider: "claude", model: "opus", effort: "medium", sizing: "orchestrator",
            modelOptions: [SettingOption(value: "opus", label: "Opus")],
            effortOptions: [SettingOption(value: "medium", label: "Medium")],
            sizingOptions: [SettingOption(value: "orchestrator", label: "Orchestrator decides")])
        return (session, mac, state)
    }
}
#endif

private struct SettingsContent: View {
    let model: AppModel
    let session: RemoteSession
    let mac: PairedMac

    @State private var settings: SettingsViewModel
    @State private var talk = TalkModePreference().mode
    @State private var notificationsOn = ReplyNotificationsPreference().isOn
    @State private var notificationsDenied = false
    @State private var confirmingStop = false
    @State private var confirmingForget = false
    @State private var confirmingRedo = false

    init(model: AppModel, session: RemoteSession, mac: PairedMac, preview: SettingsState? = nil) {
        self.model = model
        self.session = session
        self.mac = mac
        _settings = State(initialValue: SettingsViewModel(session: session, previewState: preview))
    }

    private var status: MacSessionStatus { MacSessionStatus(session) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                voice
                orchestrator
                macSection
                pairing
                testing
            }
            .padding(.horizontal, RelayMetrics.screenMargin)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(LaunchOptions.current.scrollsToBottom ? .bottom : .top)
        .task {
            settings.start()
            await refreshNotificationPermission()
        }
        .confirmationDialog("Stop all agents?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop all", role: .destructive) { session.send(sessionCommand: .stop) }
        } message: {
            Text("Every running agent on your Mac stops.")
        }
        .confirmationDialog("Forget this Mac?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget this Mac", role: .destructive) { model.forget() }
        } message: {
            Text("You will pair this iPhone again to use it.")
        }
        .confirmationDialog("Redo onboarding?", isPresented: $confirmingRedo, titleVisibility: .visible) {
            Button("Redo onboarding") { model.redoOnboarding() }
        } message: {
            Text("Every step shows again. Your Mac stays paired.")
        }
    }

    // MARK: Voice

    private var voice: some View {
        SettingsSection("Voice") {
            SettingsRow {
                ToggleRow(title: "Remote mode",
                          subtitle: model.remoteMode ? "Voice runs on this iPhone." : "Voice runs on your Mac.",
                          isOn: Bindable(model).remoteMode)
            }
            SettingsRow {
                SegmentedRow(title: "Talk", options: [("Hold", TalkMode.hold), ("Toggle", TalkMode.toggle)],
                             selection: $talk)
            }
            SettingsRow {
                SegmentedRow(title: "Replies", subtitle: "Auto-play speaks replies as they arrive.",
                             options: [("Auto-play", PlaybackMode.autoPlay), ("Queue", PlaybackMode.onDemand)],
                             selection: Bindable(model).playbackMode)
            }
            SettingsRow {
                ToggleRow(title: "Reply notifications",
                          subtitle: notificationsDenied
                              ? "Notifications are off for Relay Runner. Turn them on in iOS Settings."
                              : "While the app runs in the background.",
                          isOn: Binding(get: { notificationsOn && !notificationsDenied },
                                        set: { setNotifications($0) }))
            }
            SettingsRow(isLast: true) { speechSpeed }
        }
        .onChange(of: talk) { _, mode in TalkModePreference().mode = mode }
    }

    private var speechSpeed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speech speed").relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
            HStack(spacing: 16) {
                SpeedSlider(value: Binding(get: { settings.speechSpeed }, set: { settings.dragSpeed(to: $0) }),
                            range: SettingsViewModel.speedRange,
                            onCommit: { settings.commitSpeed($0) })
                Text(String(format: "%.1fx", settings.speechSpeed))
                    .relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
                    .monospacedDigit()
            }
            .disabled(!settings.isEnabled)
            .opacity(settings.isEnabled ? 1 : 0.4)
            if let line = macBackedLine {
                Text(line).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
            }
        }
    }

    /// The one line under the Mac-backed controls: why they are off, or why a
    /// change was refused.
    private var macBackedLine: String? {
        if case .unavailable(let line) = settings.phase { return line }
        return settings.errorLine
    }

    private func setNotifications(_ on: Bool) {
        guard on else {
            notificationsOn = false
            ReplyNotificationsPreference().isOn = false
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                status = await center.notificationSettings().authorizationStatus
            }
            let allowed = status == .authorized || status == .provisional || status == .ephemeral
            notificationsDenied = !allowed
            notificationsOn = allowed
            ReplyNotificationsPreference().isOn = allowed
        }
    }

    private func refreshNotificationPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsDenied = status == .denied
    }

    // MARK: Orchestrator

    private var orchestrator: some View {
        SettingsSection("Orchestrator") {
            SettingsRow {
                ChoiceRow(title: "Model", options: settings.modelOptions, value: settings.model,
                          label: settings.label(for: settings.model, in: settings.modelOptions),
                          isEnabled: settings.isEnabled, choose: settings.choose(model:))
            }
            SettingsRow {
                ChoiceRow(title: "Effort", options: settings.effortOptions, value: settings.effort,
                          label: settings.label(for: settings.effort, in: settings.effortOptions),
                          isEnabled: settings.isEnabled, choose: settings.choose(effort:))
            }
            SettingsRow(isLast: true) {
                ChoiceRow(title: "Sub-agent sizing", options: settings.sizingOptions, value: settings.sizing,
                          label: settings.label(for: settings.sizing, in: settings.sizingOptions),
                          isEnabled: settings.isEnabled, choose: settings.choose(sizing:))
            }
        }
    }

    // MARK: Mac

    private var macSection: some View {
        SettingsSection("Mac") {
            SettingsRow {
                VStack(alignment: .leading, spacing: 0) {
                    Text(mac.deviceName).relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
                    Text(connectionLine).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsRow(isLast: true) {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Running agents").relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
                        Text(runningAgentsLine).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                    }
                    Spacer(minLength: 8)
                    Button { confirmingStop = true } label: { RelayButtonLabel("Stop all", icon: .power) }
                        .buttonStyle(.relayDanger)
                        .disabled(runningAgents.isEmpty || !reachable)
                }
            }
        }
    }

    private var reachable: Bool { session.state == .connected || session.state == .connectedToApp }

    private var runningAgents: [String] {
        status.agents.isEmpty ? status.runningAgents : status.agents.filter(\.running).map(\.agent)
    }

    private var runningAgentsLine: String {
        let names = runningAgents.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        switch names.count {
        case 0: return reachable ? "None" : "Unknown"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    private var connectionLine: String {
        switch status.phase {
        case .connecting: return "Connecting…"
        case .unreachable: return "Not reachable"
        case .appNotRunning: return "Relay Runner isn't running"
        default: return "Connected"
        }
    }

    // MARK: Pairing

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSection("Pairing") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Mac key").relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
                        Text(fingerprintLine).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                SettingsRow(isLast: true) {
                    Button { confirmingForget = true } label: {
                        Text("Forget this Mac").relayTextStyle(.body).foregroundStyle(RelayColor.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.relayPlain)
                }
            }
            Text("Also unpair it on your Mac.")
                .relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                .padding(.leading, 4)
        }
    }

    // MARK: Testing

    /// For testing the app: walk onboarding again. iOS does not let an app
    /// revoke its own permissions, so to see the real system prompts again,
    /// delete the app and reinstall it.
    private var testing: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSection("Testing") {
                SettingsRow(isLast: true) {
                    Button { confirmingRedo = true } label: {
                        Text("Redo onboarding").relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.relayPlain)
                }
            }
            Text("iOS keeps granted permissions until the app is deleted.")
                .relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                .padding(.leading, 4)
        }
    }

    /// `SHA256:` and the first and last characters of the Mac's key.
    private var fingerprintLine: String {
        guard let fingerprint = mac.hostKeyFingerprints.first else { return "Unknown" }
        guard fingerprint.count > 16 else { return fingerprint }
        return fingerprint.prefix(12) + "…" + fingerprint.suffix(4)
    }
}

// MARK: - Pieces

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).relayTextStyle(.cardTitle).foregroundStyle(RelayColor.neutral10)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .relayGlass(.panel)
        }
    }
}

/// A row in a section's panel, with a hairline under it unless it is the last.
private struct SettingsRow<Content: View>: View {
    var isLast = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if !isLast { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
            }
    }
}

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
                Text(subtitle).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(RelayToggleStyle())
        }
    }
}

/// The styles board's switch: a white track with a black knob when on.
private struct RelayToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? RelayColor.neutral10 : RelayColor.neutral5)
                .frame(width: 52, height: 32)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? RelayColor.neutral1 : RelayColor.neutral10)
                        .frame(width: 24, height: 24).padding(4)
                }
                .animation(RelayMotion.move, value: configuration.isOn)
        }
        .buttonStyle(.relayPlain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private struct SegmentedRow<Value: Hashable>: View {
    let title: String
    var subtitle: String?
    let options: [(String, Value)]
    @Binding var selection: Value
    @Namespace private var pill

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
                if let subtitle { Text(subtitle).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7) }
            }
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    let selected = option.1 == selection
                    Button { withAnimation(RelayMotion.move) { selection = option.1 } } label: {
                        Text(option.0).relayTextStyle(.control)
                            .foregroundStyle(selected ? RelayColor.neutral10 : RelayColor.neutral7)
                            .animation(RelayMotion.enter, value: selected)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background {
                                // One pill that slides to the selected option.
                                if selected {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(RelayColor.neutral4)
                                        .matchedGeometryEffect(id: "pill", in: pill)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.relayPlain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RelayColor.neutral1))
        }
    }
}

/// A row whose value is a pill that opens the choices the Mac sent.
private struct ChoiceRow: View {
    let title: String
    let options: [SettingOption]
    let value: String?
    let label: String
    let isEnabled: Bool
    let choose: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
                .lineLimit(1).minimumScaleFactor(0.8).layoutPriority(-1)
            Spacer(minLength: 8)
            Menu {
                ForEach(options, id: \.value) { option in
                    Button {
                        choose(option.value)
                    } label: {
                        if option.value == value {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(label).relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    LucideImage(.chevronDown, size: 16).foregroundStyle(RelayColor.neutral7)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: RelayMetrics.controlHeight)
                .background(RoundedRectangle(cornerRadius: RelayMetrics.buttonRadius, style: .continuous)
                    .fill(RelayColor.neutral1))
            }
            .disabled(!isEnabled || options.isEmpty)
            .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// A slider in the styles' look that reports the final value on release.
private struct SpeedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let knob: CGFloat = 32
            let travel = max(proxy.size.width - knob, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(RelayColor.neutral5).frame(height: 4)
                Capsule().fill(RelayColor.neutral10).frame(width: travel * fraction + knob / 2, height: 4)
                Circle().fill(RelayColor.neutral10).frame(width: knob, height: knob)
                    .offset(x: travel * fraction)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in value = position(drag.location.x, travel: travel, knob: knob) }
                .onEnded { drag in onCommit(position(drag.location.x, travel: travel, knob: knob)) })
        }
        .frame(height: 32)
        // A selection tick at each 0.1x step while dragging.
        .sensoryFeedback(.selection, trigger: (value * 10).rounded())
        .accessibilityElement()
        .accessibilityLabel("Speech speed")
        .accessibilityValue(String(format: "%.1fx", value))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.1 : -0.1
            let next = min(max(value + step, range.lowerBound), range.upperBound)
            value = next
            onCommit(next)
        }
    }

    private func position(_ x: CGFloat, travel: CGFloat, knob: CGFloat) -> Double {
        let fraction = min(max((x - knob / 2) / travel, 0), 1)
        return range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
    }
}
