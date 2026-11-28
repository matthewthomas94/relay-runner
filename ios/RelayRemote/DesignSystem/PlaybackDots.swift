import SwiftUI
import UIKit

extension View {
    /// The Relay Vision dot matrix round this view's edge, in the playback
    /// glow's colours (user, 2026-11-28): on the reply the dock's Play will
    /// play and on Play itself, so the two read as one. It comes into focus
    /// as it fades in and blurs away as it leaves, as the Mac's does.
    func playbackDots(active: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            PlaybackDots(active: active)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                // Lightens only: white text under the dots stays white.
                .blendMode(.plusLighter)
                .opacity(active ? 0.75 : 0)
                .blur(radius: active ? 0 : PlaybackDots.focusBlur)
                .animation(RelayMotion.enter, value: active)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A port of the Mac's `PerimeterParticleField` (the Relay Vision edge
/// glow) to a view's own frame: the halftone dot grid of the state glows,
/// densest and largest at the edges and fading inward, coloured as the
/// playback glow with the edge dots lifted toward its warm highlight, moved
/// by the same two diagonal swells, two radial ripples and slow breath. The
/// Mac's wave lengths are for a whole screen; here positions are scaled to a
/// screen-sized space first, so the waves move through a bubble as they do
/// across a screen.
struct PlaybackDots: View {
    let active: Bool

    @State private var cache = PlaybackDotsCache()
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let focusBlur: CGFloat = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !active)) { timeline in
            Canvas { context, size in
                let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
                let breath = 0.92 + 0.12 * CGFloat(sin(elapsed * 0.6))
                for dot in cache.grid(size: size) {
                    let wave1 = sin(dot.sx * 0.0042 - dot.sy * 0.0028 - elapsed * 2.8)
                    let wave2 = sin(dot.sx * 0.0028 + dot.sy * 0.0048 - elapsed * 1.9) * 0.7
                    let wave3 = sin(dot.fromCenter * 0.0095 - elapsed * 1.4) * 0.55
                    let wave4 = sin(dot.fromOffset * 0.0072 + elapsed * 0.95) * 0.45
                    let wave = CGFloat(wave1 + wave2 + wave3 + wave4) / 2.2
                    let radius = dot.radius * (1 + wave * 0.55) * breath
                    let alpha = dot.alpha * (1 + wave * 0.45) * breath
                    guard radius > 0.1, alpha > 0.02 else { continue }
                    context.fill(Path(ellipseIn: CGRect(x: dot.x - radius, y: dot.y - radius,
                                                        width: radius * 2, height: radius * 2)),
                                 with: .color(Color(.sRGB, red: dot.rgb.x, green: dot.rgb.y, blue: dot.rgb.z,
                                                    opacity: min(1, Double(alpha)))))
                }
            }
        }
    }
}

/// The dots for one size, built once.
final class PlaybackDotsCache {
    struct Dot {
        let x: CGFloat
        let y: CGFloat
        /// Position in the screen-sized space the Mac's waves are tuned for.
        let sx: Double
        let sy: Double
        let fromCenter: Double
        let fromOffset: Double
        let radius: CGFloat
        let alpha: CGFloat
        let rgb: SIMD3<Double>
    }

    /// The Mac's grid is 8 pt with 3 pt dots across a screen; a bubble or a
    /// button needs a finer one to show the pattern at all.
    static let spacing: CGFloat = 5
    static let maxDotRadius: CGFloat = 1.8
    static let minDotRadius: CGFloat = 0.3
    /// The Mac's band (35% of the shorter side) and soft falloff.
    static let thicknessFraction: CGFloat = 0.35
    static let falloffExponent: CGFloat = 0.9
    /// The width of the space the Mac's wave lengths are tuned for.
    static let screenWidth: CGFloat = 1200

    private var size: CGSize?
    private var dots: [Dot] = []

    func grid(size: CGSize) -> [Dot] {
        if size == self.size { return dots }
        self.size = size
        dots = Self.build(size: size)
        return dots
    }

    static func build(size: CGSize) -> [Dot] {
        guard size.width > 0, size.height > 0 else { return [] }
        let style = DotFieldStyle.playback
        let thickness = min(size.width, size.height) * thicknessFraction
        let toScreen = screenWidth / size.width
        let cols = Int(size.width / spacing) + 1
        let rows = Int(size.height / spacing) + 1
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let offset = CGPoint(x: size.width * 0.32, y: size.height * 0.68)
        var seed: UInt64 = 12345
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max)
        }
        var result: [Dot] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let x = CGFloat(col) * spacing + spacing / 2
                let y = CGFloat(row) * spacing + spacing / 2
                let fromEdge = min(x, size.width - x, y, size.height - y)
                guard fromEdge < thickness else { continue }
                let edge = pow(1 - fromEdge / thickness, falloffExponent)
                guard edge > 0.015 else { continue }

                let r1 = next(), r2 = next(), r3 = next()
                let hue = style.hue + (r1 - 0.5) * 0.08
                let saturation = max(0.1, min(1, style.saturation + (r2 - 0.5) * 0.2))
                let brightness = max(0.4, min(1, 0.7 + (r3 - 0.5) * 0.3))
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, a: CGFloat = 0
                UIColor(hue: (hue + 1).truncatingRemainder(dividingBy: 1), saturation: saturation,
                        brightness: brightness, alpha: 1)
                    .getRed(&red, green: &green, blue: &blue, alpha: &a)
                // The dots at the very edge lift toward the highlight.
                let lift = Double(pow(edge, 3) * 0.70)
                let rgb = SIMD3(Double(red), Double(green), Double(blue)) * (1 - lift) + style.highlight * lift

                result.append(Dot(
                    x: x, y: y,
                    sx: Double(x * toScreen), sy: Double(y * toScreen),
                    fromCenter: Double(hypot(x - center.x, y - center.y) * toScreen),
                    fromOffset: Double(hypot(x - offset.x, y - offset.y) * toScreen),
                    radius: minDotRadius + (maxDotRadius - minDotRadius) * edge,
                    alpha: 0.2 + 0.6 * edge,
                    rgb: rgb))
            }
        }
        return result
    }
}
