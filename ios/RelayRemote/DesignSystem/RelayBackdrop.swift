import SwiftUI

/// The backdrop behind the app's screens (Figma "Jet black", user
/// 2026-11-28): a cool grey (#9caab5) under black that is solid at the top,
/// 90% at 78% of the way down and 85% at the bottom, so the foot of the
/// screen lifts just off black.
struct RelayBackdrop: View {
    static let base = Color(red: 0.613, green: 0.667, blue: 0.709)

    var body: some View {
        Self.base
            .overlay(LinearGradient(stops: [.init(color: .black, location: 0),
                                            .init(color: .black.opacity(0.9), location: 0.779),
                                            .init(color: .black.opacity(0.85), location: 1)],
                                    startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
