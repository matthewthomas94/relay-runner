import Foundation

/// How the Talk control works (Settings › Voice › Talk). There is no
/// hands-free mode in the final design.
enum TalkMode: String, CaseIterable {
    /// Talk while the button is held; release sends.
    case hold
    /// Tap to start talking and tap again to send.
    case toggle
}

/// The talk mode as stored in `UserDefaults`, following the kit's
/// `PlaybackModePreference`. Hold unless the user chose Toggle.
struct TalkModePreference {
    static let key = "talkMode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var mode: TalkMode {
        get { defaults.string(forKey: Self.key).flatMap(TalkMode.init(rawValue:)) ?? .hold }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}
