import SwiftUI

/// Six independent, interruptible springs share one presentation value for surface and controls.
struct SessionWheelSubmenuProgress: VectorArithmetic {
    private var values = Array(repeating: 0.0, count: SessionWheelGeometry.slotCount)

    init(slot: Int? = nil, progress: Double = 1) {
        if let slot { values[slot] = progress }
    }

    subscript(slot: Int) -> Double { values[slot] }
    static var zero: Self { .init() }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    static func + (lhs: Self, rhs: Self) -> Self {
        var result = lhs
        for index in result.values.indices { result.values[index] += rhs.values[index] }
        return result
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        var result = lhs
        for index in result.values.indices { result.values[index] -= rhs.values[index] }
        return result
    }

    mutating func scale(by rhs: Double) {
        for index in values.indices { values[index] *= rhs }
    }
}

struct SessionWheelSubmenuPresentation {
    let progress: Double
    let reduceMotion: Bool

    init(progress: Double, reduceMotion: Bool = false) {
        self.progress = min(max(progress, 0), 1)
        self.reduceMotion = reduceMotion
    }

    // Start wholly inside the disc, then pull radially out of the hovered segment.
    var scale: CGFloat { reduceMotion ? 1 : 0.68 + 0.32 * progress }
    var surfaceOpacity: Double { reduceMotion ? progress : 1 }
    var blur: CGFloat { reduceMotion ? 0 : 6 * sin(.pi * progress) }
    var controlsOpacity: Double {
        if reduceMotion { return progress }
        let reveal = min(max((progress - 0.3) / 0.65, 0), 1)
        return reveal * reveal * (3 - 2 * reveal)
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: SessionWheelPresentation.reducedDuration)
            : .spring(response: RelayMotion.enterDuration + RelayMotion.replacementGap, dampingFraction: 0.9)
    }
}

/// SwiftUI retargets this vector from the displayed positions and velocities on rapid hover changes.
struct SessionWheelSubmenuAnimation<Content: View>: View, Animatable {
    var progress: SessionWheelSubmenuProgress
    @ViewBuilder var content: (SessionWheelSubmenuProgress) -> Content

    var animatableData: SessionWheelSubmenuProgress {
        get { progress }
        set { progress = newValue }
    }

    var body: some View { content(progress) }
}

/// Native equivalent of liquid-gooey's shared silhouette, kept separate from interactive content.
/// Reference: Libraries.dev d243bdd3, packages/liquid-gooey/src/filter.tsx (blur + alpha threshold).
struct SessionWheelLiquidBackdrop: View {
    let progress: SessionWheelSubmenuProgress
    let reduceMotion: Bool

    var body: some View {
        Canvas { context, size in
            let geometry = SessionWheelGeometry.self
            let rect = CGRect(origin: .zero, size: size)
            let frames = (0..<geometry.slotCount).map {
                SessionWheelSubmenuPresentation(progress: progress[$0], reduceMotion: reduceMotion)
            }
            let blur = frames.map(\.blur).max() ?? 0
            context.drawLayer { liquid in
                if blur > 0.001 {
                    // Apply the blur first, then sharpen its alpha into the joined liquid surface.
                    liquid.addFilter(.alphaThreshold(min: 5.0 / 12.0, color: .black))
                    liquid.addFilter(.blur(radius: blur))
                }
                liquid.drawLayer { shapes in
                    let radius = geometry.wheelRadius
                    shapes.fill(Path(ellipseIn: CGRect(x: rect.midX - radius, y: rect.midY - radius,
                                                        width: radius * 2, height: radius * 2)), with: .color(.black))
                    for slot in 0..<geometry.slotCount where frames[slot].progress > 0 {
                        let frame = frames[slot]
                        let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                                       outerRadius: geometry.actionOuterRadius,
                                                       cornerRadius: SharedActionButtonMetrics.cornerRadius,
                                                       padding: geometry.segmentGap)
                        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                            .scaledBy(x: frame.scale, y: frame.scale)
                            .translatedBy(x: -rect.midX, y: -rect.midY)
                        var surface = shapes
                        surface.opacity = frame.surfaceOpacity
                        surface.fill(shape.path(in: rect).applying(transform), with: .color(.black))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Controls emerge from behind the wheel instead of crossing over its project tiles.
struct SessionWheelSubmenuExterior: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let radius = SessionWheelGeometry.wheelRadius
        path.addEllipse(in: CGRect(x: rect.midX - radius, y: rect.midY - radius,
                                   width: radius * 2, height: radius * 2))
        return path
    }
}
