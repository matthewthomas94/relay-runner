import AppKit
import CoreImage

/// Bottom-center pill showing state info, live transcription, or message preview.
/// Dark solid surface matching the board overlay styling.
///
/// Animation contract:
///   - Entrance: slide up from below screen + Gaussian blur 64→0
///   - Exit: slide down below screen + Gaussian blur 0→64
///   - State transitions (while visible): blur out → update content → blur in
///   - Content updates within same state: smooth in-place resize
///   - All movement is purely vertical (Y-axis only)
final class TranscriptionPill: NSView {
    enum DarkSurfaceStyle {
        static let pillFill = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        static let border = NSColor(
            srgbRed: 17 / 255,
            green: 22 / 255,
            blue: 29 / 255,
            alpha: 1
        )
        static let shadowOpacity: Float = 0.08
        static let shadowRadius: CGFloat = 4
    }

    enum Theme {
        case stt
        case tts
    }

    // Unused — kept for API compat; particles render behind the pill unmasked
    var onFrameChanged: ((CGRect) -> Void)?

    private let surfaceContainerView = NSView()
    private let fillLayer = CALayer()
    private let borderLayer = CAShapeLayer()

    private let titleLabel: NSTextField
    private let bodyLabel: NSTextField
    /// Clips bodyLabel to maxBodyHeight so long TTS responses don't grow the
    /// pill into a wall of text. When the label exceeds the container, the
    /// label is animated upward inside the container (teleprompter-style).
    private let bodyContainer = NSView()

    private let maxWidth: CGFloat = 460
    /// Cap for the visible body region. Around 4 lines at 14pt — matches the
    /// natural footprint of the legacy 200-char preview, so the pill stays
    /// unobtrusive even for long responses. Anything taller scrolls.
    private let maxBodyHeight: CGFloat = 96
    private let pillPadH: CGFloat = 24
    private let pillPadV: CGFloat = 18
    private let textGap: CGFloat = 12
    private let cr: CGFloat = 16
    private let bottomOffset: CGFloat = 56

    private let textColor = NSColor(red: 226 / 255, green: 232 / 255, blue: 240 / 255, alpha: 1)

    private var isCompact = true
    private var isTransitioning = false
    private var currentTheme: Theme?

    /// Latest pill size requested via `transitionContent`. The deferred
    /// callback reads these instead of its captured arguments so that a
    /// rapid follow-up `showCompact` (e.g. .sent → .processing within one
    /// 30fps tick) doesn't get clobbered by the original size animating
    /// back in at peak blur.
    private var pendingTransitionWidth: CGFloat?
    private var pendingTransitionHeight: CGFloat?
    /// Invalidates a hide completion when newer pill content is presented.
    private var visibilityGeneration: UInt = 0

    /// Active body-scroll animation timer. Replaced/cancelled when state
    /// changes or the pill hides.
    private var bodyScrollTimer: Timer?
    /// Body text the active scroll is animating through. When showFull is
    /// re-invoked with the same body (e.g. messageWaiting → speaking flips
    /// the title but keeps the preview), we keep the existing scroll going
    /// instead of snapping back to the top.
    private var scrolledBodyText: String?
    /// True once the user has manually scrolled the body. Auto-teleprompter
    /// is cancelled and not restarted while this body text is displayed.
    /// Reset to false when the body text changes (new message).
    private var manualScrollEngaged = false
    /// Invalidates a teleprompter start that is still inside its initial
    /// reading pause. A Timer alone cannot cancel that pending asyncAfter.
    private var bodyScrollGeneration: UInt = 0

    // Spring-damped timing for Apple-like feel
    private let springTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
    private let entranceDuration: CFTimeInterval = 0.5
    private let exitDuration: CFTimeInterval = 0.3
    private let transitionBlurDuration: CFTimeInterval = 0.12
    private let transitionUnblurDuration: CFTimeInterval = 0.4

    override init(frame: NSRect) {
        titleLabel = NSTextField(labelWithString: "")
        bodyLabel = NSTextField(labelWithString: "")

        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        alphaValue = 0

        // Subtle Figma L1-style shadow on root layer.
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        layer?.shadowRadius = DarkSurfaceStyle.shadowRadius
        layer?.shadowOpacity = 0

        // Blur filter for entrance/exit transitions
        let motionBlur = CIFilter(name: "CIGaussianBlur")!
        motionBlur.name = "motionBlur"
        motionBlur.setValue(0, forKey: kCIInputRadiusKey)
        layer?.filters = [motionBlur]

        surfaceContainerView.wantsLayer = true
        surfaceContainerView.layer?.cornerRadius = cr
        surfaceContainerView.layer?.masksToBounds = true
        addSubview(surfaceContainerView)

        fillLayer.backgroundColor = DarkSurfaceStyle.pillFill.cgColor
        surfaceContainerView.layer?.addSublayer(fillLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = DarkSurfaceStyle.border.cgColor
        borderLayer.lineWidth = 1.0
        surfaceContainerView.layer?.addSublayer(borderLayer)

        // Title label
        titleLabel.font = AppTypography.appKitFont(.pillTitle)
        titleLabel.textColor = textColor
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        addSubview(titleLabel)

        // Body container — clips bodyLabel to maxBodyHeight so overflowing
        // text scrolls inside the visible window instead of resizing the pill.
        bodyContainer.wantsLayer = true
        bodyContainer.layer?.masksToBounds = true
        bodyContainer.isHidden = true
        bodyContainer.alphaValue = 0
        addSubview(bodyContainer)

        // Body label — sized to full content height even when overflowing
        // bodyContainer; the container does the clipping.
        bodyLabel.font = AppTypography.appKitFont(.pillBody)
        bodyLabel.textColor = textColor
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.alignment = .left
        bodyLabel.cell?.truncatesLastVisibleLine = false
        bodyContainer.addSubview(bodyLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API

    func showCompact(title: String, theme: Theme, animated: Bool = true) {
        visibilityGeneration &+= 1
        let wasVisible = alphaValue > 0.01
        let wasCompact = isCompact
        let themeChanged = currentTheme.map { type(of: $0) != type(of: theme) } ?? true

        applyTypography()
        applyTheme(theme)
        titleLabel.stringValue = title
        titleLabel.alignment = .center
        isCompact = true

        titleLabel.sizeToFit()
        let titleSize = titleLabel.frame.size
        let pillWidth = ceil(titleSize.width) + pillPadH * 2 + 8  // 8px buffer prevents truncation
        let pillHeight = ceil(titleSize.height) + pillPadV * 2

        if wasVisible && animated && (!wasCompact || themeChanged) {
            // State-to-state transition: blur out → update → blur in
            transitionContent(width: pillWidth, height: pillHeight)
        } else if wasVisible {
            // Same-state update: smooth resize
            applyLayout(width: pillWidth, height: pillHeight, animated: animated)
        } else {
            // Fresh entrance
            applyLayout(width: pillWidth, height: pillHeight, animated: false)
            slideIn(animated: animated)
        }
    }

    func showFull(title: String,
                  body: String,
                  theme: Theme,
                  animated: Bool = true,
                  suppressShadow: Bool = false) {
        visibilityGeneration &+= 1
        let wasVisible = alphaValue > 0.01
        let wasCompact = isCompact

        applyTypography()
        applyTheme(theme)
        if suppressShadow {
            layer?.shadowOpacity = 0
        }
        titleLabel.stringValue = title
        titleLabel.alignment = .left
        // New body text means a fresh message — drop any manual-scroll override
        // so the next layout starts from the top with the auto-teleprompter
        // (or pin-to-bottom for STT). Same body across state transitions
        // (messageWaiting → speaking) keeps the user's manual position.
        if bodyLabel.stringValue != body {
            manualScrollEngaged = false
        }
        bodyLabel.stringValue = body
        isCompact = false

        let contentWidth = maxWidth - pillPadH * 2
        let titleSize = titleLabel.sizeThatFits(NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let bodySize = bodyLabel.sizeThatFits(NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
        // Cap body region — long responses scroll inside the container.
        let bodyVisibleHeight = min(bodySize.height, maxBodyHeight)
        let pillHeight = pillPadV + titleSize.height + textGap + bodyVisibleHeight + pillPadV

        if wasVisible && animated && wasCompact {
            // Compact → Full transition: blur out → update → blur in
            transitionContent(width: maxWidth, height: pillHeight)
        } else if wasVisible {
            // Same-state content update: smooth resize
            applyLayout(width: maxWidth, height: pillHeight, animated: animated)
            if bodyContainer.isHidden {
                bodyContainer.isHidden = false
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bodyContainer.animator().alphaValue = 1
            }
        } else {
            // Fresh entrance
            bodyContainer.isHidden = false
            bodyContainer.alphaValue = 1
            applyLayout(width: maxWidth, height: pillHeight, animated: false)
            slideIn(animated: animated)
        }
    }

    func hide(animated: Bool = true) {
        guard alphaValue > 0.01 else { return }

        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        cancelBodyScroll()

        if animated {
            // Blur out + slide down
            animateBlur(from: 0, to: 48, duration: exitDuration)

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = exitDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                var exitFrame = frame
                exitFrame.origin.y = -frame.height - 20
                animator().frame = exitFrame
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.visibilityGeneration == generation else { return }
                self.resetBlurFilter()
                self.bodyContainer.isHidden = true
                self.bodyContainer.alphaValue = 0
            })
        } else {
            alphaValue = 0
            bodyContainer.isHidden = true
            bodyContainer.alphaValue = 0
        }
    }

    // MARK: - Animation: Entrance

    private func slideIn(animated: Bool) {
        guard animated else {
            alphaValue = 1
            return
        }

        // Start below the screen edge — no particle hole until pill arrives
        let targetFrame = frame
        var startFrame = targetFrame
        startFrame.origin.y = -targetFrame.height - 20
        frame = startFrame
        alphaValue = 1


        // Blur entrance: 64 → 0
        animateBlur(from: 64, to: 0, duration: entranceDuration)

        // Slide up with spring timing
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = entranceDuration
            ctx.timingFunction = springTiming
            animator().frame = targetFrame
        })
    }

    // MARK: - Animation: State-to-state transition

    /// Blur out current content, apply layout changes, blur back in.
    /// Content changes are masked by the peak blur so the user never
    /// sees an abrupt visual switch.
    private func transitionContent(width: CGFloat, height: CGFloat) {
        // Always record the latest target so the deferred callback resizes
        // to the most recent showCompact/showFull, not the one that kicked
        // off the blur.
        pendingTransitionWidth = width
        pendingTransitionHeight = height

        guard !isTransitioning else {
            // If already transitioning, just update layout immediately
            applyLayout(width: width, height: height, animated: false)
            return
        }
        isTransitioning = true

        // Phase 1: Blur out (quick)
        animateBlur(from: 0, to: 40, duration: transitionBlurDuration)

        // Phase 2: At peak blur, update layout and blur back in
        DispatchQueue.main.asyncAfter(deadline: .now() + transitionBlurDuration * 0.8) { [weak self] in
            guard let self else { return }

            // Update layout at peak blur (content change is invisible).
            // Read the latest target rather than the captured args.
            let targetWidth = self.pendingTransitionWidth ?? width
            let targetHeight = self.pendingTransitionHeight ?? height
            self.applyLayout(width: targetWidth, height: targetHeight, animated: true, duration: self.transitionUnblurDuration)

            // Show body if full mode
            if !self.isCompact {
                if self.bodyContainer.isHidden {
                    self.bodyContainer.isHidden = false
                }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = self.transitionUnblurDuration
                    self.bodyContainer.animator().alphaValue = 1
                }
            }

            // Phase 3: Blur back in
            self.animateBlur(from: 40, to: 0, duration: self.transitionUnblurDuration)

            DispatchQueue.main.asyncAfter(deadline: .now() + self.transitionUnblurDuration) {
                self.isTransitioning = false
            }
        }
    }

    // MARK: - Animation: Blur filter

    private func animateBlur(from fromValue: CGFloat, to toValue: CGFloat, duration: CFTimeInterval) {
        let anim = CABasicAnimation(keyPath: "filters.motionBlur.inputRadius")
        anim.fromValue = fromValue
        anim.toValue = toValue
        anim.duration = duration
        anim.timingFunction = springTiming
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        layer?.add(anim, forKey: "motionBlurAnim")
    }

    private func resetBlurFilter() {
        layer?.removeAnimation(forKey: "motionBlurAnim")
        if let filter = layer?.filters?.first as? CIFilter {
            filter.setValue(0, forKey: kCIInputRadiusKey)
        }
    }

    // MARK: - Layout

    private func applyTheme(_ theme: Theme) {
        currentTheme = theme
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = DarkSurfaceStyle.shadowOpacity
        fillLayer.backgroundColor = DarkSurfaceStyle.pillFill.cgColor
        borderLayer.strokeColor = DarkSurfaceStyle.border.cgColor
    }

    private func applyTypography() {
        titleLabel.font = AppTypography.appKitFont(.pillTitle)
        titleLabel.textColor = textColor
        bodyLabel.font = AppTypography.appKitFont(.pillBody)
        bodyLabel.textColor = textColor
    }

    private func applyLayout(width: CGFloat, height: CGFloat, animated: Bool, duration: CFTimeInterval = 0.4) {
        guard let superview = superview else { return }

        let x = (superview.bounds.width - width) / 2
        let targetFrame = NSRect(x: x, y: bottomOffset, width: width, height: height)
        let targetBounds = NSRect(x: 0, y: 0, width: width, height: height)

        let inset = targetBounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = currentCornerRadius
        let crPath = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
        surfaceContainerView.layer?.cornerRadius = radius

        if animated && alphaValue > 0.01 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = springTiming
                animator().frame = targetFrame
                surfaceContainerView.animator().frame = targetBounds
            }
            // Animate CALayer frames in sync
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(springTiming)
            applyInternalLayerFrames(targetBounds, borderPath: crPath)
            CATransaction.commit()
        } else {
            frame = targetFrame
            surfaceContainerView.frame = targetBounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyInternalLayerFrames(targetBounds, borderPath: crPath)
            CATransaction.commit()
        }

        layoutLabels(targetBounds: targetBounds, animated: animated, duration: duration)
    }

    /// Set all internal CALayer frames — called inside a CATransaction.
    private func applyInternalLayerFrames(_ bounds: NSRect, borderPath: CGPath) {
        fillLayer.frame = bounds
        borderLayer.path = borderPath
        borderLayer.frame = bounds
    }

    private func layoutLabels(targetBounds: NSRect, animated: Bool, duration: CFTimeInterval = 0.4) {
        let contentWidth = targetBounds.width - currentPadH * 2
        let titleHeight = titleLabel.sizeThatFits(NSSize(width: contentWidth, height: .greatestFiniteMagnitude)).height

        if isCompact {
            cancelBodyScroll()
            let titleFrame = NSRect(
                x: currentPadH,
                y: (targetBounds.height - titleHeight) / 2,
                width: contentWidth,
                height: titleHeight
            )
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    ctx.timingFunction = springTiming
                    titleLabel.animator().frame = titleFrame
                    bodyContainer.animator().alphaValue = 0
                }
            } else {
                titleLabel.frame = titleFrame
                bodyContainer.alphaValue = 0
                bodyContainer.isHidden = true
            }
        } else {
            // Full content height (may exceed maxBodyHeight); container clips
            // it and we scroll the label inside if overflowing.
            let bodyContentHeight = bodyLabel.sizeThatFits(NSSize(width: contentWidth, height: .greatestFiniteMagnitude)).height
            let hasBody = !bodyLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let bodyVisibleHeight = hasBody ? min(bodyContentHeight, currentMaxBodyHeight) : 0
            let totalContent = titleHeight + (hasBody ? currentTextGap + bodyVisibleHeight : 0)
            let startY = (targetBounds.height - totalContent) / 2

            let containerFrame = NSRect(x: currentPadH, y: startY, width: contentWidth, height: bodyVisibleHeight)
            let titleFrameY = hasBody ? startY + bodyVisibleHeight + currentTextGap : startY
            let titleFrame = NSRect(x: currentPadH, y: titleFrameY, width: contentWidth, height: titleHeight)

            // Top-anchored: label's top edge lines up with container's top
            // edge. NSView origin is bottom-left, so the label's y is
            // (visible - content), which is ≤ 0 whenever we're overflowing.
            // We later animate this y upward toward 0 to reveal the rest.
            let initialLabelY = bodyVisibleHeight - bodyContentHeight

            // STT live transcription pins to the bottom (latest line always
            // visible) instead of running the teleprompter — partial text
            // grows as the user speaks, and auto-scrolling from the top each
            // time the body changes produces the "hitch and restart" loop.
            // Manual user scroll preserves whatever y the user landed on.
            // Otherwise (TTS, fresh entrance) start at the top and let the
            // teleprompter reveal the rest.
            let isSttPinToBottom = themeMatches(.stt) && bodyContentHeight > maxBodyHeight
            let scrollContinues = bodyLabel.stringValue == scrolledBodyText
            let preservedY: CGFloat
            if isSttPinToBottom {
                preservedY = 0  // bottom of label aligned with bottom of container = latest text
            } else if manualScrollEngaged {
                preservedY = bodyLabel.frame.origin.y
            } else if scrollContinues {
                preservedY = bodyLabel.frame.origin.y
            } else {
                preservedY = initialLabelY
            }
            let labelFrame = NSRect(x: 0, y: preservedY, width: contentWidth, height: bodyContentHeight)

            if bodyContainer.isHidden {
                bodyContainer.frame = containerFrame
                bodyLabel.frame = labelFrame
                bodyContainer.isHidden = !hasBody
            }

            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    ctx.timingFunction = springTiming
                    bodyContainer.animator().frame = containerFrame
                    bodyContainer.animator().alphaValue = hasBody ? 1 : 0
                    titleLabel.animator().frame = titleFrame
                }
                // Snap the label to its starting position inside the container
                // — animating the inner label's frame alongside the container
                // resize fights with the scroll animation we're about to start.
                bodyLabel.frame = labelFrame
            } else {
                bodyContainer.frame = containerFrame
                bodyContainer.alphaValue = hasBody ? 1 : 0
                bodyContainer.isHidden = !hasBody
                bodyLabel.frame = labelFrame
                titleLabel.frame = titleFrame
            }

            // Trigger or cancel the teleprompter scroll based on overflow.
            // STT pins to the bottom (no scroll). Manual scroll has taken
            // control. Otherwise: TTS auto-teleprompter, preserved if the
            // existing timer is already animating this same text.
            if bodyContentHeight > currentMaxBodyHeight {
                if isSttPinToBottom || manualScrollEngaged {
                    cancelBodyScroll()
                } else if !scrollContinues {
                    startBodyScroll(targetY: 0)
                }
            } else {
                cancelBodyScroll()
            }
        }

    }

    // MARK: - Body scroll (teleprompter)

    /// Linearly translate bodyLabel upward inside bodyContainer so the user
    /// can read text that overflows the visible window. Uses a 1-second
    /// pause at the start (so the user has time to read the first lines)
    /// and a fixed 25 px/sec scroll speed — slow enough to read comfortably
    /// alongside TTS narration. One-pass, no looping; if TTS keeps going
    /// past the end, the label just rests at the bottom-aligned position.
    private func startBodyScroll(targetY: CGFloat) {
        cancelBodyScroll()

        let scrollSpeed: CGFloat = 25  // px/sec
        let pauseSeconds: TimeInterval = 1.0
        let tickInterval: TimeInterval = 1.0 / 60
        let pixelsPerTick = scrollSpeed * CGFloat(tickInterval)

        let initialY = bodyLabel.frame.origin.y
        guard initialY < targetY else { return }

        // Mark which body text the active scroll is animating, so a re-layout
        // for the same text can detect that the scroll is still valid and
        // preserve position instead of restarting from the top.
        scrolledBodyText = bodyLabel.stringValue
        let generation = bodyScrollGeneration

        DispatchQueue.main.asyncAfter(deadline: .now() + pauseSeconds) { [weak self] in
            guard let self else { return }
            guard self.bodyScrollGeneration == generation else { return }
            // The state may have changed during the pause; bail if so.
            guard !self.bodyContainer.isHidden, self.bodyContainer.alphaValue > 0.01 else { return }
            // Use .common runloop mode so the timer keeps firing during
            // NSAnimationContext-driven layout passes (which run on the
            // default mode and would otherwise stall the scroll).
            let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let currentY = self.bodyLabel.frame.origin.y
                if currentY >= targetY {
                    timer.invalidate()
                    self.bodyScrollTimer = nil
                    self.scrolledBodyText = nil
                    return
                }
                var newFrame = self.bodyLabel.frame
                newFrame.origin.y = min(currentY + pixelsPerTick, targetY)
                self.bodyLabel.frame = newFrame
            }
            RunLoop.main.add(timer, forMode: .common)
            self.bodyScrollTimer = timer
        }
    }

    private func cancelBodyScroll() {
        bodyScrollGeneration &+= 1
        bodyScrollTimer?.invalidate()
        bodyScrollTimer = nil
        scrolledBodyText = nil
    }

    // MARK: - Manual scroll (trackpad / mouse wheel over the pill)

    /// Trackpad or mouse-wheel scroll on the pill takes manual control of
    /// the body scroll: the auto-teleprompter is cancelled and the user
    /// drives the y position directly, clamped to the visible/content range.
    /// Only active for TTS-themed full pills with overflowing body — STT
    /// pin-to-bottom and compact pills fall through to default handling.
    override func scrollWheel(with event: NSEvent) {
        guard acceptsManualScroll else {
            super.scrollWheel(with: event)
            return
        }

        manualScrollEngaged = true
        cancelBodyScroll()

        let bodyContentHeight = bodyLabel.frame.height
        let bodyVisibleHeight = bodyContainer.frame.height
        // origin.y range when overflowing: [bodyVisibleHeight - bodyContentHeight, 0]
        // (negative bound shows the top; 0 shows the bottom). scrollingDeltaY's
        // sign reflects raw device direction; macOS sets isDirectionInvertedFromDevice
        // when the user has natural scrolling enabled, so we undo the inversion to
        // get a consistent "positive delta = reveal later content" interpretation.
        let minY = bodyVisibleHeight - bodyContentHeight
        let maxY: CGFloat = 0
        let currentY = bodyLabel.frame.origin.y
        let lineHeight = bodyLabel.font.map {
            ceil($0.ascender - $0.descender + $0.leading)
        } ?? 16
        let delta = Self.manualScrollDelta(
            scrollingDeltaY: event.scrollingDeltaY,
            directionInvertedFromDevice: event.isDirectionInvertedFromDevice,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            lineHeight: lineHeight
        )
        let newY = max(minY, min(maxY, currentY + delta))
        if newY != currentY {
            var f = bodyLabel.frame
            f.origin.y = newY
            bodyLabel.frame = f
        }
    }

    static func manualScrollDelta(
        scrollingDeltaY: CGFloat,
        directionInvertedFromDevice: Bool,
        hasPreciseScrollingDeltas: Bool,
        lineHeight: CGFloat
    ) -> CGFloat {
        let deviceDelta = directionInvertedFromDevice ? -scrollingDeltaY : scrollingDeltaY
        return deviceDelta * (hasPreciseScrollingDeltas ? 1 : lineHeight)
    }

    /// Scroll events can land on the title or clipped body label. Claim the
    /// hit at the pill boundary while manual scrolling is available so every
    /// visible region follows the same responder path.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit supplies this point in the superview's coordinate space.
        guard acceptsManualScroll, frame.contains(point) else {
            return super.hitTest(point)
        }
        return self
    }

    // MARK: - Pill frame in screen coordinates (for selective click-through)

    /// The scrollable pill's frame in screen coordinates. Compact,
    /// non-overflowing, STT, hidden, and detached pills return nil so the
    /// full-screen overlay remains click-through for those states.
    func manualScrollFrameOnScreen() -> NSRect? {
        guard acceptsManualScroll, let window, window.isVisible else { return nil }
        let frameInWindow = convert(bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    private var acceptsManualScroll: Bool {
        !isCompact
            && !themeMatches(.stt)
            && !isHidden
            && alphaValue > 0.01
            && !bodyContainer.isHidden
            && bodyContainer.alphaValue > 0.01
            && bodyLabel.frame.height > bodyContainer.frame.height
    }

    // MARK: - Show helper (for theme comparison)

    private func themeMatches(_ theme: Theme) -> Bool {
        guard let current = currentTheme else { return false }
        switch (current, theme) {
        case (.stt, .stt), (.tts, .tts): return true
        default: return false
        }
    }

    private var currentPadH: CGFloat {
        pillPadH
    }

    private var currentPadV: CGFloat {
        pillPadV
    }

    private var currentTextGap: CGFloat {
        textGap
    }

    private var currentCornerRadius: CGFloat {
        cr
    }

    private var currentMaxBodyHeight: CGFloat {
        maxBodyHeight
    }
}
