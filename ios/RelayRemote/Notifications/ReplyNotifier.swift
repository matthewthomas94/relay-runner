import Foundation
import RelayRemoteKit
import RelayRemoteProtocol
import UserNotifications

/// A local notification as the app posts it.
struct LocalNotification: Equatable {
    let id: String
    let title: String
    let body: String
    let threadID: String?
    /// The agent whose chat a tap opens; nil opens the app as it was.
    let agent: String?
}

/// The part of `UNUserNotificationCenter` the app uses, faked in tests.
@MainActor
protocol LocalNotificationCenter: AnyObject {
    func isAuthorized() async -> Bool
    func post(_ notification: LocalNotification)
    func removeDelivered(threadID: String)
    func removeDelivered(ids: [String])
}

/// Reply notifications while the app is in the background (RR-545). Local
/// notifications only: the app posts them itself while it stays alive in the
/// background, holding its audio session so it keeps its connection to the
/// Mac. No push service is involved. With the Reply notifications preference
/// off, or notification permission not granted, it does nothing and the app
/// backgrounds as it always did.
@MainActor
final class ReplyNotifier {
    static let lostConnectionID = "connection.lost"
    static let lostConnectionText = "Lost connection to your Mac. Open to reconnect."
    static let agentKey = "agent"

    static func threadID(_ agent: String) -> String { "agent.\(agent)" }

    /// The lifecycle decision: whether going to the background keeps the
    /// audio session and the channel to the Mac open.
    static func keepsAlive(preferenceOn: Bool, authorized: Bool, sessionUsable: Bool) -> Bool {
        preferenceOn && authorized && sessionUsable
    }

    /// Holds (true) or releases (false) the audio session for the background;
    /// returns whether it is held. Set by the app to the voice layer's.
    var holdAudio: ((Bool) -> Bool)?
    private(set) var isForeground = true
    /// True while the audio session is held for notifications in the background.
    private(set) var isKeepingAlive = false

    private let center: LocalNotificationCenter
    private let preference: ReplyNotificationsPreference
    private var authorized = false
    private var assembler = ReplyNotificationAssembler()
    private var loss = ConnectionLossWatch()

    init(center: LocalNotificationCenter, preference: ReplyNotificationsPreference = ReplyNotificationsPreference()) {
        self.center = center
        self.preference = preference
    }

    /// Reads the iOS permission; called at launch and each time the app is opened,
    /// since it changes only in iOS Settings or at a prompt.
    func refreshAuthorization() async {
        authorized = await center.isAuthorized()
    }

    /// The app left the foreground. True when it keeps the channel open.
    @discardableResult
    func enteredBackground(sessionUsable: Bool) -> Bool {
        isForeground = false
        guard Self.keepsAlive(preferenceOn: preference.isOn, authorized: authorized,
                              sessionUsable: sessionUsable) else { return false }
        isKeepingAlive = holdAudio?(true) ?? false
        return isKeepingAlive
    }

    /// The app was opened: release the audio hold, allow a new lost-connection
    /// notice, and clear what is delivered for the chat on screen.
    func enteredForeground(showing agent: String) {
        isForeground = true
        loss = ConnectionLossWatch()
        release()
        center.removeDelivered(threadID: Self.threadID(agent))
        center.removeDelivered(ids: [Self.lostConnectionID])
    }

    /// An agent's chat was opened, for example from a notification.
    func chatOpened(_ agent: String) {
        center.removeDelivered(threadID: Self.threadID(agent))
    }

    /// Every `speech` frame, with the agent it was filed under. A reply that
    /// ends while the app is in the background posts one notification.
    func receive(_ speech: Speech, agent: String) {
        let replies = assembler.receive(speech, agent: agent)
        guard !isForeground, isKeepingAlive else { return }
        for reply in replies {
            center.post(LocalNotification(id: "reply.\(reply.agent).\(reply.seq)", title: AgentsModel.name(reply.agent),
                                          body: reply.body, threadID: Self.threadID(reply.agent), agent: reply.agent))
        }
    }

    /// Every session state. In the background a connection that does not come
    /// back posts the lost-connection notice once and releases the audio hold,
    /// so the app stops holding the microphone and speaker and suspends.
    func sessionStateChanged(_ state: RemoteSession.State) {
        guard !isForeground, isKeepingAlive, loss.observe(state) else { return }
        center.post(LocalNotification(id: Self.lostConnectionID, title: "Relay Remote", body: Self.lostConnectionText,
                                      threadID: nil, agent: nil))
        release()
    }

    private func release() {
        guard isKeepingAlive else { return }
        isKeepingAlive = false
        _ = holdAudio?(false)
    }
}

/// The app's `UNUserNotificationCenter`.
@MainActor
final class SystemNotificationCenter: LocalNotificationCenter {
    private let center = UNUserNotificationCenter.current()

    func isAuthorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied, .notDetermined: return false
        @unknown default: return false
        }
    }

    func post(_ notification: LocalNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        if let threadID = notification.threadID { content.threadIdentifier = threadID }
        if let agent = notification.agent { content.userInfo = [ReplyNotifier.agentKey: agent] }
        center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    func removeDelivered(threadID: String) {
        let center = center
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == threadID }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    func removeDelivered(ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Receives taps on the app's notifications (RR-545). It is the notification
/// centre's delegate from launch, so a tap that relaunched the app arrives too.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// Opens an agent's chat; set once the app model exists.
    @MainActor var openAgent: ((String) -> Void)? {
        didSet { if let pending = pendingAgent, let openAgent { pendingAgent = nil; openAgent(pending) } }
    }
    @MainActor private var pendingAgent: String?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        // Nothing is posted in the foreground; the chat already shows the reply.
        []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let agent = response.notification.request.content.userInfo[ReplyNotifier.agentKey] as? String
        else { return }
        await MainActor.run { open(agent) }
    }

    /// Opens `agent`'s chat now, or once `openAgent` is set.
    @MainActor
    func open(_ agent: String) {
        if let openAgent { openAgent(agent) } else { pendingAgent = agent }
    }
}
