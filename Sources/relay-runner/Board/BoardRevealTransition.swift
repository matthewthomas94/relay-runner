import AppKit
import QuartzCore

enum BoardRevealTransitionTiming {
    static let firstMotionBudget: TimeInterval = 0.10
    static let expandToFullWidthDuration: TimeInterval = 0.24
    static let expandDuration: TimeInterval = 0.34
    static let contentRevealDuration: TimeInterval = 0.38
    static let contentHideDuration: TimeInterval = 0.22
    static let dismissToFullWidthDuration: TimeInterval = 0.24
    static let compactDuration: TimeInterval = 0.22

    static var revealAnimationDuration: TimeInterval {
        expandToFullWidthDuration + expandDuration + contentRevealDuration
    }

    static var dismissAnimationDuration: TimeInterval {
        contentHideDuration + dismissToFullWidthDuration + compactDuration
    }
}

struct BoardRevealTransitionPlan: Equatable {
    let compactFrame: CGRect
    let fullWidthFrame: CGRect
    let expandedFrame: CGRect
    let glyphFrame: CGRect
    let compactLeadingSpacerWidth: CGFloat
    let compactNotchSpacerWidth: CGFloat
}

enum BoardRevealTransitionPlanner {
    static let minimumCompactWidth: CGFloat = 236
    static var expandedSurfaceHeight: CGFloat {
        ProgramBoardBackdropStyle.backdropHeight
    }
    static var expandedSurfaceCornerRadius: CGFloat {
        ProgramBoardBackdropStyle.bottomCornerRadius
    }
    static let bottomScreenMargin: CGFloat = 54

    static func plan(for geometry: NotchStatusDisplayGeometry) -> BoardRevealTransitionPlan {
        plan(
            for: geometry.frame,
            notchPlacement: NotchStatusPlacementPlanner.placement(for: geometry)
        )
    }

    static func plan(for screenFrame: CGRect) -> BoardRevealTransitionPlan {
        plan(for: NotchStatusDisplayGeometry(screenFrame: screenFrame))
    }

    static func plan(
        for screenFrame: CGRect,
        notchPlacement: NotchStatusPlacement?
    ) -> BoardRevealTransitionPlan {
        let glyphSize = NotchStatusPlacementPlanner.glyphSize
        let compactWidth = max(minimumCompactWidth, notchPlacement?.visibleFrame.width ?? 0)
        let compactCenterX = notchPlacement.map {
            $0.visibleFrame.midX - screenFrame.minX
        } ?? screenFrame.width / 2
        let compactX = min(
            max(0, compactCenterX - compactWidth / 2),
            max(0, screenFrame.width - compactWidth)
        )
        let compactFrame = CGRect(
            x: compactX,
            y: 0,
            width: compactWidth,
            height: glyphSize.height
        )
        let glyphX = notchPlacement.map {
            $0.glyphScreenX - screenFrame.minX
        } ?? compactFrame.maxX - glyphSize.width
        let glyphFrame = CGRect(
            x: min(max(0, glyphX), max(0, screenFrame.width - glyphSize.width)),
            y: 0,
            width: glyphSize.width,
            height: glyphSize.height
        )
        let fullWidthFrame = CGRect(
            x: 0,
            y: 0,
            width: screenFrame.width,
            height: glyphSize.height
        )
        let expandedHeight = max(
            glyphSize.height,
            min(expandedSurfaceHeight, screenFrame.height - bottomScreenMargin)
        )
        let expandedFrame = CGRect(
            x: 0,
            y: 0,
            width: screenFrame.width,
            height: expandedHeight
        )

        return BoardRevealTransitionPlan(
            compactFrame: compactFrame,
            fullWidthFrame: fullWidthFrame,
            expandedFrame: expandedFrame,
            glyphFrame: glyphFrame,
            compactLeadingSpacerWidth: notchPlacement?.leadingSpacerWidth ?? 0,
            compactNotchSpacerWidth: notchPlacement?.notchSpacerWidth ?? 0
        )
    }
}

extension NotchStatusDisplayGeometry {
    init(screenFrame: CGRect) {
        self.init(
            frame: screenFrame,
            visibleFrame: screenFrame
        )
    }
}

final class BoardRevealContainerView: NSView {
    private let plan: BoardRevealTransitionPlan
    private let revealView: BoardRevealSurfaceView
    private let glyphView: BoardRevealGlyphView
    private let contentContainerView = NSView()
    private let hostedContentView: NSView
    private let reduceMotion: Bool
    private var revealExpanded = false
    private var contentVisible = false
    private var contentBlurGeneration = 0
    private var loading: Bool

    override var isFlipped: Bool { true }

    init(
        frame: NSRect,
        contentView: NSView,
        displayGeometry: NotchStatusDisplayGeometry,
        startsLoading: Bool
    ) {
        let plan = BoardRevealTransitionPlanner.plan(for: displayGeometry)
        self.plan = plan
        self.revealView = BoardRevealSurfaceView(frame: frame, plan: plan)
        self.glyphView = BoardRevealGlyphView(frame: frame, plan: plan)
        self.hostedContentView = contentView
        self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.loading = startsLoading
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        revealView.setLoading(startsLoading)
        revealView.autoresizingMask = [.width, .height]
        addSubview(revealView)

        contentContainerView.wantsLayer = true
        contentContainerView.layer?.backgroundColor = NSColor.clear.cgColor
        contentContainerView.frame = bounds
        contentContainerView.autoresizingMask = [.width, .height]
        contentContainerView.alphaValue = 0
        contentContainerView.isHidden = true
        setContentYOffset(hiddenContentYOffset)
        addSubview(contentContainerView)

        hostedContentView.frame = contentContainerView.bounds
        hostedContentView.autoresizingMask = [.width, .height]
        contentContainerView.addSubview(hostedContentView)

        glyphView.setLoading(startsLoading)
        glyphView.autoresizingMask = [.width, .height]
        addSubview(glyphView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        revealView.cancelAnimation()
    }

    func setLoading(_ loading: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setLoading(loading)
            }
            return
        }

        self.loading = loading
        revealView.setLoading(loading)
        glyphView.setLoading(loading)
        revealContentIfReady()
    }

    func canReuse(displayGeometry: NotchStatusDisplayGeometry) -> Bool {
        BoardRevealTransitionPlanner.plan(for: displayGeometry) == plan
    }

    var isPreparedForOpening: Bool {
        !revealExpanded
            && !contentVisible
            && contentContainerView.isHidden
            && revealView.isCompact
    }

    func prepareForOpening(startsLoading: Bool) {
        revealView.cancelAnimation()
        revealView.showCompact()
        revealExpanded = false
        contentVisible = false
        contentContainerView.alphaValue = 0
        contentContainerView.isHidden = true
        setContentYOffset(hiddenContentYOffset)
        setLoading(startsLoading)
    }

    func setUpdateCheckActive(_ active: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setUpdateCheckActive(active)
            }
            return
        }

        glyphView.setLoading(active)
    }

    func animateReveal(
        firstMotion: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        guard !reduceMotion else {
            firstMotion()
            revealExpanded = true
            revealView.showExpanded()
            revealContentIfReady(completion: completion)
            return
        }

        revealView.animateToFullWidth(firstMotion: firstMotion) { [weak self] in
            guard let self else { return }
            self.revealView.animateToExpanded { [weak self] in
                guard let self else { return }
                self.revealExpanded = true
                self.revealContentIfReady(completion: completion)
            }
        }
    }

    func animateReveal(completion: @escaping () -> Void) {
        animateReveal(firstMotion: {}, completion: completion)
    }

    func animateDismiss(
        firstMotion: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        guard !reduceMotion else {
            firstMotion()
            revealView.cancelAnimation()
            contentContainerView.isHidden = true
            completion()
            return
        }

        firstMotion()
        hideContentIfNeeded { [weak self] in
            guard let self else { return }
            self.revealView.setLoading(false)
            self.revealView.animateToFullWidth { [weak self] in
                guard let self else { return }
                self.revealView.animateToCompact {
                    completion()
                }
            }
        }
    }

    func animateDismiss(completion: @escaping () -> Void) {
        animateDismiss(firstMotion: {}, completion: completion)
    }

    private func revealContentIfReady(completion: (() -> Void)? = nil) {
        guard revealExpanded else {
            completion?()
            return
        }
        guard !loading else {
            completion?()
            return
        }
        guard !contentVisible else {
            completion?()
            return
        }

        contentVisible = true
        contentContainerView.isHidden = false
        contentContainerView.alphaValue = 0
        setContentYOffset(hiddenContentYOffset)
        // The Workspace takes the loading label's place only once it has left.
        let delay = revealView.loadingLabelExitRemaining
        animateContentYOffset(
            from: hiddenContentYOffset,
            to: 0,
            duration: BoardRevealTransitionTiming.contentRevealDuration,
            timing: Self.revealTiming,
            delay: delay
        )
        let blurGeneration = animateContentBlur(
            from: hiddenContentBlurRadius,
            to: 0,
            duration: BoardRevealTransitionTiming.contentRevealDuration,
            timing: Self.revealTiming,
            delay: delay
        )
        let fade: () -> Void = { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = BoardRevealTransitionTiming.contentRevealDuration
                context.timingFunction = Self.revealTiming
                self.contentContainerView.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                self?.removeContentBlur(ifCurrent: blurGeneration)
                completion?()
            }
        }
        guard delay > 0 else {
            fade()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // A hide that starts during the wait supersedes this reveal.
            guard let self, blurGeneration == self.contentBlurGeneration else {
                completion?()
                return
            }
            fade()
        }
    }

    private func hideContentIfNeeded(completion: @escaping () -> Void) {
        guard contentVisible else {
            completion()
            return
        }

        contentVisible = false
        animateContentYOffset(
            from: 0,
            to: hiddenContentYOffset,
            duration: BoardRevealTransitionTiming.contentHideDuration,
            timing: Self.hideTiming
        )
        let blurGeneration = animateContentBlur(
            from: 0,
            to: hiddenContentBlurRadius,
            duration: BoardRevealTransitionTiming.contentHideDuration,
            timing: Self.hideTiming
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = BoardRevealTransitionTiming.contentHideDuration
            context.timingFunction = Self.hideTiming
            contentContainerView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.contentContainerView.isHidden = true
            self?.removeContentBlur(ifCurrent: blurGeneration)
            completion()
        }
    }

    private func setContentYOffset(_ offset: CGFloat) {
        contentContainerView.layer?.transform = CATransform3DMakeTranslation(0, offset, 0)
    }

    private func animateContentYOffset(
        from: CGFloat,
        to: CGFloat,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunction,
        delay: CFTimeInterval = 0
    ) {
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        animation.fillMode = .forwards
        if delay > 0 {
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .both
        }
        animation.isRemovedOnCompletion = false
        contentContainerView.layer?.add(animation, forKey: "boardRevealContentYOffset")
        setContentYOffset(to)
    }

    /// Blurs the hosted Workspace only while it travels; the filter is
    /// removed once the content settles so the resting surface renders
    /// without an offscreen pass.
    private func animateContentBlur(
        from: CGFloat,
        to: CGFloat,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunction,
        delay: CFTimeInterval = 0
    ) -> Int {
        contentBlurGeneration += 1
        guard !reduceMotion else { return contentBlurGeneration }
        RelayLayerMotion.prepare(contentContainerView)
        guard let layer = contentContainerView.layer else { return contentBlurGeneration }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(to, forKeyPath: Self.contentBlurKeyPath)
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: Self.contentBlurKeyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        if delay > 0 {
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: Self.contentBlurAnimationKey)
        return contentBlurGeneration
    }

    private func removeContentBlur(ifCurrent generation: Int) {
        guard generation == contentBlurGeneration,
              let layer = contentContainerView.layer else { return }
        layer.removeAnimation(forKey: Self.contentBlurAnimationKey)
        layer.filters = layer.filters?.filter {
            ($0 as? CIFilter)?.name != RelayLayerMotion.blurFilterName
        }
    }

    /// Travel and blur drop out under Reduce Motion; the fade remains.
    private var hiddenContentYOffset: CGFloat {
        reduceMotion ? 0 : Self.hiddenContentYOffset
    }

    private var hiddenContentBlurRadius: CGFloat {
        reduceMotion ? 0 : RelayMotion.Style.surface.blurRadius
    }

    // The container is flipped, so a positive offset sits below the resting
    // position: content rises into place on reveal and sinks on hide.
    private static let hiddenContentYOffset: CGFloat = 14
    private static let revealTiming = RelayMotion.enterCurve.mediaTimingFunction
    private static let hideTiming = RelayMotion.exitCurve.mediaTimingFunction
    private static let contentBlurKeyPath = "filters.\(RelayLayerMotion.blurFilterName).inputRadius"
    private static let contentBlurAnimationKey = "boardRevealContentBlur"
}

private final class BoardRevealSurfaceView: NSView {
    private let plan: BoardRevealTransitionPlan
    private let surfaceMaskLayer = CAShapeLayer()
    private let loadingLabel = BoardRevealLoadingLabelView()
    private var surfaceFrame: CGRect
    private var loading = false
    private var loadingLabelVisible = false
    private var loadingLabelExitEndsAt: CFTimeInterval = 0
    private var animationTimer: Timer?
    private var animationCompletion: (() -> Void)?

    override var isFlipped: Bool { true }

    /// How long the loading label still needs to finish leaving.
    var loadingLabelExitRemaining: TimeInterval {
        max(0, loadingLabelExitEndsAt - CACurrentMediaTime())
    }

    init(frame: NSRect, plan: BoardRevealTransitionPlan) {
        self.plan = plan
        self.surfaceFrame = plan.compactFrame
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        surfaceMaskLayer.fillColor = NSColor.black.cgColor
        surfaceMaskLayer.actions = [
            "bounds": NSNull(),
            "path": NSNull(),
            "position": NSNull(),
        ]
        layer?.mask = surfaceMaskLayer
        loadingLabel.isHidden = true
        addSubview(loadingLabel)
        updateSurfaceMask()
        updateLoadingLabel(animated: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    var isCompact: Bool {
        animationTimer == nil && surfaceFrame == plan.compactFrame
    }

    deinit {
        cancelAnimation()
    }

    override func layout() {
        super.layout()
        updateSurfaceMask()
        updateLoadingLabel(animated: true)
    }

    func showExpanded() {
        cancelAnimation()
        surfaceFrame = plan.expandedFrame
        updateSurfaceMask()
        updateLoadingLabel(animated: false)
        needsDisplay = true
    }

    func showCompact() {
        cancelAnimation()
        surfaceFrame = plan.compactFrame
        updateSurfaceMask()
        updateLoadingLabel(animated: false)
        needsDisplay = true
    }

    func setLoading(_ loading: Bool) {
        guard self.loading != loading else { return }
        self.loading = loading
        updateLoadingLabel(animated: true)
    }

    func animateToFullWidth(
        firstMotion: (() -> Void)? = nil,
        completion: @escaping () -> Void
    ) {
        animate(
            to: plan.fullWidthFrame,
            duration: BoardRevealTransitionTiming.expandToFullWidthDuration,
            firstMotion: firstMotion,
            completion: completion
        )
    }

    func animateToExpanded(
        firstMotion: (() -> Void)? = nil,
        completion: @escaping () -> Void
    ) {
        animate(
            to: plan.expandedFrame,
            duration: BoardRevealTransitionTiming.expandDuration,
            firstMotion: firstMotion,
            completion: completion
        )
    }

    func animateToCompact(
        firstMotion: (() -> Void)? = nil,
        completion: @escaping () -> Void
    ) {
        animate(
            to: plan.compactFrame,
            duration: BoardRevealTransitionTiming.compactDuration,
            firstMotion: firstMotion,
            completion: completion
        )
    }

    func cancelAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationCompletion = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor(calibratedWhite: 0, alpha: 0.985).setFill()
        surfacePath(in: surfaceFrame).fill()
    }

    private func animate(
        to targetFrame: CGRect,
        duration: TimeInterval,
        firstMotion: (() -> Void)? = nil,
        completion: @escaping () -> Void
    ) {
        cancelAnimation()

        let startFrame = surfaceFrame
        let startTime = CACurrentMediaTime()
        var reportedFirstMotion = false
        animationCompletion = completion

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startTime
            let rawProgress = max(0, min(1, elapsed / duration))
            let progress = Self.easeOutQuart(CGFloat(rawProgress))
            self.surfaceFrame = Self.interpolate(from: startFrame, to: targetFrame, progress: progress)
            self.updateSurfaceMask()
            self.updateLoadingLabel(animated: true)
            self.needsDisplay = true
            if !reportedFirstMotion {
                reportedFirstMotion = true
                firstMotion?()
            }

            if rawProgress >= 1 {
                timer.invalidate()
                self.animationTimer = nil
                self.surfaceFrame = targetFrame
                self.updateSurfaceMask()
                self.updateLoadingLabel(animated: true)
                self.needsDisplay = true
                let completion = self.animationCompletion
                self.animationCompletion = nil
                completion?()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    /// Keeps the loading label centred on the surface and fades it in or out
    /// (with the horizontal text motion) when it starts or stops showing.
    private func updateLoadingLabel(animated: Bool) {
        let size = loadingLabel.intrinsicContentSize
        loadingLabel.frame = NSRect(
            x: surfaceFrame.midX - size.width / 2,
            y: surfaceFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        let visible = loading && surfaceFrame.height > plan.fullWidthFrame.height + 40
        guard visible != loadingLabelVisible else { return }
        loadingLabelVisible = visible
        let duration = animated && window != nil
            ? (visible ? RelayMotion.enterDuration : RelayMotion.exitDuration)
            : 0
        if visible {
            loadingLabelExitEndsAt = 0
            RelayLayerMotion.animateIn(loadingLabel, style: .text, duration: duration)
        } else {
            loadingLabelExitEndsAt = CACurrentMediaTime() + duration
            RelayLayerMotion.animateOut(loadingLabel, style: .text, duration: duration)
        }
    }

    private func surfacePath(in rect: CGRect) -> NSBezierPath {
        if let compactPath = compactNotchCutoutPath(in: rect) {
            return compactPath
        }
        return bottomRoundedPath(in: rect)
    }

    private func updateSurfaceMask() {
        surfaceMaskLayer.frame = bounds
        surfaceMaskLayer.path = surfacePath(in: surfaceFrame).cgPath
    }

    private func compactNotchCutoutPath(in rect: CGRect) -> NSBezierPath? {
        guard plan.compactNotchSpacerWidth > 0,
              rect.height <= plan.compactFrame.height + 0.5,
              rect.width <= plan.compactFrame.width + NotchStatusPlacementPlanner.glyphSize.height else {
            return nil
        }
        let topContact = NotchStatusSurfaceShape.topContact(
            activityLabelWidth: 0,
            leadingSpacerWidth: plan.compactLeadingSpacerWidth,
            notchSpacerWidth: plan.compactNotchSpacerWidth,
            boundsWidth: rect.width,
            boundsHeight: rect.height
        )
        guard let topContact else { return nil }
        return NotchStatusSurfaceShape.compactNotchCutoutPath(in: rect, topContact: topContact)
    }

    private func bottomRoundedPath(in rect: CGRect) -> NSBezierPath {
        let radius = min(
            BoardRevealTransitionPlanner.expandedSurfaceCornerRadius,
            rect.height / 2,
            rect.width / 2
        )
        let control = radius * 0.5522847498307936
        let path = NSBezierPath()

        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
        path.curve(
            to: NSPoint(x: rect.maxX - radius, y: rect.maxY),
            controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - radius + control),
            controlPoint2: NSPoint(x: rect.maxX - radius + control, y: rect.maxY)
        )
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.curve(
            to: NSPoint(x: rect.minX, y: rect.maxY - radius),
            controlPoint1: NSPoint(x: rect.minX + radius - control, y: rect.maxY),
            controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - radius + control)
        )
        path.close()
        return path
    }

    private static func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * progress,
            y: start.minY + (end.minY - start.minY) * progress,
            width: start.width + (end.width - start.width) * progress,
            height: start.height + (end.height - start.height) * progress
        )
    }

    private static func easeOutQuart(_ value: CGFloat) -> CGFloat {
        let inverse = 1 - value
        return 1 - inverse * inverse * inverse * inverse
    }
}

private final class BoardRevealLoadingLabelView: NSView {
    // Room around the text so the transition blur is not clipped.
    private static let blurMargin: CGFloat = 8
    private let text = BoardUpdateStatus.workingLabel as NSString
    private let attributes: [NSAttributedString.Key: Any] = [
        .font: AppTypography.appKitFont(.sectionHeading),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ]

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let size = text.size(withAttributes: attributes)
        return NSSize(
            width: size.width + Self.blurMargin * 2,
            height: size.height + Self.blurMargin * 2
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        text.draw(
            in: bounds.insetBy(dx: Self.blurMargin, dy: Self.blurMargin),
            withAttributes: attributes
        )
    }
}

/// A scalar that eases toward its target on the caller's display timer.
struct BoardRevealEasedValue {
    private(set) var value: CGFloat
    private(set) var target: CGFloat
    private var startValue: CGFloat
    private var startTime: CFTimeInterval?
    let duration: TimeInterval
    let curve: RelayMotion.Curve

    init(_ value: CGFloat, duration: TimeInterval, curve: RelayMotion.Curve) {
        self.value = value
        self.target = value
        self.startValue = value
        self.duration = duration
        self.curve = curve
    }

    var isAnimating: Bool { startTime != nil }

    mutating func set(_ newTarget: CGFloat, animated: Bool, now: CFTimeInterval) {
        guard newTarget != target else { return }
        target = newTarget
        if animated, duration > 0 {
            startValue = value
            startTime = now
        } else {
            value = newTarget
            startTime = nil
        }
    }

    mutating func advance(to now: CFTimeInterval) {
        guard let startTime else { return }
        let fraction = CGFloat((now - startTime) / duration)
        guard fraction < 1 else {
            value = target
            self.startTime = nil
            return
        }
        value = startValue + (target - startValue) * curve.progress(fraction)
    }
}

private final class BoardRevealGlyphView: NSView {
    private let plan: BoardRevealTransitionPlan
    private var loading = false
    private var glyphHovered = false
    // Crossfades the resting glyph with the animated working glyph so a
    // loading or update-check change never snaps.
    private var activity = BoardRevealEasedValue(
        0,
        duration: RelayMotion.changeDuration,
        curve: RelayMotion.changeCurve
    )
    private var hover = BoardRevealEasedValue(
        0,
        duration: RelayMotion.hoverDuration,
        curve: RelayMotion.changeCurve
    )
    private var trackingArea: NSTrackingArea?
    private var animationTimer: Timer?

    override var isFlipped: Bool { true }

    init(frame: NSRect, plan: BoardRevealTransitionPlan) {
        self.plan = plan
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        animationTimer?.invalidate()
    }

    func setLoading(_ loading: Bool) {
        guard self.loading != loading else { return }
        self.loading = loading
        activity.set(
            loading ? 1 : 0,
            animated: window != nil && !Self.reduceMotion,
            now: CACurrentMediaTime()
        )
        updateAnimationTimer()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        currentGlyphFrame().contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }

        let area = NSTrackingArea(
            rect: currentGlyphFrame(),
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        refreshHoverFromMouseLocation()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshHoverFromMouseLocation()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let glyphFrame = currentGlyphFrame()
        let artworkSize = NotchStatusGlyph.artworkSize
        let dotOrigin = CGPoint(
            x: glyphFrame.minX + (glyphFrame.width - artworkSize.width) / 2,
            y: glyphFrame.minY + (glyphFrame.height - artworkSize.height) / 2
        )
        let time = CACurrentMediaTime()

        if hover.value > 0 {
            NSColor(calibratedWhite: 0.85, alpha: 0.25 * hover.value).setFill()
            NSBezierPath(
                ovalIn: NSRect(x: dotOrigin.x + 2, y: dotOrigin.y + 2, width: 20, height: 20)
            ).fill()
        }

        // Under Reduce Motion the working glyph is drawn at rest, exactly
        // like the idle glyph, so only the resting pass is needed.
        let workingWeight = Self.reduceMotion ? 0 : activity.value
        if workingWeight < 1 {
            drawDots(status: .notWorking, animated: false, alpha: 1 - workingWeight, origin: dotOrigin, time: time)
        }
        if workingWeight > 0 {
            drawDots(status: .working, animated: true, alpha: workingWeight, origin: dotOrigin, time: time)
        }
    }

    private func drawDots(
        status: NotchSessionStatus,
        animated: Bool,
        alpha: CGFloat,
        origin dotOrigin: CGPoint,
        time: CFTimeInterval
    ) {
        let motionPhase = animated ? NotchStatusGlyphMotion.phase(at: time) : 0
        for (index, dot) in status.glyph.dots.enumerated() {
            let shimmer = animated
                ? 0.72 + 0.28 * ((Darwin.sin(time * 5.2 + Double(index) * 0.62) + 1) / 2)
                : 1
            let center = animated
                ? NotchStatusGlyphMotion.transformedCenter(for: dot, status: status, phase: motionPhase)
                : CGPoint(x: dot.x, y: dot.y)
            let rect = NSRect(
                x: dotOrigin.x + center.x - dot.diameter / 2,
                y: dotOrigin.y + center.y - dot.diameter / 2,
                width: dot.diameter,
                height: dot.diameter
            )
            dot.color.boardRevealNSColor.withAlphaComponent(dot.opacity * shimmer * alpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    private func updateAnimationTimer() {
        let needsFrames = (loading && !Self.reduceMotion) || activity.isAnimating || hover.isAnimating
        if needsFrames {
            guard animationTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.advanceFrame()
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func advanceFrame() {
        let now = CACurrentMediaTime()
        activity.advance(to: now)
        hover.advance(to: now)
        needsDisplay = true
        if !activity.isAnimating, !hover.isAnimating {
            updateAnimationTimer()
        }
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovered(currentGlyphFrame().contains(point))
    }

    private func refreshHoverFromMouseLocation() {
        guard let window else {
            setHovered(false)
            return
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(windowPoint, from: nil)
        setHovered(currentGlyphFrame().contains(point))
    }

    private func setHovered(_ hovered: Bool) {
        guard glyphHovered != hovered else { return }
        glyphHovered = hovered
        hover.set(hovered ? 1 : 0, animated: window != nil, now: CACurrentMediaTime())
        updateAnimationTimer()
        needsDisplay = true
    }

    private func currentGlyphFrame() -> NSRect {
        NSRect(
            x: plan.glyphFrame.minX,
            y: plan.glyphFrame.minY,
            width: plan.glyphFrame.width,
            height: plan.glyphFrame.height
        )
    }
}

private extension NotchStatusDotColor {
    var boardRevealNSColor: NSColor {
        switch self {
        case .white:
            return .white
        case .orange:
            return NSColor(calibratedRed: 0.949, green: 0.439, blue: 0.047, alpha: 1)
        case .blue:
            return NSColor(calibratedRed: 0.169, green: 0.067, blue: 0.910, alpha: 1)
        }
    }
}
