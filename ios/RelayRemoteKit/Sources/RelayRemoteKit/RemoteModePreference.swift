import Foundation

/// The phone's Remote mode switch as stored in `UserDefaults` (RR-454). On
/// unless the user turned it off, so a fresh install drives the Mac as before.
public struct RemoteModePreference {
    public static let key = "remoteMode"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isOn: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
