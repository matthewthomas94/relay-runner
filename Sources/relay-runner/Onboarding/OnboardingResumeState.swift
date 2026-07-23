import Foundation

enum OnboardingStepID: String, CaseIterable {
    case welcome
    case agentChoice
    case microphone
    case inputMonitoring
    case parentAccessibility
    case parentScreenRecording
    /// Legacy resume value from builds that showed one combined parent
    /// permission screen.
    case parentPermissions
    case pythonSetup
    case agentLogin
    case ready
    case tutorialIntro
    case tutorialRecording
    case tutorialPlayback
    case tutorialWorkspace
    case tutorialSessionRetry
}

enum OnboardingResumeState {
    struct Snapshot: Equatable {
        let step: OnboardingStepID
        let provider: GeneralConfig.AgentProvider
        let parentPermissionsReviewed: Bool
    }

    private static let stepKey = "com.relayrunner.onboarding.resume.step"
    private static let providerKey = "com.relayrunner.onboarding.resume.provider"
    private static let parentReviewedKey = "com.relayrunner.onboarding.resume.parentPermissionsReviewed"

    static func save(step: OnboardingStepID,
                     provider: GeneralConfig.AgentProvider,
                     parentPermissionsReviewed: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(step.rawValue, forKey: stepKey)
        defaults.set(provider.rawValue, forKey: providerKey)
        defaults.set(parentPermissionsReviewed, forKey: parentReviewedKey)
    }

    static func load() -> Snapshot? {
        let defaults = UserDefaults.standard
        guard let rawStep = defaults.string(forKey: stepKey),
              let step = OnboardingStepID(rawValue: rawStep) else {
            return nil
        }
        let rawProvider = defaults.string(forKey: providerKey)
        let provider = rawProvider
            .flatMap { GeneralConfig.AgentProvider(rawValue: $0) }
            ?? .codex
        return Snapshot(
            step: step,
            provider: provider,
            parentPermissionsReviewed: defaults.bool(forKey: parentReviewedKey)
        )
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: stepKey)
        defaults.removeObject(forKey: providerKey)
        defaults.removeObject(forKey: parentReviewedKey)
    }
}
