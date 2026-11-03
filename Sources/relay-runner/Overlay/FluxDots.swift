import AppKit
import QuartzCore
import SwiftUI

/// The colour and opacity of shimmering dots. Every style shares the
/// skeleton loader's dot size, spacing and shimmer.
struct FluxDotStyle: Equatable {
    /// The dots' colour when lit; the ripple moves only their opacity.
    let highlight: NSColor
    let opacity: Float

    /// The skeleton loaders and the hover on the Workspace tabs and the
    /// Settings sidebar: opaque, so the dots show on black.
    static let standard = FluxDotStyle(
        highlight: SkeletonLoaderView.boneHighlightColor,
        opacity: 1
    )
}

/// Round dots that shimmer by the skeleton loader's rules: its dot size and
/// spacing, and the dot ripple, in a style's colour. The loader draws its
/// filled bones with them, and hovered navigation items their backgrounds.
///
/// Each presence cohort has its own layer, whose opacity is how far the
/// cohort has arrived, and inside it each ripple phase has its own shape
/// layer so its dots shimmer together.
final class FluxDotLayers {
    static let presenceKey = "dotPresence"

    /// Holds the cohort layers, at the style's opacity.
    let container = CALayer()
    /// One per cohort; its opacity is the cohort's presence.
    let cohortLayers = (0..<DotPresence.cohorts).map { _ in CALayer() }
    /// The ripple layers, one per phase, inside each cohort.
    let phaseLayers: [[CAShapeLayer]]
    let style: FluxDotStyle
    /// How much of the field is there, from 0 to 1.
    private(set) var presence: Double = 1

    init(style: FluxDotStyle = .standard) {
        self.style = style
        phaseLayers = cohortLayers.map { _ in (0..<DotRippleAnimation.phases).map { _ in CAShapeLayer() } }
        for (cohort, cohortLayer) in cohortLayers.enumerated() {
            for layer in phaseLayers[cohort] {
                layer.fillColor = style.highlight.cgColor
                layer.opacity = DotRippleAnimation.levels[0]
                cohortLayer.addSublayer(layer)
            }
            container.addSublayer(cohortLayer)
        }
        container.opacity = style.opacity
    }

    /// Shows the share of the dots present at `presence`, from 0 (none) to
    /// 1 (all), at once.
    func setPresence(_ presence: Double) {
        self.presence = presence
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (cohort, layer) in cohortLayers.enumerated() {
            layer.removeAnimation(forKey: Self.presenceKey)
            layer.opacity = DotPresence.opacity(ofCohort: cohort, presence: presence)
        }
        CATransaction.commit()
    }

    /// Disintegrates the dots in (to 1) or out (to 0) over `duration`: each
    /// cohort fades over its own slice of the sweep, so arriving dots
    /// scatter in and leaving dots scatter out, the last to arrive first.
    func animatePresence(to target: Double, duration: TimeInterval, completion: (() -> Void)? = nil) {
        let from = presence
        guard duration > 0, from != target else {
            setPresence(target)
            completion?()
            return
        }
        presence = target
        let arriving = target > from
        let curve = arriving ? RelayMotion.enterCurve : RelayMotion.exitCurve
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        for (cohort, layer) in cohortLayers.enumerated() {
            let window = DotPresence.window(ofCohort: cohort)
            // Leaving runs the sweep backwards.
            let begin = arriving ? window.start : 1 - window.end
            let end = arriving ? window.end : 1 - window.start
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = DotPresence.opacity(ofCohort: cohort, presence: from)
            fade.toValue = DotPresence.opacity(ofCohort: cohort, presence: target)
            fade.beginTime = now + begin * duration
            fade.duration = (end - begin) * duration
            fade.fillMode = .both
            fade.timingFunction = curve.mediaTimingFunction
            layer.removeAnimation(forKey: Self.presenceKey)
            layer.opacity = fade.toValue as? Float ?? layer.opacity
            layer.add(fade, forKey: Self.presenceKey)
        }
        CATransaction.commit()
    }

    /// Fills each rounded shape in the view with dots and starts the
    /// shimmer. Like the notch glyph's, each dot sits on whole screen pixels,
    /// so its edges stay crisp; half a pixel off, it blurs and looks smaller.
    func fill(_ shapes: [(rect: CGRect, cornerRadius: CGFloat)], in view: NSView) {
        let diameter = SkeletonLoaderView.dotDiameter
        let paths = phaseLayers.map { cohort in cohort.map { _ in CGMutablePath() } }
        let reduceMotion = RelayLayerMotion.reduceMotion
        for shape in shapes {
            for dot in SkeletonLoaderView.dots(in: shape.rect, cornerRadius: shape.cornerRadius) {
                let phase = DotRippleAnimation.phase(forRing: dot.ring, reduceMotion: reduceMotion)
                paths[dot.cohort][phase].addEllipse(in: view.backingAlignedRect(
                    CGRect(
                        x: dot.centre.x - diameter / 2,
                        y: dot.centre.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    ),
                    options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]
                ))
            }
        }
        let bounds = view.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        for (cohort, cohortLayer) in cohortLayers.enumerated() {
            cohortLayer.frame = bounds
            for (layer, path) in zip(phaseLayers[cohort], paths[cohort]) {
                layer.frame = bounds
                layer.path = path
            }
        }
        CATransaction.commit()
        for cohort in phaseLayers {
            DotRippleAnimation.run(on: cohort)
        }
    }
}

/// A rounded shape filled with shimmering dots. It takes no clicks.
final class FluxDotsView: NSView {
    var cornerRadius: CGFloat {
        didSet { needsLayout = true }
    }

    let dots: FluxDotLayers

    override var isFlipped: Bool { true }

    init(cornerRadius: CGFloat, style: FluxDotStyle) {
        self.cornerRadius = cornerRadius
        dots = FluxDotLayers(style: style)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(dots.container)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        dots.fill([(bounds, cornerRadius)], in: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

/// The hover background for navigation items: shimmering dots in place of
/// a solid fill.
struct FluxDotsBackground: NSViewRepresentable {
    let cornerRadius: CGFloat
    let style: FluxDotStyle
    @Environment(\.dotPresence) private var presence

    func makeNSView(context: Context) -> FluxDotsView {
        let view = FluxDotsView(cornerRadius: cornerRadius, style: style)
        view.dots.setPresence(presence)
        return view
    }

    func updateNSView(_ view: FluxDotsView, context: Context) {
        view.cornerRadius = cornerRadius
        view.dots.setPresence(presence)
    }
}

// MARK: - Disintegrate transition

private struct DotPresenceKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    /// How much of a dot field is there, from 0 to 1. The disintegrate
    /// transition drives it; a field outside one is all there.
    var dotPresence: Double {
        get { self[DotPresenceKey.self] }
        set { self[DotPresenceKey.self] = newValue }
    }
}

/// Carries an animated presence down to the dot fields beneath it.
struct DotPresenceModifier: ViewModifier, Animatable {
    var presence: Double

    var animatableData: Double {
        get { presence }
        set { presence = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.dotPresence, presence)
    }
}

/// Dot fields arrive and leave by disintegrating: their dots scatter in
/// until the field is full, and scatter out until none are left.
struct DotDisintegrateTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(DotPresenceModifier(presence: phase.isIdentity ? 1 : 0))
    }
}

extension AnyTransition {
    /// A dot field that disintegrates in and out, such as a hover fill.
    static var dotDisintegrate: AnyTransition {
        .asymmetric(
            insertion: AnyTransition(DotDisintegrateTransition()).animation(RelayMotion.enter),
            removal: AnyTransition(DotDisintegrateTransition()).animation(RelayMotion.exit)
        )
    }

    /// A dot field that takes the place of content leaving, such as a
    /// skeleton loader in an `if`/`else`: it arrives only once the outgoing
    /// content has finished its exit.
    static var dotDisintegrateReplacing: AnyTransition {
        .asymmetric(
            insertion: AnyTransition(DotDisintegrateTransition()).animation(RelayMotion.replacingEnter),
            removal: AnyTransition(DotDisintegrateTransition()).animation(RelayMotion.exit)
        )
    }
}
