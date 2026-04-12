import AppKit
import CoreImage

/// Bottom-center pill showing state info, live transcription, or message preview.
/// Liquid glass style: within-window blur refracts particles, specular border, themed glow shadow.
/// Two modes: compact (single title) and full (title + body text).
/// Two themes: STT (blood orange glow) and TTS (purple glow).
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

    // Callback when pill frame updates so particle mask can hole-punch it
    var onFrameChanged: ((CGRect) -> Void)?

    private let secondaryShadowLayer = CALayer()
    
    private let backgroundBlurView = NSVisualEffectView()
    private let glassContainerView = NSView()
    
    // Glass blur properties as per Figma specification
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

    private let maxWidth: CGFloat = 380
    private let pillPadH: CGFloat = 24
    private let pillPadV: CGFloat = 16
    private let textGap: CGFloat = 12
    private let cr: CGFloat = 16

    private let textColor = NSColor(red: 226 / 255, green: 232 / 255, blue: 240 / 255, alpha: 1)

    private var isCompact = true

    override init(frame: NSRect) {
        titleLabel = NSTextField(labelWithString: "")
        bodyLabel = NSTextField(labelWithString: "")

        super.init(frame: frame)

        wantsLayer = true
        alphaValue = 0

        // Secondary shadow (smaller, lighter glow)
        secondaryShadowLayer.shadowOffset = CGSize(width: 0, height: -8)
        secondaryShadowLayer.shadowRadius = 12
        secondaryShadowLayer.shadowOpacity = 0.1
        secondaryShadowLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(secondaryShadowLayer)

        // Primary shadow
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        layer?.shadowRadius = 24
        layer?.shadowOpacity = 0

        // Background blur for external apps behind the overlay window
        backgroundBlurView.blendingMode = .behindWindow
        backgroundBlurView.material = .underWindowBackground
        backgroundBlurView.appearance = NSAppearance(named: .darkAqua)
        backgroundBlurView.state = .active
        backgroundBlurView.wantsLayer = true
        backgroundBlurView.layer?.cornerRadius = cr
        backgroundBlurView.layer?.masksToBounds = true
        addSubview(backgroundBlurView)

        // Glass container setup (Custom particles and fills)
        glassContainerView.wantsLayer = true
        glassContainerView.layer?.cornerRadius = cr
        glassContainerView.layer?.masksToBounds = true
        addSubview(glassContainerView)
        
        // 1. Dark base to emulate local dark gradient drop-off + Figma 20% spec
        solidFillLayer.backgroundColor = NSColor(white: 0.0, alpha: 0.45).cgColor
        glassContainerView.layer?.addSublayer(solidFillLayer)

        // 2. The blurred background dots layered on top
        glassContainerView.layer?.addSublayer(backdropLayer)
        
        // 3. Precise Figma Spec: Linear Gradient 10% Opacity (Black to F8FAFC)
        gradientFillLayer.colors = [
            NSColor(white: 0.0, alpha: 0.10).cgColor,
            NSColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 0.10).cgColor
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

        // Glass border stroke (Gradient at bottom edge)
        borderMaskLayer.fillColor = nil
        borderMaskLayer.strokeColor = NSColor.white.cgColor // Mask works on alpha
        borderMaskLayer.lineWidth = 1.0

        borderGradientLayer.colors = [
            NSColor(white: 1, alpha: 0.0).cgColor,
            NSColor(white: 1, alpha: 0.0).cgColor,
            NSColor(white: 1, alpha: 0.1).cgColor
        ]
        borderGradientLayer.locations = [0.0, 0.1, 1]
        borderGradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        borderGradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        borderGradientLayer.mask = borderMaskLayer
        glassContainerView.layer?.addSublayer(borderGradientLayer)

        // Title (semibold, 12px)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = textColor
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .left
        addSubview(titleLabel)

        // Body (regular, 14px)
        bodyLabel.font = .systemFont(ofSize: 14, weight: .regular)
        bodyLabel.textColor = textColor
        bodyLabel.maximumNumberOfLines = 2
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.alignment = .left
        bodyLabel.cell?.truncatesLastVisibleLine = true
        bodyLabel.isHidden = true
        addSubview(bodyLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API

    func showCompact(title: String, theme: Theme, animated: Bool = true) {
        applyTheme(theme)
        titleLabel.stringValue = title
        bodyLabel.isHidden = true
        isCompact = true

        let titleSize = titleLabel.sizeThatFits(NSSize(width: maxWidth - pillPadH * 2, height: 20))
        let pillWidth = min(maxWidth, titleSize.width + pillPadH * 2)
        let pillHeight = titleSize.height + pillPadV * 2

        layoutPill(width: pillWidth, height: pillHeight, bottomOffset: 68, animated: animated)
        show(animated: animated)
    }

    func showFull(title: String, body: String, theme: Theme, animated: Bool = true) {
        applyTheme(theme)
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        bodyLabel.isHidden = false
        isCompact = false

        let contentWidth = maxWidth - pillPadH * 2
        let titleSize = titleLabel.sizeThatFits(NSSize(width: contentWidth, height: 20))
        let bodySize = bodyLabel.sizeThatFits(NSSize(width: contentWidth, height: 48))
        let pillHeight = pillPadV + titleSize.height + textGap + bodySize.height + pillPadV

        layoutPill(width: maxWidth, height: pillHeight, bottomOffset: 46, animated: animated)
        show(animated: animated)
    }

    func hide(animated: Bool = true) {
        guard alphaValue > 0 else { return }
        onFrameChanged?(.zero)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
                // Slide down below the screen edge
                var exitFrame = frame
                exitFrame.origin.y = -frame.height
                animator().frame = exitFrame
            }
        } else {
            alphaValue = 0
        }
    }

    func updateBackdrop(with particlesImage: CGImage, particleFrame: CGRect) {
        // Run independently of alpha so fade-in animation has rich backing data
        
        // Read model frame directly instead of relying on layer constraints
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
        
        // Emulate vibrant particle depth passing cleanly through glass
        let boostFilter = CIFilter(name: "CIColorControls")!
        boostFilter.setValue(blurredCI, forKey: kCIInputImageKey)
        boostFilter.setValue(1.6, forKey: kCIInputSaturationKey)
        boostFilter.setValue(1.3, forKey: kCIInputContrastKey)
        boostFilter.setValue(0.05, forKey: kCIInputBrightnessKey)
        
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

    // MARK: - Private

    private func applyTheme(_ theme: Theme) {
        layer?.shadowColor = theme.primaryShadowColor
        layer?.shadowOpacity = 0.25
        secondaryShadowLayer.shadowColor = theme.secondaryShadowColor
    }

    private func layoutPill(width: CGFloat, height: CGFloat, bottomOffset: CGFloat, animated: Bool) {
        guard let superview = superview else { return }

        let x = (superview.bounds.width - width) / 2
        let targetFrame = NSRect(x: x, y: bottomOffset, width: width, height: height)
        let targetBounds = NSRect(x: 0, y: 0, width: width, height: height)
        
        let inset = targetBounds.insetBy(dx: 0.5, dy: 0.5)
        let crPath = CGPath(roundedRect: inset, cornerWidth: cr, cornerHeight: cr, transform: nil)
        let boundsPath = CGPath(roundedRect: targetBounds, cornerWidth: cr, cornerHeight: cr, transform: nil)

        if animated && alphaValue > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                
                animator().frame = targetFrame
                
                backgroundBlurView.animator().frame = targetBounds
                glassContainerView.animator().frame = targetBounds
                
                solidFillLayer.frame = targetBounds
                gradientFillLayer.frame = targetBounds
                specularLayer.frame = CGRect(x: 0, y: targetBounds.height - 1, width: targetBounds.width, height: 1)
                
                borderGradientLayer.frame = targetBounds
                borderMaskLayer.path = crPath
                borderMaskLayer.frame = targetBounds
                
                secondaryShadowLayer.frame = targetBounds
                secondaryShadowLayer.shadowPath = boundsPath
                layer?.shadowPath = boundsPath
            }
        } else {
            frame = targetFrame
            
            backgroundBlurView.frame = targetBounds
            glassContainerView.frame = targetBounds
            
            solidFillLayer.frame = targetBounds
            gradientFillLayer.frame = targetBounds
            specularLayer.frame = CGRect(x: 0, y: targetBounds.height - 1, width: targetBounds.width, height: 1)
            
            borderGradientLayer.frame = targetBounds
            borderMaskLayer.path = crPath
            borderMaskLayer.frame = targetBounds
            
            secondaryShadowLayer.frame = targetBounds
            secondaryShadowLayer.shadowPath = boundsPath
            layer?.shadowPath = boundsPath
        }

        layoutLabels(targetBounds: targetBounds, animated: animated && alphaValue > 0)
        onFrameChanged?(targetFrame)
    }

    private func layoutLabels(targetBounds: NSRect, animated: Bool) {
        let contentWidth = targetBounds.width - pillPadH * 2
        let titleHeight = titleLabel.sizeThatFits(NSSize(width: contentWidth, height: 20)).height

        if bodyLabel.isHidden {
            let trPill = NSRect(x: pillPadH, y: (targetBounds.height - titleHeight) / 2, width: contentWidth, height: titleHeight)
            if animated { titleLabel.animator().frame = trPill } else { titleLabel.frame = trPill }
        } else {
            let bodyHeight = bodyLabel.sizeThatFits(NSSize(width: contentWidth, height: 48)).height
            let totalContent = titleHeight + textGap + bodyHeight
            let startY = (targetBounds.height - totalContent) / 2

            let trBody = NSRect(x: pillPadH, y: startY, width: contentWidth, height: bodyHeight)
            let trTitle = NSRect(x: pillPadH, y: startY + bodyHeight + textGap, width: contentWidth, height: titleHeight)
            
            if animated {
                bodyLabel.animator().frame = trBody
                titleLabel.animator().frame = trTitle
            } else {
                bodyLabel.frame = trBody
                titleLabel.frame = trTitle
            }
        }
    }

    private func show(animated: Bool) {
        let isHidden = alphaValue < 0.01
        if isHidden && animated {
            // Start below screen edge, then animate up
            let targetFrame = frame
            var startFrame = targetFrame
            startFrame.origin.y = -targetFrame.height
            frame = startFrame
            onFrameChanged?(targetFrame)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().frame = targetFrame
                animator().alphaValue = 1
            }
        } else if isHidden {
            alphaValue = 1
            onFrameChanged?(self.frame)
        }
    }
}
