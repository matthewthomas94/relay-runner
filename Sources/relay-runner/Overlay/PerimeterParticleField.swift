import AppKit
import QuartzCore

/// Perimeter-masked sibling of `ParticleFieldRenderer`. Reuses the same
/// halftone-dot grid + sin-wave animation + per-dot color pipeline, but the
/// visibility mask favors dots near the screen edges instead of along the
/// bottom — so the field paints the perimeter rather than the bottom band.
///
/// One instance per connected screen, owned by `PerimeterOverlayManager` and
/// hosted inside a screen-saver-level NSPanel.
///
/// Pulsing: animates the host layer opacity between two values when
/// `setActive(true, pulsing: true)` — used while a `propose_action`
/// confirmation is pending.
final class PerimeterParticleField {

    // Reuse ParticleFieldRenderer.Theme so the colors are guaranteed identical
    // to the existing reply state — no risk of drift when the theme is tuned.
    private let theme: ParticleFieldRenderer.Theme

    /// Fraction of the smaller screen dimension the visible band spans.
    /// At 0.55, the four edge falloffs overlap inside the middle ~10% — every
    /// dot on screen has some opacity, with a clear edge bias. Tunable via
    /// init for testing tighter / wider bands.
    private let thicknessFraction: CGFloat

    /// Falloff exponent. Lower = softer (dots stay visible deeper inward),
    /// higher = sharper edge band. 0.9 reads as "wide perimeter glow" —
    /// matches the design reference where dots span most of the screen.
    private let falloffExponent: CGFloat

    /// Computed during layout from `thicknessFraction × min(width, height)`.
    private var thickness: CGFloat = 100

    private let particleLayer = CALayer()

    private var animationTimer: Timer?
    private var startTime: CFTimeInterval = 0

    private var bitmapContext: CGContext?
    private var screenSize: CGSize = .zero
    private var screenScale: CGFloat = 2.0

    private var active = false
    private var pulsing = false

    // Same dot model as ParticleFieldRenderer — kept private so this file
    // stays self-contained. Adds precomputed radial distances from two
    // "wave centers" so the renderFrame hot loop doesn't repeat sqrt 80k
    // times per tick. Two centers means two overlapping radial ripples,
    // which destroys the linear-stripe character a single planar sin
    // produces and matches the soft cloud-like motion in the design ref.
    private struct Dot {
        let x: CGFloat, y: CGFloat
        let baseRadius: CGFloat
        let baseAlpha: CGFloat
        let r: CGFloat, g: CGFloat, b: CGFloat
        let distFromCenter: CGFloat       // ripple from screen center
        let distFromOffsetCenter: CGFloat // ripple from off-axis point
    }
    private var dots: [Dot] = []

    private let spacing: CGFloat = 8
    private let maxDotRadius: CGFloat = 3.0
    private let minDotRadius: CGFloat = 0.3

    init(theme: ParticleFieldRenderer.Theme = .tts,
         thicknessFraction: CGFloat = 0.55,
         falloffExponent: CGFloat = 0.9) {
        self.theme = theme
        self.thicknessFraction = thicknessFraction
        self.falloffExponent = falloffExponent
        particleLayer.opacity = 0
        // Suppress implicit fade so our explicit animations control opacity transitions.
        particleLayer.actions = ["opacity": NSNull(), "contents": NSNull()]
    }

    deinit {
        animationTimer?.invalidate()
    }

    // MARK: - Public

    func attach(to hostView: NSView) {
        if let layer = hostView.layer {
            layer.addSublayer(particleLayer)
        }
        layoutInBounds(hostView.bounds)
    }

    func layoutInBounds(_ bounds: CGRect) {
        particleLayer.frame = bounds
        if bounds.size != screenSize {
            screenSize = bounds.size
            // Use the host screen's backing scale, not NSScreen.main — the
            // perimeter spans every connected screen and they may differ.
            screenScale = particleLayer.contentsScale > 0 ? particleLayer.contentsScale : 2.0
            // Recompute thickness for this screen — at 0.55 of the shorter
            // edge, a 1080p display gets ~600pt of falloff, a 27" 5K gets
            // ~830pt. The four edges' falloffs overlap inside the middle so
            // every dot on screen has some opacity.
            thickness = min(bounds.width, bounds.height) * thicknessFraction
            rebuildContext()
            dots = buildDotGrid(size: bounds.size)
        }
    }

    /// Override the backing scale (call before attach so layer/bitmap are sized
    /// correctly for the host screen, which may differ from the main display).
    func setBackingScale(_ scale: CGFloat) {
        screenScale = max(1.0, scale)
        particleLayer.contentsScale = screenScale
    }

    /// Show or hide the perimeter. When `pulsing` is true, the layer opacity
    /// oscillates to draw attention to the pending confirmation. When false,
    /// it sits at a calmer steady opacity.
    func setActive(_ active: Bool, pulsing: Bool) {
        let didChange = (self.active != active) || (self.pulsing != pulsing)
        self.active = active
        self.pulsing = pulsing
        guard didChange else { return }

        if active {
            startAnimationIfNeeded()
        } else {
            stopAnimation()
        }

        applyOpacity()
    }

    // MARK: - Opacity / pulse

    private func applyOpacity() {
        particleLayer.removeAnimation(forKey: "pulse")

        guard active else {
            // Smooth fade out over 0.18s — matches PerimeterPanel's crossfade.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = particleLayer.presentation()?.opacity ?? particleLayer.opacity
            fade.toValue = 0.0
            fade.duration = 0.18
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            particleLayer.opacity = 0.0
            particleLayer.add(fade, forKey: "fadeOut")
            return
        }

        particleLayer.removeAnimation(forKey: "fadeOut")

        if pulsing {
            // Pull eyes — oscillate between an attention-getting bright opacity
            // and a calmer level. ~0.7s per half-cycle reads as "I want a
            // response" without being annoying.
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.55
            pulse.toValue = 1.0
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            particleLayer.opacity = 0.78          // mid-point — settles here on stop
            particleLayer.add(pulse, forKey: "pulse")
        } else {
            // Steady "computer vision active, no decision needed" state.
            // Fade in if we were hidden.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = particleLayer.presentation()?.opacity ?? particleLayer.opacity
            fade.toValue = 0.75
            fade.duration = 0.25
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            particleLayer.opacity = 0.75
            particleLayer.add(fade, forKey: "fadeIn")
        }
    }

    // MARK: - Animation loop

    private func startAnimationIfNeeded() {
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
        guard let ctx = bitmapContext else { return }
        let size = screenSize
        guard size.width > 0, size.height > 0, !dots.isEmpty else { return }

        let elapsed = CACurrentMediaTime() - startTime
        let scale = screenScale

        ctx.clear(CGRect(x: 0, y: 0, width: Int(size.width * scale), height: Int(size.height * scale)))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)

        // Slow global breathing — same value applied to every dot's radius
        // and alpha, so the whole field feels like one organism inhaling /
        // exhaling instead of a flat texture. ~10s cycle is slow enough to
        // be subliminal but visible if you're looking for it.
        let breath = 0.92 + 0.12 * CGFloat(sin(elapsed * 0.6))

        // Wave design — diverges from ParticleFieldRenderer.renderFrame on
        // purpose. The bottom field is a thin horizontal strip where short-
        // wavelength planar waves read fine. The perimeter field covers most
        // of the screen, so high-frequency planar waves stack into visible
        // diagonal bars. Two changes break that:
        //   1. Spatial frequencies dropped ~3x so each wave's wavelength
        //      exceeds screen width — single waves become slow gradients
        //      rather than tight stripes.
        //   2. Two radial ripples replace the vertical-only third wave —
        //      circular ripples never read as linear bars, and offsetting
        //      one center off-axis stops the ripples from looking
        //      symmetrically pulse-from-center.
        for dot in dots {
            // Soft diagonal swell — wavelength ~1500pt
            let wave1 = sin(
                Double(dot.x) * 0.0042
                - Double(dot.y) * 0.0028
                - elapsed * 2.8
            )
            // Counter-diagonal at a different angle and slower phase
            let wave2 = sin(
                Double(dot.x) * 0.0028
                + Double(dot.y) * 0.0048
                - elapsed * 1.9
            ) * 0.7
            // Radial ripple from screen center
            let wave3 = sin(
                Double(dot.distFromCenter) * 0.0095
                - elapsed * 1.4
            ) * 0.55
            // Radial ripple from an off-axis center, drifting opposite phase —
            // interference between the two radial waves creates moving
            // "blob" patterns instead of concentric circles.
            let wave4 = sin(
                Double(dot.distFromOffsetCenter) * 0.0072
                + elapsed * 0.95
            ) * 0.45

            let wave = CGFloat(wave1 + wave2 + wave3 + wave4) / 2.7
            let radiusScale: CGFloat = 1.0 + wave * 0.35
            let radius = dot.baseRadius * radiusScale * breath
            guard radius > 0.1 else { continue }

            let alpha = dot.baseAlpha * (1.0 + wave * 0.28) * breath
            guard alpha > 0.02 else { continue }

            ctx.setFillColor(red: dot.r, green: dot.g, blue: dot.b, alpha: alpha)
            ctx.fillEllipse(in: CGRect(
                x: dot.x - radius, y: dot.y - radius,
                width: radius * 2, height: radius * 2))
        }

        ctx.restoreGState()
        particleLayer.contents = ctx.makeImage()
    }

    // MARK: - Dot grid generation (perimeter mask)

    private func buildDotGrid(size: CGSize) -> [Dot] {
        let cols = Int(size.width / spacing) + 1
        let rows = Int(size.height / spacing) + 1

        var result: [Dot] = []
        result.reserveCapacity(cols * rows / 4)

        // Two wave centers for radial ripples. The primary sits at the screen
        // center; the offset sits in the upper-left quadrant so the two
        // ripple patterns interfere asymmetrically rather than producing
        // symmetric moiré. Both are precomputed per-dot so renderFrame's
        // hot loop avoids per-frame sqrt.
        let centerX = size.width / 2
        let centerY = size.height / 2
        let offsetX = size.width * 0.32
        let offsetY = size.height * 0.68

        // Deterministic pseudo-random for color variation — same constants as
        // ParticleFieldRenderer.buildDotGrid so colors come from the same
        // distribution.
        var seed: UInt64 = 12345

        for row in 0..<rows {
            for col in 0..<cols {
                let x = CGFloat(col) * spacing + spacing / 2
                let y = CGFloat(row) * spacing + spacing / 2

                // Perimeter mask. distFromEdge is the L∞ distance to the
                // nearest screen edge — small near edges, large in the center.
                // The falloff curve uses `falloffExponent` (default 0.9 for
                // a soft, wide band) so dots stay readable well into the
                // screen rather than vanishing right after the edge.
                let distLeft = x
                let distRight = size.width - x
                let distBottom = y
                let distTop = size.height - y
                let distFromEdge = min(distLeft, distRight, distBottom, distTop)

                guard distFromEdge < thickness else { continue }
                let t = distFromEdge / thickness                  // 0 at edge, 1 at inner cutoff
                let edgeFactor = pow(1.0 - t, falloffExponent)
                guard edgeFactor > 0.015 else { continue }        // tighter cutoff: keep faint center dots

                let dotRadius = minDotRadius + (maxDotRadius - minDotRadius) * edgeFactor
                let dotAlpha = 0.2 + 0.6 * edgeFactor

                // Per-dot color variation — same hue/sat/bri jitter recipe as
                // ParticleFieldRenderer so the perimeter palette matches the
                // bottom-of-screen reply field exactly.
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let r1 = CGFloat(seed >> 33) / CGFloat(UInt32.max)
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let r2 = CGFloat(seed >> 33) / CGFloat(UInt32.max)
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let r3 = CGFloat(seed >> 33) / CGFloat(UInt32.max)

                let hue = theme.baseHue + (r1 - 0.5) * 0.08
                let sat = max(0.1, min(1.0, theme.baseSaturation + (r2 - 0.5) * 0.2))
                let bri = max(0.4, min(1.0, 0.7 + (r3 - 0.5) * 0.3))

                let c = NSColor(hue: hue, saturation: sat, brightness: bri, alpha: 1.0)
                var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
                c.usingColorSpace(.sRGB)?.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)

                // Lift dots at the very edge toward the theme highlight — same
                // device the bottom field uses to pop the leading edge.
                let liftWeight = pow(edgeFactor, 3.0) * 0.70
                let h = theme.baseHighlight
                let fr = cr * (1 - liftWeight) + h.r * liftWeight
                let fg = cg * (1 - liftWeight) + h.g * liftWeight
                let fb = cb * (1 - liftWeight) + h.b * liftWeight

                let dxC = x - centerX, dyC = y - centerY
                let dxO = x - offsetX, dyO = y - offsetY
                let distFromCenter = sqrt(dxC * dxC + dyC * dyC)
                let distFromOffsetCenter = sqrt(dxO * dxO + dyO * dyO)

                result.append(Dot(
                    x: x, y: y,
                    baseRadius: dotRadius, baseAlpha: dotAlpha,
                    r: fr, g: fg, b: fb,
                    distFromCenter: distFromCenter,
                    distFromOffsetCenter: distFromOffsetCenter))
            }
        }

        return result
    }

    // MARK: - Context

    private func rebuildContext() {
        let w = Int(screenSize.width * screenScale)
        let h = Int(screenSize.height * screenScale)
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
}
