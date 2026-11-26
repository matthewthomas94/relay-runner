import SwiftUI

/// Splash (01–05): the port of the desktop intro. A placeholder until RR-537.
struct SplashView: View {
    let onFinished: () -> Void

    var body: some View {
        OnboardingHeroLayout(hero: "Splash",
                             action: OnboardingAction(title: "Continue", perform: onFinished))
    }
}
