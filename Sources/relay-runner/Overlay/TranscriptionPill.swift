import AppKit
import CoreImage

/// Bottom-center pill showing state info, live transcription, or message preview.
/// Liquid glass style: within-window blur refracts particles, specular border, themed glow shadow.
///
/// Animation contract:
///   - Entrance: slide up from below screen + Gaussian blur 64→0
///   - Exit: slide down below screen + Gaussian blur 0→64
///   - State transitions (while visible): blur out → update content → blur in
///   - Content updates within same state: smooth in-place resize
///   - All movement is purely vertical (Y-axis only)
final class TranscriptionPill: NSView {

    enum Theme {
        case stt
        case tts

        var primaryShadowColor: CGColor {
            switch self {
            case .stt: return NSColor(red: 244 / 255, green: 60 / 255, blue: 9 / 255, alpha: 1).cgColor
            case .tts: return NSColor(red: 40 / 255, green: 17 / 255, blue: 208 / 255, alpha: 1).cgColor
            }
        }

        var secondaryShadowColor: CGColor {
            switch self {
            case .stt: return NSColor(red: 242 / 255, green: 223 / 255, blue: 12 / 255, alpha: 1).cgColor
            case .tts: return NSColor(red: 198 / 255, green: 191 / 255, blue: 249 / 255, alpha: 1).cgColor
            }
        }
    }

    // Unused — kept for API compat; particles render behind the pill unmasked
    var onFrameChanged: ((CGRect) -> Void)?

    private let backgroundBlurView = NSVisualEffectView()
    private let glassContainerView = NSView()

    // Glass layers
    private let solidFillLayer = CALayer()
    private let backdropLayer = CALayer()
    private let gradientFillLayer = CAGradientLayer()
    private let specularLayer = CAGradientLayer()
    private let borderGradientLayer = CAGradientLayer()
    private let borderMaskLayer = CAShapeLayer()

    private let titleLabel: NSTextField
    private let bodyLabel: NSTextField
    /// Clips bodyLabel to maxBodyHeight so long TTS responses don't grow the
    /// pill into a wall of text. When the label exceeds the container, the
    /// label is animated upward inside the container (teleprompter-style).
    private let bodyContainer = NSView()

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let blurFilter = CIFilter(name: "CIGaussianBlur")!

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

    /// Active body-scroll animation timer. Replaced/cancelled when state
    /// changes or the pill hides.
    private var bodyScrollTimer: Timer?
    /// Body text the active scroll is animating through. When showFull is
    /// re-invoked with the same body (e.g. messageWaiting → speaking flips
    /// the title but keeps the preview), we keep the existing scroll going
    /// instead of snapping back to the top.
    private var scrolledBodyText: String?

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

        // Primary shadow on root layer
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.shadowRadius = 20
        layer?.shadowOpacity = 0

        // Blur filter for entrance/exit transitions
        let motionBlur = CIFilter(name: "CIGaussianBlur")!
        motionBlur.name = "motionBlur"
        motionBlur.setValue(0, forKey: kCIInputRadiusKey)
        layer?.filters = [motionBlur]

        // Background blur for external apps behind the overlay window
        backgroundBlurView.blendingMode = .behindWindow
        backgroundBlurView.material = .underWindowBackground
        backgroundBlurView.appearance = NSAppearance(named: .darkAqua)
        backgroundBlurView.state = .active
        backgroundBlurView.wantsLayer = true
        backgroundBlurView.layer?.cornerRadius = cr
        backgroundBlurView.layer?.masksToBounds = true
        addSubview(backgroundBlurView)

        // Glass container (clips all internal layers)
        glassContainerView.wantsLayer = true
        glassContainerView.layer?.cornerRadius = cr
        glassContainerView.layer?.masksToBounds = true
        addSubview(glassContainerView)

        // Dark base fill
        solidFillLayer.backgroundColor = NSColor(white: 0.0, alpha: 0.45).cgColor
        glassContainerView.layer?.addSublayer(solidFillLayer)

        // Blurred particle backdrop
        glassContainerView.layer?.addSublayer(backdropLayer)

        // Gradient overlay
        gradientFillLayer.colors = [
            NSColor(white: 0.0, alpha: 0.10).cgColor,
            NSColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 0.10).cgColor,
        ]
        gradientFillLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradientFillLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        glassContainerView.layer?.addSublayer(gradientFillLayer)

        // Top specular highlight
        specularLayer.colors = [
            NSColor(white: 1, alpha: 0.0).cgColor,
            NSColor(white: 1, alpha: 0.1).cgColor,
        ]
        specularLayer.startPoint = CGPoint(x: 0.5, y: 0)
        specularLayer.endPoint = CGPoint(x: 0.5, y: 1)
        glassContainerView.layer?.addSublayer(specularLayer)

        // Border stroke
        borderMaskLayer.fillColor = nil
        borderMaskLayer.strokeColor = NSColor.white.cgColor
        borderMaskLayer.lineWidth = 1.0

        borderGradientLayer.colors = [
            NSColor(white: 1, alpha: 0.0).cgColor,
            NSColor(white: 1, alpha: 0.0).cgColor,
            NSColor(white: 1, alpha: 0.1).cgColor,
        ]
        borderGradientLayer.locations = [0.0, 0.1, 1]
        borderGradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        borderGradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        borderGradientLayer.mask = borderMaskLayer
        glassContainerView.layer?.addSublayer(borderGradientLayer)

        // Title label
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
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
        bodyLabel.font = .systemFont(ofSize: 14, weight: .regular)
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
        let wasVisible = alphaValue > 0.01
        let wasCompact = isCompact
        let themeChanged = currentTheme.map { type(of: $0) != type(of: theme) } ?? true

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

    func showFull(title: String, body: String, theme: Theme, animated: Bool = true, suppressShadow: Bool = false) {
        let wasVisible = alphaValue > 0.01
        let wasCompact = isCompact

        applyTheme(theme)
        if suppressShadow {
            layer?.shadowOpacity = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdropLayer.contents = nil
            CATransaction.commit()
        }
        titleLabel.stringValue = title
        titleLabel.alignment = .left
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
                self?.resetBlurFilter()
                self?.bodyContainer.isHidden = true
                self?.bodyContainer.alphaValue = 0
            })
        } else {
            alphaValue = 0
            bodyContainer.isHidden = true
            bodyContainer.alphaValue = 0
        }
    }

    func updateBackdrop(with particlesImage: CGImage, particleFrame: CGRect) {
        let targetFrame = self.frame
        let intersection = targetFrame.intersection(particleFrame)
        guard intersection.width > 0 && intersection.height > 0 else { return }

        let scale = CGFloat(particlesImage.width) / particleFrame.width
        let cropRect = CGRect(
            x: (intersection.minX - particleFrame.minX) * scale,
            y: (intersection.minY - particleFrame.minY) * scale,
            width: intersection.width * scale,
            height: intersection.height * scale
        )

        let ciImage = CIImage(cgImage: particlesImage).cropped(to: cropRect)
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(8.0 * scale, forKey: kCIInputRadiusKey)

        guard let blurredCI = blurFilter.outputImage else { return }

        let boostFilter = CIFilter(name: "CIColorControls")!
        boostFilter.setValue(blurredCI, forKey: kCIInputImageKey)
        boostFilter.setValue(1.1, forKey: kCIInputSaturationKey)
        boostFilter.setValue(1.1, forKey: kCIInputContrastKey)
        boostFilter.setValue(0.02, forKey: kCIInputBrightnessKey)

        guard let output = boostFilter.outputImage else { return }
        let finalCI = output.cropped(to: cropRect)

        if let blurredImage = ciContext.createCGImage(finalCI, from: cropRect) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdropLayer.contents = blurredImage
            let backdropOriginX = intersection.minX - targetFrame.minX
            let backdropOriginY = intersection.minY - targetFrame.minY
            backdropLayer.frame = CGRect(
                x: backdropOriginX, y: backdropOriginY,
                width: intersection.width, height: intersection.height
            )
            CATransaction.commit()
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

            // Update layout at peak blur (content change is invisible)
            self.applyLayout(width: width, height: height, animated: true, duration: self.transitionUnblurDuration)

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
        layer?.shadowColor = theme.primaryShadowColor
        layer?.shadowOpacity = 0.2
    }

    private func applyLayout(width: CGFloat, height: CGFloat, animated: Bool, duration: CFTimeInterval = 0.4) {
        guard let superview = superview else { return }

        let x = (superview.bounds.width - width) / 2
        let targetFrame = NSRect(x: x, y: bottomOffset, width: width, height: height)
        let targetBounds = NSRect(x: 0, y: 0, width: width, height: height)

        let inset = targetBounds.insetBy(dx: 0.5, dy: 0.5)
        let crPath = CGPath(roundedRect: inset, cornerWidth: cr, cornerHeight: cr, transform: nil)

        if animated && alphaValue > 0.01 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = springTiming
                animator().frame = targetFrame
                backgroundBlurView.animator().frame = targetBounds
                glassContainerView.animator().frame = targetBounds
            }
            // Animate CALayer frames in sync
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(springTiming)
            applyInternalLayerFrames(targetBounds, borderPath: crPath)
            CATransaction.commit()
        } else {
            frame = targetFrame
            backgroundBlurView.frame = targetBounds
            glassContainerView.frame = targetBounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyInternalLayerFrames(targetBounds, borderPath: crPath)
            CATransaction.commit()
        }

        layoutLabels(targetBounds: targetBounds, animated: animated, duration: duration)
    }

    /// Set all internal CALayer frames — called inside a CATransaction.
    private func applyInternalLayerFrames(_ bounds: NSRect, borderPath: CGPath) {
        solidFillLayer.frame = bounds
        gradientFillLayer.frame = bounds
        specularLayer.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        borderGradientLayer.frame = bounds
        borderMaskLayer.path = borderPath
        borderMaskLayer.frame = bounds
    }

    private func layoutLabels(targetBounds: NSRect, animated: Bool, duration: CFTimeInterval = 0.4) {
        let contentWidth = targetBounds.width - pillPadH * 2
        let titleHeight = titleLabel.sizeThatFits(NSSize(width: contentWidth, height: .greatestFiniteMagnitude)).height

        if isCompact {
            cancelBodyScroll()
            let titleFrame = NSRect(
                x: pillPadH,
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
            let bodyVisibleHeight = min(bodyContentHeight, maxBodyHeight)
            let totalContent = titleHeight + textGap + bodyVisibleHeight
            let startY = (targetBounds.height - totalContent) / 2

            let containerFrame = NSRect(x: pillPadH, y: startY, width: contentWidth, height: bodyVisibleHeight)
            let titleFrame = NSRect(x: pillPadH, y: startY + bodyVisibleHeight + textGap, width: contentWidth, height: titleHeight)

            // Top-anchored: label's top edge lines up with container's top
            // edge. NSView origin is bottom-left, so the label's y is
            // (visible - content), which is ≤ 0 whenever we're overflowing.
            // We later animate this y upward toward 0 to reveal the rest.
            let initialLabelY = bodyVisibleHeight - bodyContentHeight

            // If the body text is the same one the scroll is currently
            // animating, preserve its current y so the user doesn't see
            // the text snap back to the top on every state transition.
            // Otherwise (new content / fresh entrance) start at top.
            let scrollContinues = bodyLabel.stringValue == scrolledBodyText && bodyScrollTimer != nil
            let preservedY = scrollContinues ? bodyLabel.frame.origin.y : initialLabelY
            let labelFrame = NSRect(x: 0, y: preservedY, width: contentWidth, height: bodyContentHeight)

            if bodyContainer.isHidden {
                bodyContainer.frame = containerFrame
                bodyLabel.frame = labelFrame
                bodyContainer.isHidden = false
            }

            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    ctx.timingFunction = springTiming
                    bodyContainer.animator().frame = containerFrame
                    bodyContainer.animator().alphaValue = 1
                    titleLabel.animator().frame = titleFrame
                }
                // Snap the label to its starting position inside the container
                // — animating the inner label's frame alongside the container
                // resize fights with the scroll animation we're about to start.
                bodyLabel.frame = labelFrame
            } else {
                bodyContainer.frame = containerFrame
                bodyContainer.alphaValue = 1
                bodyLabel.frame = labelFrame
                titleLabel.frame = titleFrame
            }

            // Trigger or cancel the teleprompter scroll based on overflow.
            // If scrollContinues, the existing timer is still running for the
            // same text — leave it alone.
            if bodyContentHeight > maxBodyHeight {
                if !scrollContinues {
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

        DispatchQueue.main.asyncAfter(deadline: .now() + pauseSeconds) { [weak self] in
            guard let self else { return }
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
        bodyScrollTimer?.invalidate()
        bodyScrollTimer = nil
        scrolledBodyText = nil
    }

    // MARK: - Show helper (for theme comparison)

    private func themeMatches(_ theme: Theme) -> Bool {
        guard let current = currentTheme else { return false }
        switch (current, theme) {
        case (.stt, .stt), (.tts, .tts): return true
        default: return false
        }
    }
}
