import SwiftUI

/// Tutorial (15–20): hold to talk, release to send, play and stop a reply,
/// over the real dock and tab bar. A placeholder until RR-542.
struct TutorialView: View {
    let model: AppModel
    let onFinished: () -> Void

    var body: some View {
        OnboardingHeroLayout(hero: "Tutorial", onSkip: onFinished,
                             action: OnboardingAction(title: "Continue", perform: onFinished))
    }
}
