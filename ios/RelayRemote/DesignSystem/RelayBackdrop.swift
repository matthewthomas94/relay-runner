import SwiftUI

/// The backdrop behind the app's screens: pure black (user, 2026-11-27).
/// The Figma frames' wallpaper wash under a black gradient read as a fade
/// up the screen; the glass is tuned against black instead.
struct RelayBackdrop: View {
    var body: some View {
        Color.black
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
