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
}
