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

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let blurFilter = CIFilter(name: "CIGaussianBlur")!

    private let maxWidth: CGFloat = 460
    private let pillPadH: CGFloat = 24
    private let pillPadV: CGFloat = 18
    private let textGap: CGFloat = 12
    private let cr: CGFloat = 16
    private let bottomOffset: CGFloat = 56

    private let textColor = NSColor(red: 226 / 255, green: 232 / 255, blue: 240 / 255, alpha: 1)

    private var isCompact = true
    private var isTransitioning = false
    private var currentTheme: Theme?

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

        // Body label
        bodyLabel.font = .systemFont(ofSize: 14, weight: .regular)
        bodyLabel.textColor = textColor
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.alignment = .left
        bodyLabel.cell?.truncatesLastVisibleLine = true
        bodyLabel.isHidden = true
        bodyLabel.alphaValue = 0
        addSubview(bodyLabel)
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
        }
        titleLabel.stringValue = title
        titleLabel.alignment = .left
        bodyLabel.stringValue = body
        isCompact = false

        let contentWidth = maxWidth - pillPadH * 2
        let titleSize = titleLabel.sizeThatFits(NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let bodySize = bodyLabel.sizeThatFits(NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let pillHeight = pillPadV + titleSize.height + textGap + bodySize.height + pillPadV

        if wasVisible && animated && wasCompact {
            // Compact → Full transition: blur out → update → blur in
            transitionContent(width: maxWidth, height: pillHeight)
        } else if wasVisible {
            // Same-state content update: smooth resize
            applyLayout(width: maxWidth, height: pillHeight, animated: animated)
            if bodyLabel.isHidden {
                bodyLabel.frame = bodyLabel.frame
                bodyLabel.isHidden = false
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bodyLabel.animator().alphaValue = 1
            }
        } else {
            // Fresh entrance
            bodyLabel.isHidden = false
            bodyLabel.alphaValue = 1
            applyLayout(width: maxWidth, height: pillHeight, animated: false)
            slideIn(animated: animated)
        }
    }

    func hide(animated: Bool = true) {
        guard alphaValue > 0.01 else { return }


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
                self?.bodyLabel.isHidden = true
                self?.bodyLabel.alphaValue = 0
            })
        } else {
            alphaValue = 0
            bodyLabel.isHidden = true
            bodyLabel.alphaValue = 0
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
                if self.bodyLabel.isHidden {
                    self.bodyLabel.isHidden = false
                }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = self.transitionUnblurDuration
                    self.bodyLabel.animator().alphaValue = 1
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
                    bodyLabel.animator().alphaValue = 0
                }
            } else {
                titleLabel.frame = titleFrame
                bodyLabel.alphaValue = 0
                bodyLabel.isHidden = true
            }
        } else {
            let bodyHeight = bodyLabel.sizeThatFits(NSSize(width: contentWidth, height: .greatestFiniteMagnitude)).height
            let totalContent = titleHeight + textGap + bodyHeight
            let startY = (targetBounds.height - totalContent) / 2

            let bodyFrame = NSRect(x: pillPadH, y: startY, width: contentWidth, height: bodyHeight)
            let titleFrame = NSRect(x: pillPadH, y: startY + bodyHeight + textGap, width: contentWidth, height: titleHeight)

            if bodyLabel.isHidden {
                bodyLabel.frame = bodyFrame
                bodyLabel.isHidden = false
            }

            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    ctx.timingFunction = springTiming
                    bodyLabel.animator().frame = bodyFrame
                    bodyLabel.animator().alphaValue = 1
                    titleLabel.animator().frame = titleFrame
                }
            } else {
                bodyLabel.frame = bodyFrame
                bodyLabel.alphaValue = 1
                titleLabel.frame = titleFrame
            }
        }
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
