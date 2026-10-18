import AppKit
import QuartzCore
import SwiftUI

/// The shared motion language for every Relay Runner surface.
///
/// Anything that appears, text included, expands into place while
/// it sharpens from a blur and fades in. Anything that disappears contracts,
/// blurs and fades out. Every movement is eased; exits are
/// quicker than entrances so dismissals feel responsive. When one thing
/// replaces another, the outgoing content finishes leaving and the screen
/// rests for a beat before its replacement arrives, so the two never share
/// the screen.
///
/// Reduce Motion keeps the opacity crossfade and drops scale and blur.
enum RelayMotion {
    // MARK: Timing

    static let durationScale: Double = 0.75
    static let enterDuration: TimeInterval = 0.34 * durationScale
    static let exitDuration: TimeInterval = 0.2 * durationScale
    static let changeDuration: TimeInterval = 0.3 * durationScale
    static let hoverDuration: TimeInterval = 0.15 * durationScale
    /// The empty beat between an exit and the entrance that replaces it.
    static let replacementGap: TimeInterval = 0.1 * durationScale
    /// How long a replacement waits: the outgoing exit plus a short rest.
    static let replacementDelay: TimeInterval = exitDuration + replacementGap

    /// A cubic Bézier easing curve shared by SwiftUI, Core Animation, and
    /// timer-driven AppKit drawing so all three move identically.
    struct Curve: Equatable {
        let x1: Double
        let y1: Double
        let x2: Double
        let y2: Double

        func animation(duration: TimeInterval) -> Animation {
            .timingCurve(x1, y1, x2, y2, duration: duration)
        }

        var mediaTimingFunction: CAMediaTimingFunction {
            CAMediaTimingFunction(
                controlPoints: Float(x1), Float(y1), Float(x2), Float(y2)
            )
        }

        /// Eased progress for a linear time fraction, for surfaces that
        /// animate from their own display timer.
        func progress(_ fraction: CGFloat) -> CGFloat {
            let t = min(max(fraction, 0), 1)
            guard t > 0, t < 1 else { return t }
            var lower: CGFloat = 0
            var upper: CGFloat = 1
            for _ in 0..<16 {
                let candidate = (lower + upper) / 2
                if Self.bezier(candidate, CGFloat(x1), CGFloat(x2)) < t {
                    lower = candidate
                } else {
                    upper = candidate
                }
            }
            return Self.bezier((lower + upper) / 2, CGFloat(y1), CGFloat(y2))
        }

        private static func bezier(_ t: CGFloat, _ first: CGFloat, _ second: CGFloat) -> CGFloat {
            let inverse = 1 - t
            return 3 * inverse * inverse * t * first + 3 * inverse * t * t * second + t * t * t
        }
    }

    /// Decelerates into place (ease-out quint).
    static let enterCurve = Curve(x1: 0.22, y1: 1, x2: 0.36, y2: 1)
    /// Accelerates away.
    static let exitCurve = Curve(x1: 0.4, y1: 0, x2: 1, y2: 1)
    /// Settles an in-place change such as a resize, recolour, or state swap
    /// (ease-out quart).
    static let changeCurve = Curve(x1: 0.25, y1: 1, x2: 0.5, y2: 1)

    static var enter: Animation { enterCurve.animation(duration: enterDuration) }
    /// The entrance for content that replaces something leaving.
    static var replacingEnter: Animation { enter.delay(replacementDelay) }
    static var exit: Animation { exitCurve.animation(duration: exitDuration) }
    static var change: Animation { changeCurve.animation(duration: changeDuration) }
    static var hover: Animation { .easeOut(duration: hoverDuration) }

    static func change(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18 * durationScale) : change
    }

    // MARK: Styles

    /// How contracted and blurred a hidden element is at its resting position.
    struct Style: Equatable {
        let hiddenScale: CGFloat
        let blurRadius: CGFloat

        /// Controls, rows, badges, icons, and inline sections.
        static let element = Style(hiddenScale: 0.96, blurRadius: 6)
        /// Modals, panels, popovers, windows, and whole pages.
        static let surface = Style(hiddenScale: 0.96, blurRadius: 12)
        /// Labels and copy that swap in place.
        static let text = Style(hiddenScale: 0.96, blurRadius: 4)

        func scale(hidden: Bool, reduceMotion: Bool) -> CGFloat {
            hidden && !reduceMotion ? hiddenScale : 1
        }

        func blur(hidden: Bool, reduceMotion: Bool) -> CGFloat {
            hidden && !reduceMotion ? blurRadius : 0
        }
    }
}

// MARK: - SwiftUI

/// Applies the hidden or resting appearance for a Relay motion style.
struct RelayMotionEffect: ViewModifier {
    let style: RelayMotion.Style
    let hidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: style.blur(hidden: hidden, reduceMotion: reduceMotion))
            .scaleEffect(style.scale(hidden: hidden, reduceMotion: reduceMotion))
    }
}

struct RelayTransition: Transition {
    let style: RelayMotion.Style

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(RelayMotionEffect(style: style, hidden: !phase.isIdentity))
    }
}

extension AnyTransition {
    /// Controls, rows, badges, icons, and inline sections.
    static var relayElement: AnyTransition { relay(.element) }
    /// Modals, panels, popovers, and whole pages.
    static var relaySurface: AnyTransition { relay(.surface) }
    /// Labels and copy.
    static var relayText: AnyTransition { relay(.text) }

    static func relay(_ style: RelayMotion.Style) -> AnyTransition {
        .asymmetric(
            insertion: AnyTransition(RelayTransition(style: style)).animation(RelayMotion.enter),
            removal: AnyTransition(RelayTransition(style: style)).animation(RelayMotion.exit)
        )
    }

    /// For content that takes the place of something leaving, such as either
    /// branch of an `if`/`else` or a page keyed by selection: it arrives only
    /// once the outgoing content has finished its exit.
    static func relayReplacing(_ style: RelayMotion.Style = .element) -> AnyTransition {
        .asymmetric(
            insertion: AnyTransition(RelayTransition(style: style)).animation(RelayMotion.replacingEnter),
            removal: AnyTransition(RelayTransition(style: style)).animation(RelayMotion.exit)
        )
    }
}

/// Swaps content built from `value`: the outgoing copy contracts still
/// showing its own value, the space rests for a beat, then the copy for the
/// new value expands in.
///
/// Build everything that changes with `value` inside `content` from its
/// argument. The leaving copy is frozen with the value it was built from; a
/// modifier-based swap cannot do this, because its leaving copy keeps
/// rendering the live content and morphs into the new value as it exits.
struct RelaySwap<Value: Hashable, Content: View>: View {
    let value: Value
    let style: RelayMotion.Style
    let alignment: Alignment
    let content: (Value) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `style: .text` for copy; the default suits icons, glyphs, and badges.
    init(
        _ value: Value,
        style: RelayMotion.Style = .element,
        alignment: Alignment = .center,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.value = value
        self.style = style
        self.alignment = alignment
        self.content = content
    }

    var body: some View {
        ZStack(alignment: alignment) {
            content(value)
                .id(value)
                .transition(.relayReplacing(style))
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// Plays the Relay entrance once when the view first appears, for
    /// content that is mounted by AppKit rather than inserted by SwiftUI.
    func relayAppearOnMount(style: RelayMotion.Style = .surface, delay: TimeInterval = 0) -> some View {
        modifier(RelayAppearOnMountModifier(style: style, delay: delay))
    }
}

private struct RelayAppearOnMountModifier: ViewModifier {
    let style: RelayMotion.Style
    let delay: TimeInterval
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .modifier(RelayMotionEffect(style: style, hidden: !visible))
            .onAppear {
                withAnimation(RelayMotion.enter.delay(delay)) {
                    visible = true
                }
            }
    }
}

// MARK: - AppKit

/// Core Animation counterparts of the SwiftUI transitions for layer-backed
/// AppKit views and panels.
enum RelayLayerMotion {
    static let blurFilterName = "relayMotionBlur"
    private static let blurKeyPath = "filters.\(blurFilterName).inputRadius"
    private static let travelKey = "relayMotionTravel"
    private static let blurKey = "relayMotionBlurRadius"
    private static let generationKey = "relayMotionGeneration"

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Makes the view ready to blur, keeping any filters it already owns.
    static func prepare(_ view: NSView) {
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        guard let layer = view.layer else { return }
        let filters = layer.filters ?? []
        let hasBlur = filters.contains { ($0 as? CIFilter)?.name == blurFilterName }
        guard !hasBlur, let blur = CIFilter(name: "CIGaussianBlur") else { return }
        blur.name = blurFilterName
        blur.setValue(0, forKey: kCIInputRadiusKey)
        layer.filters = filters + [blur]
    }

    /// AppKit backing layers may anchor at a corner. Compensate so scaling
    /// preserves the visual center without changing their layout or anchor.
    static func centeredScale(_ scale: CGFloat, on layer: CALayer) -> CATransform3D {
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform.m41 = layer.bounds.width * (0.5 - layer.anchorPoint.x) * (1 - scale)
        transform.m42 = layer.bounds.height * (0.5 - layer.anchorPoint.y) * (1 - scale)
        return transform
    }

    /// Fades, sharpens, and expands a view into place.
    static func animateIn(
        _ view: NSView,
        style: RelayMotion.Style = .element,
        duration: TimeInterval = RelayMotion.enterDuration,
        delay: TimeInterval = 0,
        completion: (() -> Void)? = nil
    ) {
        prepare(view)
        view.isHidden = false
        run(
            on: view,
            style: style,
            fromHidden: true,
            duration: duration,
            delay: delay,
            curve: RelayMotion.enterCurve,
            completion: completion
        )
    }

    /// Blurs, fades, and contracts a view out of sight, then hides it.
    static func animateOut(
        _ view: NSView,
        style: RelayMotion.Style = .element,
        duration: TimeInterval = RelayMotion.exitDuration,
        hidesWhenDone: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        prepare(view)
        run(
            on: view,
            style: style,
            fromHidden: false,
            duration: duration,
            delay: 0,
            curve: RelayMotion.exitCurve
        ) { [weak view] in
            if hidesWhenDone, view?.alphaValue ?? 1 < 0.01 {
                view?.isHidden = true
            }
            completion?()
        }
    }

    /// Replaces a view's content in place: a snapshot of the old content
    /// leaves, then the updated view arrives.
    static func crossfade(
        _ view: NSView,
        style: RelayMotion.Style = .text,
        update: () -> Void
    ) {
        guard !view.isHidden, view.alphaValue > 0.01, view.window != nil,
              !view.bounds.isEmpty, let superview = view.superview,
              let snapshot = snapshotLayer(of: view) else {
            update()
            return
        }
        prepare(view)
        let holder = NSView(frame: view.frame)
        // Assigning the layer first makes the holder layer-hosting.
        holder.layer = snapshot
        holder.wantsLayer = true
        holder.autoresizingMask = view.autoresizingMask
        superview.addSubview(holder, positioned: .above, relativeTo: view)

        update()

        view.alphaValue = 0
        animateOut(holder, style: style, hidesWhenDone: false) { [weak holder] in
            holder?.removeFromSuperview()
        }
        animateIn(view, style: style, delay: RelayMotion.replacementDelay)
    }

    // MARK: Internals

    private static func run(
        on view: NSView,
        style: RelayMotion.Style,
        fromHidden: Bool,
        duration: TimeInterval,
        delay: TimeInterval,
        curve: RelayMotion.Curve,
        completion: (() -> Void)?
    ) {
        guard let layer = view.layer else {
            view.alphaValue = fromHidden ? 1 : 0
            completion?()
            return
        }
        let blur = reduceMotion ? 0 : style.blurRadius
        let hiddenTransform = centeredScale(style.scale(hidden: true, reduceMotion: reduceMotion), on: layer)
        let startTransform = fromHidden ? hiddenTransform : CATransform3DIdentity
        let endTransform = fromHidden ? CATransform3DIdentity : hiddenTransform
        let startBlur = fromHidden ? blur : 0
        let endBlur = fromHidden ? 0 : blur

        // Continue from whatever is on screen when interrupting.
        let presentedTransform = layer.presentation()?.transform ?? startTransform
        let presentedBlur = (layer.presentation()?.value(forKeyPath: blurKeyPath) as? CGFloat) ?? startBlur
        let interrupting = layer.animation(forKey: travelKey) != nil
        layer.removeAnimation(forKey: travelKey)
        layer.removeAnimation(forKey: blurKey)

        if fromHidden, !interrupting {
            view.alphaValue = 0
        }

        let beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0
        // A later animation on the same view cancels a fade still waiting
        // for its delay.
        let generation = ((layer.value(forKey: generationKey) as? Int) ?? 0) + 1
        layer.setValue(generation, forKey: generationKey)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = endTransform
        layer.setValue(endBlur, forKeyPath: blurKeyPath)
        CATransaction.commit()

        guard duration > 0 else {
            view.alphaValue = fromHidden ? 1 : 0
            completion?()
            return
        }

        let travelAnimation = CABasicAnimation(keyPath: "transform")
        travelAnimation.fromValue = interrupting ? presentedTransform : startTransform
        travelAnimation.toValue = endTransform
        let blurAnimation = CABasicAnimation(keyPath: blurKeyPath)
        blurAnimation.fromValue = interrupting ? presentedBlur : startBlur
        blurAnimation.toValue = endBlur
        for animation in [travelAnimation, blurAnimation] {
            animation.duration = duration
            animation.timingFunction = curve.mediaTimingFunction
            animation.beginTime = beginTime
            animation.fillMode = .backwards
        }
        layer.add(travelAnimation, forKey: travelKey)
        layer.add(blurAnimation, forKey: blurKey)

        let fade = {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = curve.mediaTimingFunction
                view.animator().alphaValue = fromHidden ? 1 : 0
            } completionHandler: {
                completion?()
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak layer] in
                guard let layer, layer.value(forKey: generationKey) as? Int == generation else { return }
                fade()
            }
        } else {
            fade()
        }
    }

    private static func snapshotLayer(of view: NSView) -> CALayer? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = view.window?.backingScaleFactor ?? 2
        return layer
    }
}

/// Window-level presentation for app panels and windows.
enum RelayWindowMotion {
    /// Bumped by every present/dismiss so a dismissal that is overtaken by a
    /// re-presentation never orders the window out afterwards.
    private static var generations: [ObjectIdentifier: Int] = [:]

    private static func nextGeneration(for window: NSWindow) -> Int {
        let id = ObjectIdentifier(window)
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        return generation
    }

    /// Orders a window in by fading, expanding, and sharpening its content.
    static func present(
        _ window: NSWindow,
        makeKey: Bool = true,
        style: RelayMotion.Style = .surface,
        completion: (() -> Void)? = nil
    ) {
        _ = nextGeneration(for: window)
        let alreadyVisible = window.isVisible && window.alphaValue > 0.99
        guard !alreadyVisible else {
            if makeKey { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
            completion?()
            return
        }

        if !window.isVisible {
            window.alphaValue = 0
        }
        if makeKey { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }

        if let content = window.contentView {
            RelayLayerMotion.prepare(content)
            animateContent(content, style: style, entering: true)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = RelayMotion.enterDuration
            context.timingFunction = RelayMotion.enterCurve.mediaTimingFunction
            window.animator().alphaValue = 1
        } completionHandler: {
            completion?()
        }
    }

    /// Contracts, blurs, and fades the content, then orders the window out.
    /// The frame stays fixed throughout both directions.
    static func dismiss(
        _ window: NSWindow,
        style: RelayMotion.Style = .surface,
        completion: (() -> Void)? = nil
    ) {
        guard window.isVisible else {
            completion?()
            return
        }
        let id = ObjectIdentifier(window)
        let generation = nextGeneration(for: window)
        if let content = window.contentView {
            RelayLayerMotion.prepare(content)
            animateContent(content, style: style, entering: false)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = RelayMotion.exitDuration
            context.timingFunction = RelayMotion.exitCurve.mediaTimingFunction
            window.animator().alphaValue = 0
        } completionHandler: {
            guard generations[id] == generation else { return }
            window.orderOut(nil)
            window.alphaValue = 1
            if let layer = window.contentView?.layer {
                layer.removeAnimation(forKey: "relayWindowBlur")
                layer.removeAnimation(forKey: "relayWindowScale")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DIdentity
                layer.setValue(0, forKeyPath: "filters.\(RelayLayerMotion.blurFilterName).inputRadius")
                CATransaction.commit()
            }
            completion?()
        }
    }

    private static func animateContent(
        _ view: NSView,
        style: RelayMotion.Style,
        entering: Bool
    ) {
        guard let layer = view.layer else { return }
        let reduceMotion = RelayLayerMotion.reduceMotion
        let keyPath = "filters.\(RelayLayerMotion.blurFilterName).inputRadius"
        let hidden = RelayLayerMotion.centeredScale(style.scale(hidden: true, reduceMotion: reduceMotion), on: layer)
        let targetTransform = entering ? CATransform3DIdentity : hidden
        let targetBlur = entering ? 0 : style.blur(hidden: true, reduceMotion: reduceMotion)
        let interrupting = layer.animation(forKey: "relayWindowScale") != nil
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = interrupting ? layer.presentation()?.transform ?? layer.transform
            : (entering ? hidden : CATransform3DIdentity)
        scale.toValue = targetTransform
        let blur = CABasicAnimation(keyPath: keyPath)
        blur.fromValue = interrupting ? layer.presentation()?.value(forKeyPath: keyPath)
            : (entering ? style.blur(hidden: true, reduceMotion: reduceMotion) : 0)
        blur.toValue = targetBlur
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = targetTransform
        layer.setValue(targetBlur, forKeyPath: keyPath)
        CATransaction.commit()
        for animation in [scale, blur] {
            animation.duration = entering ? RelayMotion.enterDuration : RelayMotion.exitDuration
            animation.timingFunction = (entering ? RelayMotion.enterCurve : RelayMotion.exitCurve).mediaTimingFunction
        }
        layer.add(scale, forKey: "relayWindowScale")
        layer.add(blur, forKey: "relayWindowBlur")
    }
}
