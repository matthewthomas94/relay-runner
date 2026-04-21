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
    /// themselves — IT admin action is required.
    case restricted
}

/// The three privacy permissions Relay Runner requires.
enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case inputMonitoring

    var id: String { rawValue }

    /// Short human name for the Privacy & Security pane.
    var displayName: String {
        switch self {
        case .microphone:      return "Microphone"
        case .accessibility:   return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }
}

/// Observable source of truth for the app's privacy permission state.
///
/// Checks are cheap (pure local system calls), so we poll on a short
/// interval rather than relying on distributed notifications — macOS
/// doesn't reliably notify apps when permissions flip, so polling is
/// the only way to recover automatically when a user grants in Settings.
@Observable
final class PermissionsManager {

    private(set) var microphone: PermissionStatus = .notDetermined
    private(set) var accessibility: PermissionStatus = .notDetermined
    private(set) var inputMonitoring: PermissionStatus = .notDetermined

    private var pollTimer: Timer?

    init() {
        refresh()
    }

    deinit {
        stopMonitoring()
    }

    /// Read current state of a single permission.
    func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:      return microphone
        case .accessibility:   return accessibility
        case .inputMonitoring: return inputMonitoring
        }
    }

    /// True when every required permission is granted.
    var allGranted: Bool {
        microphone == .granted &&
        accessibility == .granted &&
        inputMonitoring == .granted
    }

    /// The permissions that are not currently usable (anything other than `.granted`).
    var missing: [PermissionKind] {
        PermissionKind.allCases.filter { status(for: $0) != .granted }
    }

    // MARK: - Refresh

    /// Re-read all permission statuses. Publishes updates only on change so
    /// observers don't churn on every tick.
    func refresh() {
        let mic = Self.checkMicrophone()
        let ax = Self.checkAccessibility()
        let im = Self.checkInputMonitoring()
        if mic != microphone { microphone = mic }
        if ax != accessibility { accessibility = ax }
        if im != inputMonitoring { inputMonitoring = im }
    }

    /// Start periodic re-check. Cheap — all underlying APIs are local syscalls.
    func startMonitoring(interval: TimeInterval = 2.0) {
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
                self?.microphone = granted ? .granted : .denied
                completion(granted)
            }
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
}

private extension PermissionKind {
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
        }
    }
}
