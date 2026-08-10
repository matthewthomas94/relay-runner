import AppKit
import QuartzCore

/// Renders an animated halftone dot particle field.
/// Dots are arranged in a grid with size varying across the presentation area.
/// A slow diagonal wave adds subtle organic movement.
final class ParticleFieldRenderer {

    enum Theme: Hashable {
        case stt    // yellow/amber
        case tts    // blue/purple
        case workspace  // modal backdrop navy

        var baseHue: CGFloat {
            switch self {
            case .stt: return 0.04    // deeper blood orange
            case .tts: return 0.68    // blue-purple
            case .workspace: return 0
            }
        }

        var baseSaturation: CGFloat {
            switch self {
            case .stt: return 0.95
            case .tts: return 0.80
            case .workspace: return 0
            }
        }

        /// Fraction of screen height the field covers.
        var fieldFraction: CGFloat {
            switch self {
            case .stt: return 0.32
            case .tts: return 0.44
            case .workspace: return 1
            }
        }

        /// RGB tint blended into dots at the base of the field. Sampled from
        /// the Figma mocks — STT base dots are nearly white (faintest warm
        /// tint), TTS base dots are #FDEADB cream.
        var baseHighlight: (r: CGFloat, g: CGFloat, b: CGFloat) {
            switch self {
            case .stt: return (1.000, 0.965, 0.900)
            case .tts: return (0.992, 0.918, 0.859)
            case .workspace: return (10.0 / 255.0, 15.0 / 255.0, 25.0 / 255.0)
            }
        }
    }

    enum Coverage {
        case lowerScreen
        case fullBounds

        var boundsFraction: CGFloat {
            switch self {
            case .lowerScreen: return 0.44
            case .fullBounds: return 1
            }
        }
    }

    private let gradientLayer = CAGradientLayer()
    private let particleLayer = CALayer()

    private var currentTheme: Theme?
    private var intensityMultiplier: Double = 0.6
    private var reduceMotion = false

    private var animationTimer: Timer?
    private var startTime: CFTimeInterval = 0

    private var bitmapContext: CGContext?
    private var latestParticleImage: CGImage?
    private var fieldSize: CGSize = .zero
    private var screenSize: CGSize = .zero
    private var screenScale: CGFloat = 2.0

    // Pre-computed dot grid (position + base radius + color components)
    private struct Dot {
        let x: CGFloat, y: CGFloat
        let baseRadius: CGFloat
        let baseAlpha: CGFloat
        let r: CGFloat, g: CGFloat, b: CGFloat
    }
    private var dots: [Theme: [Dot]] = [:]

    private let spacing: CGFloat = 8
    private let maxDotRadius: CGFloat = 3.0
    private let minDotRadius: CGFloat = 0.3
    private let coverage: Coverage

    init(coverage: Coverage = .lowerScreen) {
        self.coverage = coverage
        // Dark gradient behind particles: transparent at top, dark at bottom
        gradientLayer.colors = [
            NSColor(white: 0, alpha: 0).cgColor,
            NSColor(white: 0, alpha: 0.75).cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)  // top in AppKit coords
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)    // bottom
        gradientLayer.opacity = 0
        gradientLayer.actions = ["opacity": NSNull()]

        particleLayer.opacity = 0
        particleLayer.actions = ["opacity": NSNull()]
    }

    deinit {
        animationTimer?.invalidate()
    }

    // MARK: - Public

    func attach(to hostView: NSView) {
        if let layer = hostView.layer {
            layer.addSublayer(gradientLayer)
            layer.addSublayer(particleLayer)
        }
        layoutInBounds(hostView.bounds)
    }

    func layoutInBounds(_ bounds: CGRect, backingScale: CGFloat? = nil) {
        let fieldH = bounds.height * coverage.boundsFraction
        gradientLayer.frame = bounds
        particleLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: fieldH)

        let resolvedScale = backingScale ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if bounds.size != screenSize || resolvedScale != screenScale {
            screenSize = bounds.size
            fieldSize = CGSize(width: bounds.width, height: fieldH)
            screenScale = resolvedScale
            rebuildContext()
            dots.removeAll()
            if currentTheme != nil, reduceMotion {
                renderFrame()
            }
        }
    }

    func setIntensity(_ value: Double) {
        intensityMultiplier = max(0, min(1, value))
        if currentTheme != nil {
            particleLayer.opacity = Float(intensityMultiplier)
            gradientLayer.opacity = Float(intensityMultiplier)
        }
    }

    func transition(to theme: Theme?, reduceMotion: Bool = false) {
        let resolvedReduceMotion = reduceMotion || theme == .workspace
        guard theme != currentTheme || resolvedReduceMotion != self.reduceMotion else { return }
        let wasHidden = currentTheme == nil
        currentTheme = theme
        self.reduceMotion = resolvedReduceMotion

        guard theme != nil else {
            stopAnimation()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            particleLayer.opacity = 0
            gradientLayer.opacity = 0
            CATransaction.commit()
            return
        }

        if resolvedReduceMotion {
            stopAnimation()
            renderFrame()
        } else {
            startAnimation()
        }

        if wasHidden {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            particleLayer.opacity = Float(intensityMultiplier)
            gradientLayer.opacity = Float(intensityMultiplier)
            CATransaction.commit()
        }
    }

    // MARK: - Animation loop

    private func startAnimation() {
        guard animationTimer == nil else { return }
        startTime = CACurrentMediaTime()
        renderFrame()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.renderFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func renderFrame() {
        guard let theme = currentTheme, let ctx = bitmapContext else { return }
        let size = fieldSize
        guard size.width > 0, size.height > 0 else { return }

        let elapsed = reduceMotion ? 0 : CACurrentMediaTime() - startTime
        let scale = screenScale

        // Ensure dots are pre-computed for this theme
        if dots[theme] == nil {
            dots[theme] = buildDotGrid(theme: theme, size: size)
        }
        guard let grid = dots[theme] else { return }

        // Clear
        ctx.clear(CGRect(x: 0, y: 0, width: Int(size.width * scale), height: Int(size.height * scale)))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)

        // Draw each dot with wave-modulated radius
        for dot in grid {
            // Primary diagonal wave
            let wave1 = sin(
                Double(dot.x) * 0.012
                - Double(dot.y) * 0.008
                - elapsed * 4.2
            )
            // Secondary wave at different angle and speed for variation
            let wave2 = sin(
                Double(dot.x) * 0.007
                + Double(dot.y) * 0.011
                - elapsed * 2.7
            ) * 0.4
            // Slow broad undulation
            let wave3 = sin(
                Double(dot.x) * 0.004
                - elapsed * 1.1
            ) * 0.3

            let wave = CGFloat(wave1 + wave2 + wave3) / 1.7  // normalize
            let radiusScale: CGFloat = 1.0 + wave * 0.2
            let radius = dot.baseRadius * radiusScale
            guard radius > 0.1 else { continue }

            // Preserve the exact design color for the static workspace matrix.
            let alpha = theme == .workspace
                ? dot.baseAlpha
                : dot.baseAlpha * (1.0 + wave * 0.1)
            guard alpha > 0.02 else { continue }

            ctx.setFillColor(red: dot.r, green: dot.g, blue: dot.b, alpha: alpha)
            ctx.fillEllipse(in: CGRect(
                x: dot.x - radius, y: dot.y - radius,
                width: radius * 2, height: radius * 2))
        }

        ctx.restoreGState()
        let image = ctx.makeImage()
        latestParticleImage = image
        particleLayer.contents = image
    }

    // MARK: - Dot grid generation

    private func buildDotGrid(theme: Theme, size: CGSize) -> [Dot] {
        let fieldHeight = min(
            size.height,
            size.height * (theme.fieldFraction / coverage.boundsFraction)
        )
        let cols = Int(size.width / spacing) + 1
        let rows = Int(fieldHeight / spacing) + 1

        let centerX = size.width / 2
        let sigma = size.width * 0.45
        let workspaceCenterY = fieldHeight / 2
        let workspaceSigmaX = max(1, size.width * 0.30)
        let workspaceSigmaY = max(1, fieldHeight * 0.30)

        var result: [Dot] = []
        result.reserveCapacity(cols * rows)

        // Deterministic pseudo-random for color variation
        var seed: UInt64 = 12345

        for row in 0..<rows {
            for col in 0..<cols {
                let x = CGFloat(col) * spacing + spacing / 2
                let y = CGFloat(row) * spacing + spacing / 2

                let verticalT = CGFloat(row) / CGFloat(max(1, rows - 1))
                let combined: CGFloat
                if theme == .workspace {
                    let dx = x - centerX
                    let dy = y - workspaceCenterY
                    let horizontalFactor = exp(
                        -(dx * dx) / (2 * workspaceSigmaX * workspaceSigmaX)
                    )
                    let verticalFactor = exp(
                        -(dy * dy) / (2 * workspaceSigmaY * workspaceSigmaY)
                    )
                    combined = horizontalFactor * verticalFactor
                } else {
                    let verticalFactor = pow(1.0 - verticalT, 1.6)
                    let dx = x - centerX
                    let horizontalFactor = exp(-(dx * dx) / (2 * sigma * sigma))
                    combined = verticalFactor * horizontalFactor
                }
                guard combined > 0.02 else { continue }

                let dotRadius = minDotRadius + (maxDotRadius - minDotRadius) * combined
                let dotAlpha = theme == .workspace ? 1.0 : 0.2 + 0.6 * combined

                // Per-dot color variation
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let r1 = CGFloat(seed >> 33) / CGFloat(UInt32.max)
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let r2 = CGFloat(seed >> 33) / CGFloat(UInt32.max)
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let r3 = CGFloat(seed >> 33) / CGFloat(UInt32.max)

                var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
                if theme == .workspace {
                    let color = theme.baseHighlight
                    cr = color.r
                    cg = color.g
                    cb = color.b
                } else {
                    let hue = theme.baseHue + (r1 - 0.5) * 0.08
                    let sat = max(0.1, min(1.0, theme.baseSaturation + (r2 - 0.5) * 0.2))
                    let bri = max(0.4, min(1.0, 0.7 + (r3 - 0.5) * 0.3))

                    // Convert HSB to RGB
                    let c = NSColor(hue: hue, saturation: sat, brightness: bri, alpha: 1.0)
                    c.usingColorSpace(.sRGB)?.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
                }

                // Lift toward the theme highlight at the base of the field.
                // row 0 sits at the visible bottom (CG bitmap origin), so low
                // verticalT receives the most lift. Steep curve keeps the
                // mid-field theme-saturated while the bottom strip pushes
                // hard toward the highlight — giving vertical contrast.
                let liftWeight = pow(1.0 - verticalT, 3.0) * 0.70
                let h = theme.baseHighlight
                let fr = cr * (1 - liftWeight) + h.r * liftWeight
                let fg = cg * (1 - liftWeight) + h.g * liftWeight
                let fb = cb * (1 - liftWeight) + h.b * liftWeight

                result.append(Dot(
                    x: x, y: y,
                    baseRadius: dotRadius, baseAlpha: dotAlpha,
                    r: fr, g: fg, b: fb))
            }
        }

        return result
    }

    // MARK: - Context management

    private func rebuildContext() {
        latestParticleImage = nil
        let w = Int(fieldSize.width * screenScale)
        let h = Int(fieldSize.height * screenScale)
        guard w > 0, h > 0 else {
            bitmapContext = nil
            return
        }
        bitmapContext = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    var isAnimationRunning: Bool {
        animationTimer != nil
    }

    var renderedParticleFrame: CGRect {
        particleLayer.frame
    }

    var renderedGradientFrame: CGRect {
        gradientLayer.frame
    }

    var renderedParticleImage: CGImage? {
        latestParticleImage
    }
}
