import Observation
import RelayRemoteProtocol

/// RR-544: what the Settings tab's Mac-backed controls (speech speed and the
/// Orchestrator rows) show and send, over `RemoteSession`'s settings API.
/// Values are always the Mac's; the one local state is the speech-speed slider
/// while the user drags it.
@MainActor
@Observable
public final class SettingsViewModel {
    public enum Phase: Equatable, Sendable {
        /// Waiting for the first `settings_state`.
        case loading
        /// The controls work.
        case ready
        /// The controls are disabled; the associated line says why.
        case unavailable(String)
    }

    public static let speedRange = 0.5...2.0
    public static let unreachableLine = "Your Mac isn't reachable, so these can't be changed right now."
    public static let unsupportedLine = "This Mac can't change these from your iPhone yet."

    @ObservationIgnored private let session: RemoteSession
    @ObservationIgnored private var requested = false
    /// The slider's position while dragging or until the Mac answers.
    private var pendingSpeed: Double?
    @ObservationIgnored private var observing = false

    /// Debug screenshots only: stands in for the Mac's settings.
    @ObservationIgnored private let previewState: SettingsState?

    public init(session: RemoteSession, previewState: SettingsState? = nil) {
        self.session = session
        self.previewState = previewState
    }

    private var current: SettingsState? { previewState ?? session.settings }

    private var isReachable: Bool {
        previewState != nil || session.state == .connected || session.state == .connectedToApp
    }

    private var hasValues: Bool {
        guard let settings = current else { return false }
        return settings.model != nil || settings.speechSpeedPercent != nil
    }

    public var phase: Phase {
        guard isReachable else { return .unavailable(Self.unreachableLine) }
        if hasValues { return .ready }
        if session.settingsError != nil { return .unavailable(Self.unsupportedLine) }
        return .loading
    }

    public var isEnabled: Bool { phase == .ready }

    /// One short line for a refused change, while the Mac's values show.
    public var errorLine: String? { hasValues ? session.settingsError : nil }

    /// The Mac's speech speed, or what the slider is being dragged to.
    public var speechSpeed: Double {
        pendingSpeed ?? Double(current?.speechSpeedPercent ?? 100) / 100
    }

    public var modelOptions: [SettingOption] { current?.modelOptions ?? [] }
    public var effortOptions: [SettingOption] { current?.effortOptions ?? [] }
    public var sizingOptions: [SettingOption] { current?.sizingOptions ?? [] }

    public var model: String? { current?.model }
    public var effort: String? { current?.effort }
    public var sizing: String? { current?.sizing }

    public func label(for value: String?, in options: [SettingOption]) -> String {
        guard let value else { return "—" }
        return options.first { $0.value == value }?.label ?? value
    }

    /// Asks the Mac for its settings when the channel is up and nothing has
    /// been asked yet on it. Call again when the connection changes.
    public func refresh() {
        guard isReachable else {
            requested = false
            return
        }
        guard !requested else { return }
        requested = session.requestSettings()
    }

    /// Follows the connection and the Mac's replies: asks for the settings
    /// once connected, and drops the slider's drag position when the Mac has
    /// answered, so a refused speed returns to the Mac's value.
    public func start() {
        guard !observing else { return }
        observing = true
        track()
    }

    private func track() {
        withObservationTracking {
            _ = session.state
            _ = session.settings
            _ = session.settingsError
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.macChanged()
                self.track()
            }
        }
        refresh()
    }

    private func macChanged() {
        refresh()
        // After release, the Mac's answer (a different state, or an error)
        // replaces the slider's position; before release a drag is left alone.
        if pendingSpeed != nil, let baseline = committedFrom,
           session.settings != baseline || session.settingsError != nil {
            pendingSpeed = nil
            committedFrom = nil
        }
    }

    /// The settings at the moment the speed was sent; nil while dragging.
    @ObservationIgnored private var committedFrom: SettingsState?

    /// The slider moved: shows the position, sends nothing.
    public func dragSpeed(to value: Double) {
        pendingSpeed = Self.snapped(value)
        committedFrom = nil
    }

    /// The user let go: one `set` with the final speed.
    public func commitSpeed(_ value: Double) {
        let snapped = Self.snapped(value)
        pendingSpeed = snapped
        let baseline = session.settings ?? SettingsState()
        if session.updateSettings(speechSpeedPercent: Int((snapped * 100).rounded())) {
            committedFrom = baseline
        } else {
            pendingSpeed = nil
            committedFrom = nil
        }
    }

    public func choose(model value: String) { _ = session.updateSettings(model: value) }
    public func choose(effort value: String) { _ = session.updateSettings(effort: value) }
    public func choose(sizing value: String) { _ = session.updateSettings(sizing: value) }

    private static func snapped(_ value: Double) -> Double {
        let clamped = min(max(value, speedRange.lowerBound), speedRange.upperBound)
        return (clamped * 10).rounded() / 10
    }
}
