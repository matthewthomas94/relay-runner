import SwiftUI
import UIKit

/// The colours and reach of a state glow, from the desktop's `ParticleFieldRenderer.Theme`.
struct DotFieldStyle: Hashable {
    let hue: CGFloat
    let saturation: CGFloat
    /// Fraction of the view's height the field covers, from the bottom.
    let coverage: CGFloat
    /// RGB tint blended into dots at the base of the field.
    let highlight: SIMD3<Double>

    /// While the user talks: the desktop's STT colours over the bottom 32%.
    static let listening = DotFieldStyle(hue: 0.04, saturation: 0.95, coverage: 0.32,
                                         highlight: SIMD3(1.000, 0.965, 0.900))
    /// While a reply plays: the desktop's TTS colours over the bottom 44%.
    static let playback = DotFieldStyle(hue: 0.68, saturation: 0.80, coverage: 0.44,
                                        highlight: SIMD3(0.992, 0.918, 0.859))
}

/// The app-wide state glow: a port of `buildDotGrid` from the desktop's
/// `ParticleFieldRenderer` on an 8 pt grid, slightly brightened for the phone.
/// Dots grow toward the bottom centre and ripple with diagonal waves. It
/// fills its frame and draws only in the bottom `style.coverage` of it; it
/// holds still with Reduce Motion on.
struct DotField: View, Animatable {
    let style: DotFieldStyle
    /// 0 hides the field and 1 shows all of it. In between, the field rises
    /// from the bottom, so animating this fades it up.
    var reveal: Double = 1
    /// The dots' size, 0 to their own: as the field pushes up from the
    /// bottom edge its dots grow from nothing, and shrink as it sinks
    /// (user, 2026-11-28).
    var growth: Double = 1

    var animatableData: Double {
        get { growth }
        set { growth = newValue }
    }

    @State private var cache = DotFieldCache()
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || reveal <= 0)) { timeline in
            Canvas { context, size in
                guard reveal > 0, growth > 0 else { return }
                let grown = CGFloat(min(1, growth))
                let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
                for dot in cache.grid(style: style, size: size) {
                    let wave = DotFieldCache.wave(x: dot.x, y: dot.fieldY, elapsed: elapsed)
                    let radius = dot.radius * (1 + wave * 0.2) * grown
                    let alpha = dot.alpha * (1 + Double(wave) * 0.1) * Self.revealFactor(reveal, verticalT: dot.verticalT)
                    guard radius > 0.1, alpha > 0.002 else { continue }
                    context.fill(
                        Path(ellipseIn: CGRect(x: dot.x - radius, y: dot.y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(Color(.sRGB, red: dot.rgb.x, green: dot.rgb.y, blue: dot.rgb.z,
                                           opacity: min(1, alpha))))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// How much of a row at `verticalT` (0 bottom, 1 top of the field) shows
    /// at `reveal`: a soft edge that rises from the bottom.
    static func revealFactor(_ reveal: Double, verticalT: Double) -> Double {
        let band = 0.35
        return RelayMotion.smoothstep((min(1, max(0, reveal)) * (1 + band) - verticalT) / band)
    }
}

/// Builds the field's dots once per size and style.
final class DotFieldCache {
    struct Dot {
        /// Centre in SwiftUI's y-down coordinates.
        let x: CGFloat
        let y: CGFloat
        /// Height above the bottom edge, as the desktop's wave expects.
        let fieldY: CGFloat
        let verticalT: Double
        let radius: CGFloat
        let alpha: Double
        let rgb: SIMD3<Double>
    }

    static let spacing: CGFloat = 8
    static let maxDotRadius: CGFloat = 3
    static let minDotRadius: CGFloat = 0.3
    /// The phone's lift over the desktop field.
    static let alphaBoost = 1.2
    static let brightnessBoost: CGFloat = 0.1

    private var key: (DotFieldStyle, CGSize)?
    private var dots: [Dot] = []

    func grid(style: DotFieldStyle, size: CGSize) -> [Dot] {
        if let key, key.0 == style, key.1 == size { return dots }
        key = (style, size)
        dots = Self.build(style: style, size: size)
        return dots
    }

    /// Diagonal waves at different angles and speeds, as on the desktop.
    static func wave(x: CGFloat, y: CGFloat, elapsed: Double) -> CGFloat {
        let wave1 = sin(Double(x) * 0.012 - Double(y) * 0.008 - elapsed * 4.2)
        let wave2 = sin(Double(x) * 0.007 + Double(y) * 0.011 - elapsed * 2.7) * 0.4
        let wave3 = sin(Double(x) * 0.004 - elapsed * 1.1) * 0.3
        return CGFloat(wave1 + wave2 + wave3) / 1.7
    }

    static func build(style: DotFieldStyle, size: CGSize) -> [Dot] {
        let fieldHeight = size.height * style.coverage
        guard size.width > 0, fieldHeight > 0 else { return [] }
        let cols = Int(size.width / spacing) + 1
        let rows = Int(fieldHeight / spacing) + 1
        let centerX = size.width / 2
        let sigma = size.width * 0.45
        var result: [Dot] = []
        result.reserveCapacity(cols * rows)
        // Deterministic pseudo-random colour variation, as on the desktop.
        var seed: UInt64 = 12345
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max)
        }
        for row in 0..<rows {
            for col in 0..<cols {
                let x = CGFloat(col) * spacing + spacing / 2
                let fieldY = CGFloat(row) * spacing + spacing / 2
                let verticalT = CGFloat(row) / CGFloat(max(1, rows - 1))
                let dx = x - centerX
                let combined = pow(1 - verticalT, 1.6) * exp(-(dx * dx) / (2 * sigma * sigma))
                guard combined > 0.02 else { continue }
                let radius = minDotRadius + (maxDotRadius - minDotRadius) * combined
                let alpha = (0.2 + 0.6 * Double(combined)) * alphaBoost

                let r1 = next(), r2 = next(), r3 = next()
                let hue = style.hue + (r1 - 0.5) * 0.08
                let saturation = max(0.1, min(1, style.saturation + (r2 - 0.5) * 0.2))
                let brightness = max(0.4, min(1, 0.7 + brightnessBoost + (r3 - 0.5) * 0.3))
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, a: CGFloat = 0
                UIColor(hue: (hue + 1).truncatingRemainder(dividingBy: 1), saturation: saturation,
                        brightness: brightness, alpha: 1)
                    .getRed(&red, green: &green, blue: &blue, alpha: &a)
                // Lift toward the highlight at the base of the field.
                let lift = Double(pow(1 - verticalT, 3) * 0.70)
                let base = SIMD3(Double(red), Double(green), Double(blue))
                let rgb = base * (1 - lift) + style.highlight * lift
                result.append(Dot(x: x, y: size.height - fieldY, fieldY: fieldY, verticalT: Double(verticalT),
                                  radius: radius, alpha: alpha, rgb: rgb))
            }
        }
        return result
    }
}
