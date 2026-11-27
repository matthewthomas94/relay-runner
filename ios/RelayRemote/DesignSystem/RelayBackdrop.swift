import SwiftUI

/// The faint backdrop behind the app's screens in the final Figma designs
/// (screens 21–27): a soft, light abstract wash under a black gradient that
/// is solid at the top and lets about 30% through at the bottom. The glass
/// panels need something behind them to refract; on flat black they read as
/// plain grey boxes. The Figma frames use a wallpaper photo for the wash; this
/// draws a lookalike instead of shipping that image. Onboarding stays black.
struct RelayBackdrop: View {
    var body: some View {
        ZStack {
            wash
            // Figma's "Backdrop" layer: black 100% → 92% at 72% → 70%.
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.92), location: 0.72),
                .init(color: .black.opacity(0.7), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Warm sand on the left fading to lavender and pale grey on the right,
    /// with sweeping light bands like the folded-paper photo in the designs.
    private var wash: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(colors: [Color(red: 0.72, green: 0.64, blue: 0.52),
                                        Color(red: 0.80, green: 0.77, blue: 0.70),
                                        Color(red: 0.50, green: 0.48, blue: 0.60),
                                        Color(red: 0.78, green: 0.79, blue: 0.82)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(0..<3) { band in
                    Ellipse()
                        .stroke(Color.white.opacity(0.55), lineWidth: 18)
                        .frame(width: size.width * 1.9, height: size.height * 0.9)
                        .rotationEffect(.degrees(-28))
                        .offset(x: size.width * (0.35 + 0.22 * Double(band)), y: size.height * (0.12 + 0.1 * Double(band)))
                        .blur(radius: 14)
                }
                Ellipse()
                    .fill(Color(red: 0.36, green: 0.34, blue: 0.48).opacity(0.6))
                    .frame(width: size.width * 1.2, height: size.height * 0.5)
                    .rotationEffect(.degrees(-30))
                    .offset(x: size.width * 0.15, y: size.height * 0.35)
                    .blur(radius: 40)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }
}
