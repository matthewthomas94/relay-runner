import SwiftUI

/// Permissions (06–11): microphone, speech recognition, local network,
/// camera, notifications. A placeholder until RR-538.
struct PermissionsFlowView: View {
    let onFinished: () -> Void

    var body: some View {
        OnboardingHeroLayout(hero: "Permissions", onSkip: onFinished,
                             action: OnboardingAction(title: "Continue", perform: onFinished))
    }
}
