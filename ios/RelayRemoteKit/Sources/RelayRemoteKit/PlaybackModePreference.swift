import Foundation

/// The phone's playback mode as stored in `UserDefaults` (RR-458). Auto-play
/// unless the user chose to play replies on demand.
public struct PlaybackModePreference {
    public static let key = "playbackMode"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var mode: PlaybackMode {
        get { (defaults.string(forKey: Self.key)).flatMap(PlaybackMode.init(rawValue:)) ?? .autoPlay }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}
