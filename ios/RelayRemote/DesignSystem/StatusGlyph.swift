import SwiftUI

/// What an agent is doing, as the four-dot status glyph shows it.
enum StatusGlyphState: String, CaseIterable, Equatable {
    /// Not running: one grey (#596069) 3 pt dot.
    case off
    /// Ready: four static white dots.
    case ready
    /// Working: the four dots spin.
    case working
    /// Listening: the core spins and orange (#f2700c) dots pulse out from it.
    case listening
    /// Playing back: as listening, in purple (#2b11e8).
    case playing

    var animates: Bool { self == .working || self == .listening || self == .playing }
}

/// A port of the desktop notch glyph (`NotchStatusGlyph`, `NotchStatusGlyphMotion`
/// and the glyph change in `NotchContentMotion`) to a 24 × 24 pt artwork, with
/// the phone's extra stopped state. Coming online, the grey dot splits into the
/// four white dots.
struct StatusGlyph: View {
    let state: StatusGlyphState
    var size: CGFloat = 24

    @State private var source: StatusGlyphState?
    @State private var changedAt = Date.distantPast
    @State private var changing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !needsFrames)) { timeline in
            Canvas { context, canvasSize in
                let scale = min(canvasSize.width, canvasSize.height) / StatusGlyphRenderer.artworkSize
                let elapsed = timeline.date.timeIntervalSince(changedAt)
                let progress = reduceMotion ? 1 : min(1, max(0, elapsed / StatusGlyphRenderer.changeDuration))
                let dots = StatusGlyphRenderer.dots(
                    state: state, from: source, progress: progress,
                    time: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
                for dot in dots where dot.alpha > 0.001 {
                    let radius = dot.diameter / 2 * scale
                    let center = CGPoint(x: dot.center.x * scale, y: dot.center.y * scale)
                    context.fill(
                        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(Color(.sRGB, red: dot.color.x, green: dot.color.y, blue: dot.color.z,
                                           opacity: dot.alpha)))
                }
            }
        }
        .frame(width: size, height: size)
        .onChange(of: state) { oldValue, _ in
            source = oldValue
            changedAt = .now
            changing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + StatusGlyphRenderer.changeDuration) {
                if Date.now.timeIntervalSince(changedAt) >= StatusGlyphRenderer.changeDuration { changing = false }
            }
        }
        .accessibilityLabel(Self.accessibilityLabel(state))
    }

    private var needsFrames: Bool {
        !reduceMotion && (state.animates || changing)
    }

    static func accessibilityLabel(_ state: StatusGlyphState) -> String {
        switch state {
        case .off: return "Not running"
        case .ready: return "Ready"
        case .working: return "Working"
        case .listening: return "Listening"
        case .playing: return "Playing back"
        }
    }
}

/// The glyph's geometry and motion, free of any view so tests can check it.
enum StatusGlyphRenderer {
    struct Dot: Equatable {
        var center: CGPoint
        var diameter: CGFloat = 3
        var color: SIMD3<Double>
        var alpha: Double = 1
    }

    static let artworkSize: CGFloat = 24
    static let changeDuration: TimeInterval = 0.45
    static let motionDuration: TimeInterval = 0.6
    static let center = CGPoint(x: 12, y: 12)

    static let white = SIMD3<Double>(1, 1, 1)
    static let grey = SIMD3<Double>(0x59 / 255.0, 0x60 / 255.0, 0x69 / 255.0)
    static let orange = SIMD3<Double>(0.949, 0.439, 0.047)
    static let blue = SIMD3<Double>(0.169, 0.067, 0.910)

    private static let core: [CGPoint] = [
        CGPoint(x: 14.5, y: 9.5), CGPoint(x: 9.5, y: 9.5), CGPoint(x: 9.5, y: 14.5), CGPoint(x: 14.5, y: 14.5),
    ]

    /// The resting dots of a state.
    static func restingDots(_ state: StatusGlyphState) -> [Dot] {
        switch state {
        case .off:
            return [Dot(center: center, color: grey)]
        case .ready, .working:
            return core.map { Dot(center: $0, color: white) }
        case .listening:
            return activityDots(accent: orange)
        case .playing:
            return activityDots(accent: blue)
        }
    }

    private static func activityDots(accent: SIMD3<Double>) -> [Dot] {
        let layout: [(CGFloat, CGFloat, Bool)] = [
            (14.5, 9.5, true), (19.5, 9.5, false), (14.5, 4.5, false),
            (9.5, 9.5, true), (4.5, 9.5, false), (9.5, 4.5, false),
            (9.5, 14.5, true), (9.5, 19.5, false), (4.5, 14.5, false),
            (14.5, 14.5, true), (14.5, 19.5, false), (19.5, 14.5, false),
        ]
        return layout.map { x, y, isCore in Dot(center: CGPoint(x: x, y: y), color: isCore ? white : accent) }
    }

    static func isCore(_ point: CGPoint) -> Bool { core.contains(point) }

    /// The dots to draw at `time`, `progress` (0...1) of the way through a
    /// change from `source`. Dots the new state no longer uses retract into
    /// the core and fade; new dots emerge from it. To and from `off` the core
    /// is the single centre dot, so the grey dot splits into four.
    static func dots(state: StatusGlyphState, from source: StatusGlyphState?, progress: Double,
                     time: TimeInterval, reduceMotion: Bool) -> [Dot] {
        let phase = state.animates && !reduceMotion ? motionPhase(at: time) : 0
        let moved: (CGPoint) -> CGPoint = { point in
            state.animates && !reduceMotion ? transformed(point, state: state, phase: phase) : point
        }
        let target = restingDots(state)
        var result: [Dot] = []
        if let source, source != state, progress < 1 {
            let change = RelayMotion.smoothstep(progress)
            let sourceDots = restingDots(source)
            let targetPoints = Set(target.map { PointKey($0.center) })
            var sourceByPoint: [PointKey: Dot] = [:]
            for dot in sourceDots where sourceByPoint[PointKey(dot.center)] == nil {
                sourceByPoint[PointKey(dot.center)] = dot
            }
            for dot in sourceDots where !targetPoints.contains(PointKey(dot.center)) {
                let anchor = state == .off ? center : nearestCore(to: dot.center)
                result.append(Dot(center: interpolate(moved(dot.center), moved(anchor), change),
                                  diameter: dot.diameter, color: dot.color, alpha: dot.alpha * (1 - change)))
            }
            for dot in target {
                if let previous = sourceByPoint[PointKey(dot.center)] {
                    result.append(Dot(center: moved(dot.center), diameter: dot.diameter,
                                      color: mix(previous.color, dot.color, change), alpha: dot.alpha))
                } else {
                    let anchor = source == .off ? center : nearestCore(to: dot.center)
                    let color = source == .off ? mix(grey, dot.color, change) : dot.color
                    result.append(Dot(center: interpolate(moved(anchor), moved(dot.center), change),
                                      diameter: dot.diameter, color: color, alpha: dot.alpha * change))
                }
            }
        } else {
            result = target.map { Dot(center: moved($0.center), diameter: $0.diameter, color: $0.color, alpha: $0.alpha) }
        }
        guard (state == .listening || state == .playing), !reduceMotion else { return result }
        // The desktop's shimmer on the listening and playing glyphs.
        return result.enumerated().map { index, dot in
            var dot = dot
            dot.alpha *= 0.72 + 0.28 * ((sin(time * 5.2 + Double(index) * 0.62) + 1) / 2)
            return dot
        }
    }

    // MARK: Motion, from NotchStatusGlyphMotion

    private static let accentKeyframe = 0.6667
    private static let rotationKeyframe = 0.6683
    private static let halfStepTurn = Double.pi / 4
    private static let easeSamples: [Double] = [
        0, 0.0188, 0.0679, 0.1374, 0.2195, 0.308, 0.3978, 0.4856, 0.5686,
        0.6452, 0.7142, 0.7753, 0.8283, 0.8735, 0.9113, 0.9423, 0.9671,
        0.9866, 1.0014, 1.0123, 1.0198, 1.0247, 1.0274, 1.0283, 1.0281,
        1.0268, 1.025, 1.0227, 1.0202, 1.0177, 1.0152, 1.0128, 1.0106,
        1.0085, 1.0068, 1.0052, 1.0039, 1.0028, 1.0018, 1.0011, 1.0005,
        1, 0.9997, 0.9995, 0.9993, 0.9992, 0.9992, 0.9992, 0.9992,
        0.9993, 0.9993,
    ]

    static func motionPhase(at time: TimeInterval) -> Double {
        let raw = time.truncatingRemainder(dividingBy: motionDuration)
        return (raw >= 0 ? raw : raw + motionDuration) / motionDuration
    }

    static func transformed(_ point: CGPoint, state: StatusGlyphState, phase: Double) -> CGPoint {
        if isCore(point) || point == center {
            return rotated(point, by: coreRotation(phase: phase))
        }
        guard state == .listening || state == .playing else { return point }
        let vector = accentVector(point)
        let amount = phase <= accentKeyframe
            ? ease(phase / accentKeyframe)
            : 1 - ease((phase - accentKeyframe) / (1 - accentKeyframe))
        return CGPoint(x: point.x + vector.x * amount, y: point.y + vector.y * amount)
    }

    static func coreRotation(phase: Double) -> Double {
        if phase <= rotationKeyframe {
            return halfStepTurn * ease(phase / rotationKeyframe)
        }
        return halfStepTurn + halfStepTurn * ease((phase - rotationKeyframe) / (1 - rotationKeyframe))
    }

    private static func ease(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return 0 }
        guard clamped < 1 else { return 1 }
        let scaled = clamped * Double(easeSamples.count - 1)
        let lower = min(Int(scaled), easeSamples.count - 2)
        let fraction = scaled - Double(lower)
        return easeSamples[lower] + (easeSamples[lower + 1] - easeSamples[lower]) * fraction
    }

    private static func accentVector(_ point: CGPoint) -> CGPoint {
        switch (point.x, point.y) {
        case (19.5, _): return CGPoint(x: 1, y: 0)
        case (4.5, _): return CGPoint(x: -1, y: 0)
        case (_, 4.5): return CGPoint(x: 0, y: -1)
        case (_, 19.5): return CGPoint(x: 0, y: 1)
        default: return .zero
        }
    }

    private static func rotated(_ point: CGPoint, by angle: Double) -> CGPoint {
        guard angle != 0 else { return point }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let c = CGFloat(cos(angle))
        let s = CGFloat(sin(angle))
        return CGPoint(x: center.x + dx * c - dy * s, y: center.y + dx * s + dy * c)
    }

    private static func nearestCore(to point: CGPoint) -> CGPoint {
        core.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? center
    }

    private static func interpolate(_ from: CGPoint, _ to: CGPoint, _ amount: Double) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * amount, y: from.y + (to.y - from.y) * amount)
    }

    private static func mix(_ from: SIMD3<Double>, _ to: SIMD3<Double>, _ amount: Double) -> SIMD3<Double> {
        from + (to - from) * amount
    }

    private struct PointKey: Hashable {
        let x: CGFloat
        let y: CGFloat
        init(_ point: CGPoint) { x = point.x; y = point.y }
    }
}
