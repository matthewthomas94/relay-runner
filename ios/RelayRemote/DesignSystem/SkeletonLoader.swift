import QuartzCore
import SwiftUI
import UIKit

// The Mac's skeleton loader (Sources/relay-runner/Overlay/SkeletonLoader.swift),
// ported: a loading state that sketches the screen it stands in for with bare
// shapes. Filled bones are a dot matrix whose dots shimmer as column snakes;
// outlined bones are faint solid lines. The field disintegrates in and out,
// dots arriving and leaving here and there across it. The shimmer and the
// disintegration are Core Animation on the render server, so they cost the
// main thread nothing. Reduce Motion holds the dots still.
//
// Lay a skeleton out with ordinary SwiftUI views, mark its shapes with
// `skeletonBone(radius:)` or `skeletonOutline(radius:)` (or use
// `SkeletonLine`), and wrap it in `SkeletonField`, which draws every bone
// in one layer tree. Give the skeleton `.transition(.relaySkeleton)` and what
// replaces it `.transition(.relayAfterSkeleton)` (user, 2026-11-28).

enum SkeletonMetrics {
    /// The dots' pitch and size, as on the Mac.
    static let dotPitch: CGFloat = 5
    static let dotDiameter: CGFloat = 3
    /// The dots are the bone highlight (#383e46); outlines the bone base
    /// (#171a1e) at a third.
    static let dotColor = UIColor(red: 0x38 / 255, green: 0x3e / 255, blue: 0x46 / 255, alpha: 1)
    static let outlineColor = UIColor(red: 0x17 / 255, green: 0x1a / 255, blue: 0x1e / 255, alpha: 1)
    static let outlineWidth: CGFloat = 1.5
    static let outlineOpacity: Float = 0.33
    /// How long content replacing a skeleton waits: the skeleton's exit and a beat.
    static let replacementDelay: TimeInterval = SkeletonPresence.exitDuration + 0.075
}

/// The column snakes (the Mac's `DotColumnSnakeAnimation`, after Dotm Square
/// 6): in each column a bright head steps one dot along every fifth of a
/// cycle with a dimming tail; alternate columns rise and fall.
enum SkeletonSnake {
    static let cycle: TimeInterval = 1.5 / 1.25
    static let phases = 5
    static let opacityBase: Float = 0.12
    static let opacityMid: Float = 0.42
    static let opacityPeak: Float = 1
    static var levels: [Float] {
        [0.6 * opacityPeak + 0.25 * opacityMid + 0.15 * opacityBase,
         0.3 * opacityPeak + 0.5 * opacityMid + 0.2 * opacityBase,
         0.6 * opacityMid + 0.4 * opacityBase,
         0.2 * opacityMid + 0.8 * opacityBase,
         0.625 * opacityBase]
    }
    static let keyTimes: [NSNumber] = [0, 0.2, 0.4, 0.6, 0.8, 1]

    /// Where a dot sits along its column's snake, 0 (lit first) to 4.
    static func position(column: Int, row: Int) -> Int {
        let raw = column % 2 == 0 ? -row - 1 : row
        return (raw % phases + phases) % phases
    }

    static func delay(forPhase phase: Int) -> TimeInterval {
        Double(phase) / Double(phases) * cycle
    }

    /// The still gradient along a column, for Reduce Motion.
    static func restingOpacity(forPhase phase: Int) -> Float {
        let value = 0.22 + Float(phase) / Float(phases - 1) * 0.66
        let source: [Float] = [0, 0.08, 0.34, 0.94, 1]
        let target: [Float] = [0, opacityBase, opacityMid, opacityPeak, 1]
        for index in 1..<source.count where value <= source[index] {
            let progress = (value - source[index - 1]) / (source[index] - source[index - 1])
            return target[index - 1] + (target[index] - target[index - 1]) * progress
        }
        return 1
    }
}

/// How the field arrives and leaves (the Mac's `DotPresence`): the dots are
/// dealt into scattered cohorts that fade one after another.
enum SkeletonPresence {
    static let cohorts = 24
    static let fade: Double = 0.12
    static let enterDuration: TimeInterval = 0.45
    static let exitDuration: TimeInterval = 0.35

    static func cohort(column: Int, row: Int) -> Int {
        var hash = UInt32(truncatingIfNeeded: column) &* 0x9E37_79B1
        hash = hash &+ UInt32(truncatingIfNeeded: row) &* 0x85EB_CA77
        hash ^= hash >> 16
        hash &*= 0x85EB_CA6B
        hash ^= hash >> 13
        hash &*= 0xC2B2_AE35
        hash ^= hash >> 16
        return Int(hash % UInt32(cohorts))
    }

    static func window(ofCohort cohort: Int) -> (start: Double, end: Double) {
        let start = Double(cohort) / Double(cohorts) * (1 - fade)
        return (start, start + fade)
    }
}

// MARK: - Bones

struct SkeletonBoneSpec: Equatable {
    var rect: CGRect
    /// Negative: fully rounded.
    var radius: CGFloat
    var outline: Bool
}

private struct SkeletonBoneAnchor {
    let anchor: Anchor<CGRect>
    let radius: CGFloat
    let outline: Bool
}

private struct SkeletonBoneKey: PreferenceKey {
    static let defaultValue: [SkeletonBoneAnchor] = []
    static func reduce(value: inout [SkeletonBoneAnchor], nextValue: () -> [SkeletonBoneAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Marks this view's frame as a filled bone: dots that shimmer.
    func skeletonBone(radius: CGFloat? = nil) -> some View {
        // Added to the bones inside, not replacing them.
        transformAnchorPreference(key: SkeletonBoneKey.self, value: .bounds) {
            $0.append(SkeletonBoneAnchor(anchor: $1, radius: radius ?? -1, outline: false))
        }
    }

    /// Marks this view's frame as an outlined bone (a card's edge).
    func skeletonOutline(radius: CGFloat) -> some View {
        transformAnchorPreference(key: SkeletonBoneKey.self, value: .bounds) {
            $0.append(SkeletonBoneAnchor(anchor: $1, radius: radius, outline: true))
        }
    }
}

/// A filled bone of a set height; `width` nil fills the width offered,
/// `fraction` takes that share of it.
struct SkeletonLine: View {
    var width: CGFloat?
    var fraction: CGFloat = 1
    var height: CGFloat = 10

    var body: some View {
        if let width {
            Color.clear.frame(width: width, height: height).skeletonBone(radius: height / 2)
        } else {
            GeometryReader { proxy in
                Color.clear.frame(width: proxy.size.width * fraction, height: height)
                    .skeletonBone(radius: height / 2)
            }
            .frame(height: height)
        }
    }
}

/// Lays out `content` and draws its bones as one dot field over it. The
/// content itself draws nothing; it only places the bones.
struct SkeletonField<Content: View>: View {
    var label: String = "Loading"
    @ViewBuilder let content: Content
    @Environment(\.skeletonPresent) private var present

    var body: some View {
        content
            .overlayPreferenceValue(SkeletonBoneKey.self) { anchors in
                GeometryReader { proxy in
                    SkeletonDots(bones: anchors.map {
                        SkeletonBoneSpec(rect: proxy[$0.anchor], radius: $0.radius, outline: $0.outline)
                    }, present: present)
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}

extension EnvironmentValues {
    /// False while a skeleton leaves: its dots disintegrate out.
    @Entry var skeletonPresent = true
}

private struct SkeletonLeaving: ViewModifier {
    let leaving: Bool

    func body(content: Content) -> some View {
        // The opacity only keeps the view on screen for the transition's
        // length; the dots leave by themselves.
        content.environment(\.skeletonPresent, !leaving).opacity(leaving ? 0.999 : 1)
    }
}

extension AnyTransition {
    /// A skeleton: its dots scatter in by themselves and scatter out as it goes.
    static var relaySkeleton: AnyTransition {
        .asymmetric(insertion: .identity,
                    removal: .modifier(active: SkeletonLeaving(leaving: true), identity: SkeletonLeaving(leaving: false))
                        .animation(.linear(duration: SkeletonPresence.exitDuration)))
    }

    /// Content taking a skeleton's place: it waits for the skeleton to
    /// leave, then fades in from a light blur and a few points down.
    static var relayAfterSkeleton: AnyTransition {
        .asymmetric(insertion: .modifier(active: RelayArrivingModifier(hidden: true),
                                         identity: RelayArrivingModifier(hidden: false))
                        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.32).delay(SkeletonMetrics.replacementDelay)),
                    removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
}

// MARK: - Drawing

private struct SkeletonDots: UIViewRepresentable {
    let bones: [SkeletonBoneSpec]
    let present: Bool

    func makeUIView(context: Context) -> SkeletonDotsView { SkeletonDotsView() }

    func updateUIView(_ view: SkeletonDotsView, context: Context) {
        view.update(bones: bones)
        if !present { view.leave() }
    }
}

final class SkeletonDotsView: UIView {
    private static let shimmerKey = "shimmer"
    private static let presenceKey = "presence"

    private var bones: [SkeletonBoneSpec] = []
    private var cohortLayers: [CALayer] = []
    private var phaseLayers: [[CAShapeLayer]] = []
    private let outlineLayer = CAShapeLayer()
    private var arrived = false
    private var leaving = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        for _ in 0..<SkeletonPresence.cohorts {
            let cohort = CALayer()
            cohort.opacity = 0
            var phases: [CAShapeLayer] = []
            for _ in 0..<SkeletonSnake.phases {
                let phase = CAShapeLayer()
                phase.fillColor = SkeletonMetrics.dotColor.cgColor
                cohort.addSublayer(phase)
                phases.append(phase)
            }
            layer.addSublayer(cohort)
            cohortLayers.append(cohort)
            phaseLayers.append(phases)
        }
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = SkeletonMetrics.outlineColor.cgColor
        outlineLayer.lineWidth = SkeletonMetrics.outlineWidth
        outlineLayer.opacity = 0
        layer.addSublayer(outlineLayer)
        NotificationCenter.default.addObserver(self, selector: #selector(restartShimmer),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    func update(bones: [SkeletonBoneSpec]) {
        guard bones != self.bones else { return }
        self.bones = bones
        redraw()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        restartShimmer()
        if !arrived {
            arrived = true
            animatePresence(arriving: true)
        }
    }

    func leave() {
        guard !leaving else { return }
        leaving = true
        animatePresence(arriving: false)
    }

    private func redraw() {
        let paths: [[CGMutablePath]] = (0..<SkeletonPresence.cohorts).map { _ in
            (0..<SkeletonSnake.phases).map { _ in CGMutablePath() }
        }
        let outlines = CGMutablePath()
        let diameter = SkeletonMetrics.dotDiameter
        for bone in bones {
            let radius = bone.radius < 0 ? min(bone.rect.width, bone.rect.height) / 2 : bone.radius
            if bone.outline {
                let inset = SkeletonMetrics.outlineWidth / 2
                outlines.addPath(UIBezierPath(roundedRect: bone.rect.insetBy(dx: inset, dy: inset),
                                              cornerRadius: radius).cgPath)
                continue
            }
            for dot in Self.dots(in: bone.rect, cornerRadius: radius) {
                // Rows and columns count from the field's corner, so bones
                // at different heights light at different moments.
                let column = Int((dot.x / SkeletonMetrics.dotPitch).rounded())
                let row = Int((dot.y / SkeletonMetrics.dotPitch).rounded())
                let cohort = SkeletonPresence.cohort(column: column, row: row)
                let phase = SkeletonSnake.position(column: column, row: row)
                paths[cohort][phase].addEllipse(in: CGRect(x: dot.x - diameter / 2, y: dot.y - diameter / 2,
                                                           width: diameter, height: diameter))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cohort in paths.indices {
            for phase in paths[cohort].indices { phaseLayers[cohort][phase].path = paths[cohort][phase] }
        }
        outlineLayer.path = outlines
        CATransaction.commit()
    }

    /// The Mac's dot grid: centred in the bone, its corners rounding like
    /// the bone's; two rows or columns keep every dot.
    static func dots(in rect: CGRect, cornerRadius: CGFloat) -> [CGPoint] {
        let pitch = SkeletonMetrics.dotPitch, diameter = SkeletonMetrics.dotDiameter
        let columns = max(1, Int(((rect.width - diameter) / pitch).rounded(.down)) + 1)
        let rows = max(1, Int(((rect.height - diameter) / pitch).rounded(.down)) + 1)
        let left = rect.midX - CGFloat(columns - 1) * pitch / 2
        let top = rect.midY - CGFloat(rows - 1) * pitch / 2
        let span = CGRect(x: left, y: top, width: CGFloat(columns - 1) * pitch, height: CGFloat(rows - 1) * pitch)
        let scale = rect.width > 0 && rect.height > 0 ? min(span.width / rect.width, span.height / rect.height) : 0
        let corner = rows < 3 || columns < 3 ? 0 : min(cornerRadius * scale, span.width / 2, span.height / 2)
        let core = span.insetBy(dx: corner, dy: corner)
        var dots: [CGPoint] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: left + CGFloat(column) * pitch, y: top + CGFloat(row) * pitch)
                let dx = max(core.minX - point.x, point.x - core.maxX, 0)
                let dy = max(core.minY - point.y, point.y - core.maxY, 0)
                if hypot(dx, dy) <= corner + diameter / 2 { dots.append(point) }
            }
        }
        return dots
    }

    @objc private func restartShimmer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let now = CACurrentMediaTime()
        let cycle = SkeletonSnake.cycle
        for phases in phaseLayers {
            for (phase, layer) in phases.enumerated() {
                layer.removeAnimation(forKey: Self.shimmerKey)
                if reduceMotion {
                    layer.opacity = SkeletonSnake.restingOpacity(forPhase: phase)
                    continue
                }
                layer.opacity = SkeletonSnake.levels[SkeletonSnake.phases - 1]
                let snake = CAKeyframeAnimation(keyPath: "opacity")
                snake.values = SkeletonSnake.levels + [SkeletonSnake.levels[0]]
                snake.keyTimes = SkeletonSnake.keyTimes
                snake.calculationMode = .linear
                snake.duration = cycle
                snake.repeatCount = .infinity
                // Locked to the clock, so every field's snakes move together.
                snake.timeOffset = (now + cycle - SkeletonSnake.delay(forPhase: phase))
                    .truncatingRemainder(dividingBy: cycle)
                layer.add(snake, forKey: Self.shimmerKey)
            }
        }
        CATransaction.commit()
    }

    /// Each cohort fades over its own slice of the sweep; leaving runs it
    /// backwards, the last dots to arrive leaving first.
    private func animatePresence(arriving: Bool) {
        let duration = arriving ? SkeletonPresence.enterDuration : SkeletonPresence.exitDuration
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (cohort, layer) in cohortLayers.enumerated() {
            let window = SkeletonPresence.window(ofCohort: cohort)
            let begin = arriving ? window.start : 1 - window.end
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? (arriving ? 0 : 1)
            fade.toValue = arriving ? 1 : 0
            fade.beginTime = now + begin * duration
            fade.duration = SkeletonPresence.fade * duration
            fade.fillMode = .both
            layer.removeAnimation(forKey: Self.presenceKey)
            layer.add(fade, forKey: Self.presenceKey)
            layer.opacity = arriving ? 1 : 0
        }
        let outline = CABasicAnimation(keyPath: "opacity")
        outline.fromValue = outlineLayer.presentation()?.opacity ?? 0
        outline.toValue = arriving ? SkeletonMetrics.outlineOpacity : 0
        outline.duration = duration
        outlineLayer.add(outline, forKey: Self.presenceKey)
        outlineLayer.opacity = arriving ? SkeletonMetrics.outlineOpacity : 0
        CATransaction.commit()
    }
}
