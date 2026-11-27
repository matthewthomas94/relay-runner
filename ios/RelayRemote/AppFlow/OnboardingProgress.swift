import Foundation

/// Whether the user has walked the first-launch onboarding to the end,
/// stored in `UserDefaults`.
struct OnboardingProgress {
    static let key = "onboardingFinished"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isFinished: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    static let replayKey = "onboardingReplay"

    /// Set by Settings › Testing › Redo onboarding: the next walk shows every
    /// permission step even when it is already decided, and skips pairing
    /// while the phone is still paired. Cleared when the tutorial finishes.
    var isReplaying: Bool {
        get { defaults.bool(forKey: Self.replayKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.replayKey) }
    }
}
