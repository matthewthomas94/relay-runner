import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// Status for a single macOS privacy permission.
enum PermissionStatus: Equatable {
    /// Granted by the user.
    case granted
    /// User has explicitly denied, OR the API can't distinguish
    /// "denied" from "never prompted" (true for Accessibility).
    case denied
    /// Never prompted.
    case notDetermined
    /// Blocked by a parental control / MDM policy. User cannot grant it
    /// themselves — IT admin action is required. Only Microphone has an
    /// authoritative system signal for this; Accessibility and Input
    /// Monitoring don't expose a "restricted" status.
    case restricted
}

/// Privacy permissions Relay Runner can use. All are optional — the app
/// degrades gracefully when any of them is denied:
/// - Microphone: required to capture speech.
/// - Accessibility: enables media-pause when recording starts; required by
///   Relay Runner's app-hosted Relay Actions tool host to post CGEvents
///   (clicks, keystrokes).
/// - Input Monitoring: required to capture non-Caps-Lock global activation
///   keys and the double-tap Shift Workspace hotkey.
/// - Screen Recording: required by Relay Runner's app-hosted Relay Vision
///   screenshot tool. Without it, the screenshot tool returns a clear error
///   string but the rest of the app keeps working.
enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case inputMonitoring
    case screenRecording

    var id: String { rawValue }

    /// Short human name for the Privacy & Security pane.
    var displayName: String {
        switch self {
        case .microphone:      return "Microphone"
        case .accessibility:   return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        }
    }

    static let guidedSetupOrder: [PermissionKind] = [
        .microphone,
        .accessibility,
        .inputMonitoring,
        .screenRecording,
    ]
}

/// Observable source of truth for the app's privacy permission state.
///
/// Permission checks are pure local syscalls so polling is cheap. We poll
/// rather than rely on distributed notifications because macOS doesn't
/// reliably notify apps when permissions flip — polling is the only way
/// to recover automatically when a user grants in Settings. We also
/// hook `didBecomeActive` so a flip-back-to-the-app after granting
/// updates the UI without waiting for a poll tick.
@Observable
final class PermissionsManager {

    private(set) var microphone: PermissionStatus = .notDetermined
    private(set) var accessibility: PermissionStatus = .notDetermined
    private(set) var inputMonitoring: PermissionStatus = .notDetermined
    /// Screen Recording is gated only by Relay Runner's hosted Relay Vision
    /// screenshot path. Voice features work even when this is denied.
    private(set) var screenRecording: PermissionStatus = .notDetermined

    /// Permissions blocked by a device policy. Only populated for
    /// Microphone — the system reports `.restricted` directly via
    /// `AVCaptureDevice.authorizationStatus`. Accessibility and Input
    /// Monitoring have no equivalent API, so we don't infer policy
    /// blocks for them from "user clicked Open Settings but stayed
    /// denied" any more — that heuristic fired during the 5-30s window
    /// users spend legitimately navigating Settings, producing a
    /// scary "contact your IT admin" warning during normal grants.
    private(set) var likelyRestricted: Set<PermissionKind> = []

    /// Permissions that were granted on a previous run but appear denied
    /// now. Surfaced as a one-time banner so the user understands the
    /// red dots aren't a detection bug — most likely a macOS update or
    /// app reinstall reset TCC for this signing identity. Cleared when
    /// the user acknowledges or the permission is regranted.
    private(set) var resetSinceLastRun: Set<PermissionKind> = []

    /// Called from the main thread whenever any permission transitions between
    /// statuses (e.g. denied → granted). Used by side-effect observers like
    /// the notifier or STT auto-recovery — UI should observe the published
    /// properties above instead.
    @ObservationIgnored
    var onChange: ((PermissionKind, PermissionStatus, PermissionStatus) -> Void)?

    private var pollTimer: Timer?

    @ObservationIgnored
    private var becomeActiveObserver: NSObjectProtocol?

    /// UserDefaults key prefix for last-known status persistence (Phase C).
    private static let lastKnownDefaultsPrefix = "com.relayrunner.lastKnownPermission."

    init() {
        // Capture last-known status from the previous run BEFORE refresh()
        // overwrites it via persistLastKnown.
        let lastKnown = Self.loadLastKnown()
        refresh()
        // Stale-grant detection: any permission previously granted that
        // is now denied gets flagged for the one-time banner. Other
        // transitions (e.g. .notDetermined → .denied) don't look like
        // a regression — the user simply hasn't granted yet.
        for kind in PermissionKind.allCases {
            let prev = lastKnown[kind] ?? .notDetermined
            if prev == .granted && status(for: kind) == .denied {
                resetSinceLastRun.insert(kind)
            }
        }
        // App-active hook: System Settings > Privacy is the most likely
        // thing the user just left when returning to us. Refresh
        // immediately instead of waiting up to a poll interval.
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        stopMonitoring()
        if let obs = becomeActiveObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Read current state of a single permission.
    func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:      return microphone
        case .accessibility:   return accessibility
        case .inputMonitoring: return inputMonitoring
        case .screenRecording: return screenRecording
        }
    }

    /// True when every first-run voice permission is granted. Relay Runner can
    /// still run with Accessibility / Input Monitoring / Screen Recording
    /// denied; those are surfaced contextually when a feature needs them.
    var allGranted: Bool {
        microphone == .granted
    }

    var guidedSetupGranted: Bool {
        PermissionKind.guidedSetupOrder.allSatisfy { status(for: $0) == .granted }
    }

    /// The missing permissions that block the default voice path.
    var missing: [PermissionKind] {
        [.microphone].filter { status(for: $0) != .granted }
    }

    /// Clear the stale-grant flag for a single permission (e.g. when the
    /// user dismisses the banner). Re-grants clear the flag automatically.
    func acknowledgeReset(_ kind: PermissionKind) {
        resetSinceLastRun.remove(kind)
    }

    // MARK: - Refresh

    /// Re-read all permission statuses. Publishes updates only on change so
    /// observers don't churn on every tick.
    func refresh() {
        let mic = Self.checkMicrophone()
        let ax = Self.checkAccessibility()
        let im = Self.checkInputMonitoring()
        let sr = Self.checkScreenRecording()
        if mic != microphone {
            let old = microphone; microphone = mic
            onChange?(.microphone, old, mic)
            Self.persistLastKnown(.microphone, status: mic)
            if mic == .granted { resetSinceLastRun.remove(.microphone) }
        }
        if ax != accessibility {
            let old = accessibility; accessibility = ax
            onChange?(.accessibility, old, ax)
            Self.persistLastKnown(.accessibility, status: ax)
            if ax == .granted { resetSinceLastRun.remove(.accessibility) }
        }
        if im != inputMonitoring {
            let old = inputMonitoring; inputMonitoring = im
            onChange?(.inputMonitoring, old, im)
            Self.persistLastKnown(.inputMonitoring, status: im)
            if im == .granted { resetSinceLastRun.remove(.inputMonitoring) }
        }
        if sr != screenRecording {
            let old = screenRecording; screenRecording = sr
            onChange?(.screenRecording, old, sr)
            Self.persistLastKnown(.screenRecording, status: sr)
            if sr == .granted { resetSinceLastRun.remove(.screenRecording) }
        }
        // Microphone is the only kind for which the system reports a real
        // policy lock. Mirror its restricted state into likelyRestricted
        // so views have a single API for "blocked by IT" UI.
        if microphone == .restricted {
            likelyRestricted.insert(.microphone)
        } else {
            likelyRestricted.remove(.microphone)
        }
    }

    /// Start periodic re-check. Cheap — all underlying APIs are local
    /// syscalls. Default 1s gives near-instant feedback when a user flips
    /// a toggle in Settings; `didBecomeActive` triggers an extra immediate
    /// refresh on app focus.
    func startMonitoring(interval: TimeInterval = 1.0) {
        stopMonitoring()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Request / prompt

    /// Trigger the system microphone prompt. Resolves on main with the result.
    func requestMicrophone(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.setMicrophoneStatus(granted ? .granted : .denied)
                completion(granted)
            }
        }
    }

    private func setMicrophoneStatus(_ newStatus: PermissionStatus) {
        let old = microphone
        microphone = newStatus
        if old != newStatus {
            onChange?(.microphone, old, newStatus)
            Self.persistLastKnown(.microphone, status: newStatus)
        }
        if newStatus == .granted {
            resetSinceLastRun.remove(.microphone)
        }
        if newStatus == .restricted {
            likelyRestricted.insert(.microphone)
        } else {
            likelyRestricted.remove(.microphone)
        }
    }

    /// Ask for microphone access without sending the user through System
    /// Settings. If the user previously denied access, reset only this app's
    /// Microphone TCC entry first so macOS can show the normal in-app prompt
    /// again. That prompt applies immediately and avoids the Settings
    /// "Quit & Reopen" sheet shown when a running app is toggled externally.
    func requestMicrophonePrompt(completion: @escaping (Bool) -> Void) {
        refresh()
        switch microphone {
        case .notDetermined:
            requestMicrophone(completion: completion)
        case .denied:
            resetMicrophoneAndRequest(completion: completion)
        case .granted:
            completion(true)
        case .restricted:
            completion(false)
        }
    }

    private func resetMicrophoneAndRequest(completion: @escaping (Bool) -> Void) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.relayrunner.app"
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = Self.resetTCC(service: "Microphone", bundleID: bundleID)
            DispatchQueue.main.async {
                self?.refresh()
                self?.requestMicrophone(completion: completion)
            }
        }
    }

    private static func resetTCC(service: String, bundleID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("[Permissions] tccutil reset \(service) failed: \(error)")
            return false
        }
    }

    /// Trigger the Accessibility system prompt. This doesn't grant directly —
    /// the user still has to toggle the app in System Settings. But calling
    /// this makes Relay Runner *appear* in the Accessibility list, which is
    /// a prerequisite on a fresh install.
    func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let opts: CFDictionary = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Trigger the Input Monitoring system prompt. Same caveat as Accessibility:
    /// on macOS 10.15+ the system only makes the app visible in the list; the
    /// user must toggle it on.
    func promptInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Force this app to appear in System Settings → Privacy & Security →
    /// Input Monitoring when the user explicitly needs it. macOS only
    /// registers an app's cdhash for kTCCServiceListenEvent when something
    /// actually attempts to install a global event monitor — IOHIDRequestAccess
    /// alone is unreliable for this on ad-hoc-signed builds.
    ///
    /// Install + immediately remove a no-op global key monitor so the cdhash
    /// is registered before the user clicks Open Settings. If the app was
    /// already registered, this is a quick no-op. If permission hasn't been
    /// granted yet, `addGlobalMonitorForEvents` returns nil and no events are
    /// observed — TCC still sees the attempt, which is enough. Must be called
    /// on the main thread (NSEvent monitor lifecycle is main-thread-only).
    func registerForInputMonitoringList() {
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { _ in }) else {
            return
        }
        NSEvent.removeMonitor(monitor)
    }

    /// Open the appropriate Privacy & Security pane in System Settings.
    /// URL scheme is stable across macOS 13 / 14 / 15.
    func openSettings(for kind: PermissionKind) {
        guard let url = URL(string: kind.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Individual status checks

    private static func checkMicrophone() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    private static func checkAccessibility() -> PermissionStatus {
        // AXIsProcessTrusted() cannot distinguish "never prompted" from
        // "denied" — both return false. Callers that care about the
        // difference should track whether they've called promptAccessibility()
        // in this session.
        AXIsProcessTrusted() ? .granted : .denied
    }

    private static func checkInputMonitoring() -> PermissionStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied:  return .denied
        case kIOHIDAccessTypeUnknown: return .notDetermined
        default:                      return .notDetermined
        }
    }

    /// Screen Recording is checked via CGPreflightScreenCaptureAccess (macOS 11+).
    /// This API doesn't trigger a prompt — it just reads current TCC state.
    /// To actually prompt, the app invokes CGRequestScreenCaptureAccess or the
    /// hosted `screenshot` tool. Either path attributes the grant to Relay
    /// Runner because the gated call runs in the app process.
    private static func checkScreenRecording() -> PermissionStatus {
        // The preflight API returns true only when granted; otherwise we
        // can't tell .denied from .notDetermined here. Treat both as .denied
        // — the screenshot tool's failure path tells the user how to grant
        // and surfaces the same Settings deep-link as other permissions.
        return CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Trigger the system Screen Recording prompt. Like Accessibility, this
    /// just makes the app appear in the Privacy pane — the user still has to
    /// flip the toggle in System Settings. Calling it pre-emptively is OK.
    func promptScreenRecording() {
        // CGRequestScreenCaptureAccess registers the app's cdhash with TCC
        // for kTCCServiceScreenCapture if it isn't already registered. Returns
        // true if the user has already granted; false otherwise. Either way,
        // the app appears in System Settings → Privacy & Security → Screen
        // Recording afterward.
        _ = CGRequestScreenCaptureAccess()
    }

    // MARK: - Last-known status persistence

    private static func loadLastKnown() -> [PermissionKind: PermissionStatus] {
        var result: [PermissionKind: PermissionStatus] = [:]
        let defaults = UserDefaults.standard
        for kind in PermissionKind.allCases {
            let key = lastKnownDefaultsPrefix + kind.rawValue
            if let raw = defaults.string(forKey: key),
               let status = PermissionStatus.fromStored(raw) {
                result[kind] = status
            }
        }
        return result
    }

    private static func persistLastKnown(_ kind: PermissionKind, status: PermissionStatus) {
        let key = lastKnownDefaultsPrefix + kind.rawValue
        UserDefaults.standard.set(status.storedValue, forKey: key)
    }
}

private extension PermissionStatus {
    var storedValue: String {
        switch self {
        case .granted:       return "granted"
        case .denied:        return "denied"
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        }
    }

    static func fromStored(_ raw: String) -> PermissionStatus? {
        switch raw {
        case "granted":       return .granted
        case "denied":        return .denied
        case "notDetermined": return .notDetermined
        case "restricted":    return .restricted
        default:              return nil
        }
    }
}

extension PermissionKind {
    /// Deep-link URL for the Privacy & Security subpane.
    /// Stable across macOS 13 (Ventura) / 14 (Sonoma) / 15 (Sequoia).
    var settingsURL: String {
        switch self {
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }
}
