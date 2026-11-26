import Foundation

/// Whether each agent reply posts a local notification while the app runs in
/// the background (Settings › Voice › Reply notifications), stored in
/// `UserDefaults`. On unless the user turned it off.
struct ReplyNotificationsPreference {
    static let key = "replyNotifications"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isOn: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
