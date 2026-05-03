import Foundation
import UserNotifications

/// Fires a macOS notification when a privacy permission the app was relying
/// on gets revoked. Wired up so that PermissionsManager.onChange routes into
/// `recordChange(_:from:to:)`.
///
/// Anti-spam rules:
///  * Only fires on a transition from `.granted` to anything else — not on
///    initial startup, not on first-ever prompt.
///  * Debounces to at most one notification per permission per 5 minutes,
///    so an OS blip that flaps the status doesn't spam the user.
final class PermissionNotifier {

    private var lastNotified: [PermissionKind: Date] = [:]
    private let debounceWindow: TimeInterval = 300

    init() {
        // Ask for notification permission up-front. If the user declines,
        // `add(_:)` below still succeeds but the alert never shows — that's
        // fine; the menu bar badge still signals the issue.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    /// Call on every permission status transition. Fires a notification only
    /// when the transition is a real revocation.
    func recordChange(_ kind: PermissionKind,
                      from old: PermissionStatus,
                      to new: PermissionStatus) {
        guard old == .granted, new != .granted else { return }

        if let last = lastNotified[kind],
           Date().timeIntervalSince(last) < debounceWindow {
            return
        }
        lastNotified[kind] = Date()

        let content = UNMutableNotificationContent()
        content.title = "Relay Runner — \(kind.displayName) access lost"
        content.body = body(for: kind)
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "perm-revoked-\(kind.rawValue)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func body(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            return "Relay Runner can't hear you — microphone access was removed. Open the menu and choose Fix Permissions to restore it."
        case .accessibility:
            return "Relay Runner can't pause media during recording — Accessibility access was removed. Open the menu and choose Fix Permissions."
        case .inputMonitoring:
            return "Relay Runner can't detect your trigger key — Input Monitoring access was removed. Open the menu and choose Fix Permissions."
        case .screenRecording:
            return "Relay Runner can't take screenshots for the computer-action voice tools — Screen Recording access was removed. Voice transcription and speech still work."
        }
    }
}
