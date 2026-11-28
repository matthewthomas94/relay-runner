import SwiftUI
import UIKit

extension View {
    /// The Relay Vision dot matrix round this view's edge, in the playback
    /// glow's colours (user, 2026-11-28): on the reply the dock's Play will
    /// play and on Play itself, so the two read as one. It comes into focus
    /// as it fades in and blurs away as it leaves, as the Mac's does.
    func playbackDots(active: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            PlaybackDots(active: active, cornerRadius: cornerRadius)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                // Lightens only: white text under the dots stays white.
                .blendMode(.plusLighter)
                .opacity(active ? PlaybackDots.restOpacity : 0)
                .blur(radius: active ? 0 : PlaybackDots.focusBlur)
                .animation(RelayMotion.enter, value: active)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A port of the Mac's `PerimeterParticleField` (the Relay Vision edge
/// glow) to a view's own frame: a thin band of dots just inside its rounded
/// edge, largest at the edge and fading inward, coloured as the
/// playback glow with the edge dots lifted toward its warm highlight and
/// breathing as the Mac's do. The Mac's swells cross a whole screen; on a
/// bubble or a button they only swept across it, so here they run round the
/// edge instead (user, 2026-11-28).
struct PlaybackDots: View {
    let active: Bool
    let cornerRadius: CGFloat

    @State private var cache = PlaybackDotsCache()
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let focusBlur: CGFloat = 8
    /// Fainter than the Mac's 0.75: a trim, not a glow (user, 2026-11-28).
    static let restOpacity: Double = 0.55

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !active)) { timeline in
            Canvas { context, size in
                let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
                let breath = 0.92 + 0.12 * CGFloat(sin(elapsed * 0.6))
                for dot in cache.dots(size: size, cornerRadius: cornerRadius) {
                    // Clockwise round the edge: a lap-long swell under two
                    // shorter ones, all running the same way.
                    let lap = dot.along * 2 * .pi
                    let wave1 = sin(lap * 3 - elapsed * 2.8)
                    let wave2 = sin(lap * 2 - elapsed * 1.9) * 0.7
                    let wave3 = sin(lap - elapsed * 1.4) * 0.55
                    let wave = CGFloat(wave1 + wave2 + wave3) / 2.25
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
        /// How far round the edge, 0 to 1 clockwise from the top left.
        let along: Double
        let radius: CGFloat
        let alpha: CGFloat
        let rgb: SIMD3<Double>
    }

    /// The Mac's dots sit on a square grid masked to a band 35% of the
    /// screen deep. On a bubble or a button that reached well into the text
    /// and squared off the corners (user, 2026-11-28), so here the dots run
    /// in rows along the edge itself, each row inset from the last and
    /// rounding the corners with the shape: three rows, about 9 pt deep.
    static let rowGap: CGFloat = 3
    static let rows = 3
    static let dotGap: CGFloat = 3
    static let maxDotRadius: CGFloat = 1.1
    static let minDotRadius: CGFloat = 0.35
    private var key: [CGFloat] = []
    private var cached: [Dot] = []

    func dots(size: CGSize, cornerRadius: CGFloat) -> [Dot] {
        let key = [size.width, size.height, cornerRadius]
        if key == self.key { return cached }
        self.key = key
        cached = Self.build(size: size, cornerRadius: cornerRadius)
        return cached
    }

    static func build(size: CGSize, cornerRadius: CGFloat) -> [Dot] {
        guard size.width > 0, size.height > 0 else { return [] }
        let style = DotFieldStyle.playback
        let depth = rowGap * CGFloat(rows)
        var seed: UInt64 = 12345
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max)
        }
        var result: [Dot] = []
        for row in 0..<rows {
            let inset = rowGap / 2 + CGFloat(row) * rowGap
            let ring = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            guard ring.width > 0, ring.height > 0 else { break }
            let edge = pow(1 - inset / depth, 0.9)
            let radius = min(max(cornerRadius - inset, 0), ring.width / 2, ring.height / 2)
            for point in Self.points(along: ring, cornerRadius: radius, gap: dotGap) {
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
                    x: point.position.x, y: point.position.y,
                    along: point.along,
                    radius: minDotRadius + (maxDotRadius - minDotRadius) * edge,
                    alpha: 0.2 + 0.6 * edge,
                    rgb: rgb))
            }
        }
        return result
    }

    /// Points about `gap` apart round a rounded rectangle, evenly spaced
    /// over its whole length, each with how far round it is (0 to 1).
    static func points(along rect: CGRect, cornerRadius r: CGFloat,
                       gap: CGFloat) -> [(position: CGPoint, along: Double)] {
        let straightX = rect.width - 2 * r
        let straightY = rect.height - 2 * r
        let arc = CGFloat.pi / 2 * r
        let length = 2 * straightX + 2 * straightY + 4 * arc
        guard length > 0 else { return [] }
        let count = max(1, Int((length / gap).rounded()))
        let step = length / CGFloat(count)
        // Clockwise from the top edge's left end: top, top-right corner,
        // right, bottom-right, bottom, bottom-left, left, top-left.
        func point(at distance: CGFloat) -> CGPoint {
            var d = distance
            func corner(_ cx: CGFloat, _ cy: CGFloat, from angle: CGFloat) -> CGPoint {
                let a = angle + d / max(r, 0.0001)
                return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            }
            if d < straightX { return CGPoint(x: rect.minX + r + d, y: rect.minY) }
            d -= straightX
            if d < arc { return corner(rect.maxX - r, rect.minY + r, from: -.pi / 2) }
            d -= arc
            if d < straightY { return CGPoint(x: rect.maxX, y: rect.minY + r + d) }
            d -= straightY
            if d < arc { return corner(rect.maxX - r, rect.maxY - r, from: 0) }
            d -= arc
            if d < straightX { return CGPoint(x: rect.maxX - r - d, y: rect.maxY) }
            d -= straightX
            if d < arc { return corner(rect.minX + r, rect.maxY - r, from: .pi / 2) }
            d -= arc
            if d < straightY { return CGPoint(x: rect.minX, y: rect.maxY - r - d) }
            d -= straightY
            return corner(rect.minX + r, rect.minY + r, from: .pi)
        }
        return (0..<count).map { (point(at: CGFloat($0) * step), Double($0) / Double(count)) }
    }
}
