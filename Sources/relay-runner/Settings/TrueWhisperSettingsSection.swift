import AppKit
import Observation
import SwiftUI
import TrueWhisper

/// The camera permission calls True Whisper settings need, so tests can
/// inject a status instead of touching TCC.
protocol TrueWhisperCameraPermission: AnyObject {
    var camera: PermissionStatus { get }
    func requestCameraPrompt(completion: @escaping (Bool) -> Void)
    func openSettings(for kind: PermissionKind)
}

extension PermissionsManager: TrueWhisperCameraPermission {}

enum TrueWhisperReadout: Equatable {
    case needsEnrollment
    case testing
    case result(accuracy: Int, chance: Int, aboveChance: Bool)

    var description: String {
        switch self {
        case .needsEnrollment: return "Enrol at least two words to test"
        case .testing: return "Testing…"
        case .result(let accuracy, let chance, _): return "Accuracy \(accuracy)%, chance \(chance)%"
        }
    }

    var isAboveChance: Bool {
        if case .result(_, _, true) = self { return true }
        return false
    }

    var status: String? {
        guard case .result = self else { return nil }
        return isAboveChance ? "Above chance" : "Not above chance"
    }
}

@MainActor
@Observable
final class TrueWhisperSettingsModel {
    let enrollment: TrueWhisperEnrollment
    private(set) var readout: TrueWhisperReadout = .needsEnrollment
    /// Set once this section has asked for camera access, so a denial shows
    /// the inline note even while the toggle is off.
    private(set) var cameraRequested = false

    @ObservationIgnored let permission: TrueWhisperCameraPermission
    @ObservationIgnored private let evaluate: @Sendable ([Template]) -> Evaluation?
    @ObservationIgnored private var readoutTask: Task<Void, Never>?
    /// Called after a recording or Clear changes the saved templates, so the
    /// running engine picks them up without a relaunch.
    @ObservationIgnored private let onTemplatesChanged: () -> Void

    init(
        permission: TrueWhisperCameraPermission,
        enrollment: TrueWhisperEnrollment? = nil,
        evaluate: @escaping @Sendable ([Template]) -> Evaluation? = { Evaluation.run(templates: $0, permutations: 100) },
        onTemplatesChanged: @escaping () -> Void = {}
    ) {
        self.permission = permission
        self.onTemplatesChanged = onTemplatesChanged
        self.enrollment = enrollment ?? TrueWhisperEnrollment()
        self.evaluate = evaluate
    }

    func onAppear() {
        enrollment.reloadCounts()
        refreshReadout()
    }

    func showsPermissionNote(enabled: Bool) -> Bool {
        guard enabled || cameraRequested else { return false }
        return permission.camera == .denied || permission.camera == .restricted
    }

    /// Turning True Whisper on asks for the camera when it is not granted.
    /// The toggle keeps whatever the user set, granted or not.
    func enabledChanged(_ enabled: Bool) {
        guard enabled, permission.camera != .granted else { return }
        cameraRequested = true
        permission.requestCameraPrompt { _ in }
    }

    func record(_ word: String) {
        guard !enrollment.isRecording else { return }
        guard permission.camera == .granted else {
            cameraRequested = true
            permission.requestCameraPrompt { [weak self] granted in
                guard granted else { return }
                self?.startRecording(word)
            }
            return
        }
        startRecording(word)
    }

    private func startRecording(_ word: String) {
        enrollment.record(word)
        Task { [weak self] in
            await self?.enrollment.waitUntilIdle()
            self?.refreshReadout()
            self?.onTemplatesChanged()
        }
    }

    func clearAll() {
        try? enrollment.clearAll()
        refreshReadout()
        onTemplatesChanged()
    }

    /// Runs leave-one-out evaluation off the main thread over the words with
    /// enough takes, once at least two words qualify.
    func refreshReadout() {
        readoutTask?.cancel()
        guard enrollment.isReady else {
            readout = .needsEnrollment
            return
        }
        let enrolled = Set(enrollment.counts.filter { $0.value >= TrueWhisperEnrollment.enrolledTakes }.keys)
        let templates = enrollment.store.load().filter { enrolled.contains($0.label) }
        let evaluate = evaluate
        readout = .testing
        readoutTask = Task { [weak self] in
            let evaluation = await Task.detached(priority: .utility) { evaluate(templates) }.value
            guard !Task.isCancelled, let self else { return }
            self.readout = evaluation.map {
                .result(accuracy: Int(($0.accuracy * 100).rounded()),
                        chance: Int(($0.chance * 100).rounded()),
                        aboveChance: $0.pValue < 0.05)
            } ?? .needsEnrollment
        }
    }

    func waitForReadout() async {
        await readoutTask?.value
    }

    static func toggleDescription(isReady: Bool) -> String {
        let base = "While Caps Lock is held, Relay Runner turns the camera on and recognises the enrolled words from your mouth. The microphone stays off. Only lip geometry is kept; no video is stored."
        return isReady ? base : base + " Takes effect once at least two words are enrolled below."
    }

    static func rowDescription(word: String, count: Int, enrollment: TrueWhisperEnrollment) -> String {
        guard enrollment.word == word else {
            return count == 1 ? "1 take" : "\(count) takes"
        }
        let total = TrueWhisperEnrollment.takesPerWord
        switch enrollment.phase {
        case .idle, .waitingForFace: return "Looking for your face…"
        case .cue(let take): return "Take \(take) of \(total): say “\(word)”"
        case .countdown(let take, let remaining): return "Take \(take) of \(total): \(remaining)"
        case .recording(let take): return "Take \(take) of \(total): recording"
        }
    }

    static func failureMessage(_ failure: TrueWhisperEnrollment.Failure) -> String {
        switch failure {
        case .noFace: return "No face found. Sit facing the camera in good light and try again."
        case .tooManyShortTakes: return "Too many takes lost your face. Check the lighting and try again."
        case .camera: return "The camera could not start. Check camera access and try again."
        case .store: return "Could not save the takes. The takes recorded so far are kept."
        }
    }
}

struct TrueWhisperSettingsSection: View {
    @Binding var enabled: Bool
    @State private var model: TrueWhisperSettingsModel
    @State private var confirmClear = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(enabled: Binding<Bool>, permission: TrueWhisperCameraPermission, onTemplatesChanged: @escaping () -> Void = {}) {
        _enabled = enabled
        _model = State(initialValue: TrueWhisperSettingsModel(permission: permission, onTemplatesChanged: onTemplatesChanged))
    }

    private var enrollment: TrueWhisperEnrollment { model.enrollment }
    private var motion: Animation { RelayMotion.change(reduceMotion: reduceMotion) }

    var body: some View {
        SettingsSection("True Whisper", badge: "Experimental") {
            SettingsControlRow(
                "Read lips instead of listening",
                description: TrueWhisperSettingsModel.toggleDescription(isReady: enrollment.isReady)
            ) {
                Toggle("Read lips instead of listening", isOn: $enabled)
            }

            if model.showsPermissionNote(enabled: enabled) {
                SettingsRow {
                    Text("Camera access is off for Relay Runner. Allow it in System Settings to use True Whisper.")
                        .font(AppTypography.font(.settingsDescription))
                        .foregroundStyle(SettingsSurfaceColor.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: SettingsLayout.labelControlSpacing)
                    SettingsActionButton(title: "Open System Settings", systemImage: "gear") {
                        model.permission.openSettings(for: .camera)
                    }
                }
                .transition(.relayElement)
            }

            ForEach(TrueWhisperEnrollment.vocabulary, id: \.self) { word in
                SettingsDivider()
                let isThis = enrollment.word == word
                SettingsControlRow(
                    word.capitalized,
                    description: TrueWhisperSettingsModel.rowDescription(
                        word: word, count: enrollment.counts[word] ?? 0, enrollment: enrollment)
                ) {
                    SettingsActionButton(
                        title: isThis ? "Stop" : "Record",
                        systemImage: isThis ? "stop.fill" : "video",
                        isEnabled: isThis || !enrollment.isRecording,
                        accessibilityLabel: isThis ? "Stop recording \(word)" : "Record \(word)"
                    ) {
                        if isThis { enrollment.stop() } else { model.record(word) }
                    }
                }
            }

            SettingsDivider()

            SettingsControlRow("Recognition test", description: model.readout.description) {
                SettingsInlineStatus(
                    text: model.readout.status,
                    semanticColor: model.readout.isAboveChance ? .success : .idle,
                    reservedWidth: 130
                )
            }

            SettingsDivider()

            SettingsRow {
                Spacer(minLength: 0)
                SettingsActionButton(
                    title: "Clear All Takes", systemImage: "trash",
                    isEnabled: !enrollment.isRecording && !enrollment.counts.isEmpty
                ) {
                    confirmClear = true
                }
            }

            if let failure = enrollment.failure {
                SettingsRow {
                    RelaySwap(TrueWhisperSettingsModel.failureMessage(failure), style: .text, alignment: .leading) { message in
                        Text(message)
                            .font(AppTypography.font(.settingsDescription))
                            .foregroundStyle(SettingsSurfaceColor.error)
                    }
                }
                .transition(.relayElement)
            }
        }
        .animation(motion, value: model.showsPermissionNote(enabled: enabled))
        .animation(motion, value: enrollment.failure)
        .animation(motion, value: model.readout)
        .onAppear { model.onAppear() }
        .onDisappear { enrollment.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in enrollment.stop() }
        .onChange(of: enabled) { _, on in model.enabledChanged(on) }
        .alert("Clear all takes?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every recorded True Whisper take. You will need to enrol words again.")
        }
    }
}
