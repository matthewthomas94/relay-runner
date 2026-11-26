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
        notifications.openAgent = { [weak model] slug in model?.openAgentChat(slug) }
        return true
    }
}
