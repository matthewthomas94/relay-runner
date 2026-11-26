import Foundation

/// The stages of the app. First launch walks splash → permissions → pairing
/// → tutorial → app. Later launches open the app when the phone is paired and
/// pairing when it is not.
enum AppStage: String, CaseIterable {
    case splash, permissions, pairing, tutorial, app
}

enum AppFlow {
    /// Where a launch starts.
    static func initialStage(onboardingFinished: Bool, paired: Bool) -> AppStage {
        guard onboardingFinished else { return .splash }
        return paired ? .app : .pairing
    }

    /// The stage after `stage` finishes. Pairing again after onboarding goes
    /// straight back to the app, without the tutorial.
    static func stage(after stage: AppStage, onboardingFinished: Bool) -> AppStage {
        switch stage {
        case .splash: return .permissions
        case .permissions: return .pairing
        case .pairing: return onboardingFinished ? .app : .tutorial
        case .tutorial, .app: return .app
        }
    }
}
