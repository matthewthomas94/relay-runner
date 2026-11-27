import SwiftUI
import UIKit
import UserNotifications

@main
struct RelayRemoteApp: App {
    @UIApplicationDelegateAdaptor(RelayRemoteAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppFlowRouter(model: appDelegate.model)
                .task { appDelegate.model.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            appDelegate.model.scenePhaseChanged(phase)
        }
    }
}

/// Owns the app model so a tapped notification reaches it even when the tap
/// launched the app (RR-545): the notification centre's delegate has to be set
/// before launch finishes.
@MainActor
final class RelayRemoteAppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()
    private let notifications = NotificationRouter()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notifications
        // A finger landing in a scroll view (the agent and project tabs, the
        // ticket list, Settings) presses what is under it at once, rather than
        // after the ~150 ms scroll views wait to see whether it will scroll.
        // Dragging still scrolls and cancels the press (user, 2026-11-27).
        UIScrollView.appearance().delaysContentTouches = false
        notifications.openAgent = { [weak model] slug in model?.openAgentChat(slug) }
        return true
    }
}
