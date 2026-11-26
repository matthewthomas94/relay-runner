import AVFoundation
import Foundation
import Network
import UserNotifications

/// One permission the onboarding asks for, in the order asked.
enum PermissionStep: String, CaseIterable, Equatable {
    case microphone, localNetwork, camera, notifications

    var hero: HeroText {
        switch self {
        case .microphone: "Let’s start with your mic"
        case .localNetwork: "Next, local network\nto find your Mac"
        case .camera: "Next, your camera\nto scan the pairing code"
        case .notifications: "Lastly, notifications\nfor replies"
        }
    }
}

enum PermissionStatus: Equatable {
    case undetermined, granted, denied
}

/// The system calls behind the steps, so tests can fake them.
protocol PermissionsClient {
    /// Local network has no status API, so it always reports `.undetermined`.
    func status(of step: PermissionStep) async -> PermissionStatus
    /// Raises the system prompt and returns once it is answered.
    func request(_ step: PermissionStep) async -> PermissionStatus
}

/// Walks the permission steps: steps already decided are left out, the primary
/// button raises the prompt and moves on once it is answered, Skip moves on
/// without asking.
@MainActor @Observable
final class PermissionsFlowModel {
    private(set) var current: PermissionStep?
    private(set) var isLoaded = false
    private var pending: [PermissionStep] = []

    private let client: PermissionsClient
    private var notifications: ReplyNotificationsPreference

    init(client: PermissionsClient = SystemPermissionsClient(),
         notifications: ReplyNotificationsPreference = ReplyNotificationsPreference()) {
        self.client = client
        self.notifications = notifications
    }

    /// Drops the steps whose permission was already decided.
    func load(startingAt forced: PermissionStep? = nil) async {
        guard !isLoaded else { return }
        if let forced {
            pending = Array(PermissionStep.allCases.drop { $0 != forced })
            current = forced
            isLoaded = true
            return
        }
        var steps: [PermissionStep] = []
        for step in PermissionStep.allCases where await client.status(of: step) == .undetermined {
            steps.append(step)
        }
        pending = steps
        current = steps.first
        isLoaded = true
    }

    func grant() async {
        guard let step = current else { return }
        let result = await client.request(step)
        if step == .notifications { notifications.isOn = result == .granted }
        advance()
    }

    func skip() {
        if current == .notifications { notifications.isOn = false }
        advance()
    }

    private func advance() {
        if !pending.isEmpty { pending.removeFirst() }
        current = pending.first
    }
}

struct SystemPermissionsClient: PermissionsClient {
    func status(of step: PermissionStep) async -> PermissionStatus {
        switch step {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .undetermined
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .notDetermined: return .undetermined
            default: return .denied
            }
        case .notifications:
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .notDetermined: return .undetermined
            case .denied: return .denied
            default: return .granted
            }
        case .localNetwork:
            return .undetermined
        }
    }

    func request(_ step: PermissionStep) async -> PermissionStatus {
        switch step {
        case .microphone:
            return await AVAudioApplication.requestRecordPermission() ? .granted : .denied
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        case .notifications:
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            return granted ? .granted : .denied
        case .localNetwork:
            return await LocalNetworkPrompt.trigger()
        }
    }
}

/// iOS has no call to ask for local network access; browsing for the Mac's
/// Bonjour service (what discovery does) raises the prompt. Finishes when the
/// browser reports a result (ready, or waiting while the prompt is open and
/// then denied) or after a short timeout.
enum LocalNetworkPrompt {
    static func trigger(timeout: Duration = .seconds(8)) async -> PermissionStatus {
        let queue = DispatchQueue(label: "relay-remote.local-network-prompt")
        let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: "local."), using: .tcp)
        return await withCheckedContinuation { continuation in
            let gate = OnceGate(continuation)
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.granted)
                case .failed: gate.finish(.denied)
                default: break
                }
            }
            browser.browseResultsChangedHandler = { _, _ in gate.finish(.granted) }
            browser.start(queue: queue)
            Task {
                try? await Task.sleep(for: timeout)
                gate.finish(.undetermined)
            }
            gate.onFinish = { browser.cancel() }
        }
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PermissionStatus, Never>?
        var onFinish: (() -> Void)?

        init(_ continuation: CheckedContinuation<PermissionStatus, Never>) {
            self.continuation = continuation
        }

        func finish(_ status: PermissionStatus) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            onFinish?()
            pending.resume(returning: status)
        }
    }
}
