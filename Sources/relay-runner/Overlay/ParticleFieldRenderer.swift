import AppKit
import CoreImage
import QuartzCore

/// Renders an animated particle field in one of two styles: overlay
/// particles for the screen overlays, or panel particles for Workspace panels.
final class ParticleFieldRenderer {

    /// The two particle looks. Overlay particles are used outside the
    /// Workspace; panel particles are used inside it.
    enum Style {
        /// Halftone dots, as in the TTS and STT screen overlays.
        case overlay
        /// Light glowing beneath a grid of tiles, as on the Settings agent
        /// card and the Workspace's skeleton loader panels.
        case panel
    }

    enum Theme: Hashable {
        case idle   // white orb
        case stt    // yellow/amber
        case tts    // blue/purple
        case workspace  // modal backdrop navy

        var baseHue: CGFloat {
            switch self {
            case .stt: return 0.04    // deeper blood orange
            case .tts: return 0.68    // blue-purple
            case .idle, .workspace: return 0
            }
        }

        var baseSaturation: CGFloat {
            switch self {
            case .stt: return 0.95
            case .tts: return 0.80
            case .idle, .workspace: return 0
            }
        }

        /// Fraction of screen height the field covers.
        var fieldFraction: CGFloat {
            switch self {
            case .stt: return 0.32
            case .tts: return 0.44
            case .idle, .workspace: return 1
            }
        }

        /// RGB tint blended into dots at the base of the field. Sampled from
        /// the Figma mocks — STT base dots are nearly white (faintest warm
        /// tint), TTS base dots are #FDEADB cream.
        var baseHighlight: (r: CGFloat, g: CGFloat, b: CGFloat) {
            switch self {
            case .idle: return (1, 1, 1)
            case .stt: return (1.000, 0.965, 0.900)
            case .tts: return (0.992, 0.918, 0.859)
            case .workspace: return (10.0 / 255.0, 15.0 / 255.0, 25.0 / 255.0)
            }
        }
    }

    enum Coverage {
        case lowerScreen
        case fullBounds
        case agentOrb

        var boundsFraction: CGFloat {
            switch self {
            case .lowerScreen: return 0.44
            case .fullBounds, .agentOrb: return 1
            }
        }
    }

    private let gradientLayer = CAGradientLayer()
    private let particleLayer = CALayer()
    private let motionBlur = CIFilter(name: "CIGaussianBlur")!

    /// Panel particles, an inverted halftone: the orb's light glows beneath
    /// a grid of dark tiles, round and standing apart where it is strongest
    /// and squaring off until they close away from it. The light is sampled
    /// at low resolution into `glowLight` and shown as the particle layer's
    /// contents; the tiles are drawn sharp into `tileLayer` above it.
    private let tileGrid: Bool
    private let tileLayer = CALayer()
    private var glowLight: CGContext?
    private static let glowSampleSpacing: CGFloat = 3
    private static let tilesAcross: CGFloat = 15
    /// Workspace loader panels keep one scale everywhere: the tiles and light
    /// of the agent card at its full width. The agent card itself scales them
    /// with its own width.
    static let panelTilePitch: CGFloat = 32
    private static let panelLightWidth: CGFloat = 480
    private let scalesWithWidth: Bool
    /// Keeps the light's path below the agent card's title and status.
    private static let tileGridTopReserve: CGFloat = 116
    private static let lightWanderPeriod: Double = 9
    /// The light moves at two-fifths of the dot orb's pace.
    private static let tileLightPace = 0.4
    /// How far apart the tiles stand at the light's core, as a share of a tile.
    private static let tileCoreGap: CGFloat = 0.05
    /// The panels panel particles show on, in field points with y up.
    /// Empty means the whole field is one panel, as on the agent card.
    private var panels: [CGRect] = []
    private var panelCornerRadius: CGFloat = 0
    /// The light's route over the panels: waypoints scattered across them,
    /// with the time it reaches each, in field points and seconds.
    private var route: [(point: CGPoint, time: Double)] = []
    private var routeRandom = RouteRandom(state: 0)
    /// The light sweeps along its route at about this many points a second.
    static let panelLightSpeed: CGFloat = 107
    /// On Workspace panels the light is this much larger than in the agent card.
    private static let panelLightGrowth = 1.33
    /// On Workspace panels the light's shape changes faster and further
    /// than on the agent card.
    private static let panelMorphPace = 1.0
    private static let panelMorphDepth = 1.8
    /// How far behind the leading lobe, in seconds along the route, each of
    /// the light's lobes follows, so it trails its motion like a liquid.
    private static let panelLobeLag: [Double] = [0, 0.36, 0.72]

    private var currentTheme: Theme?
    private var intensityMultiplier: Double = 0.6
    private var reduceMotion = false
    private var departure: CGFloat = 0
    private var blurRadius: CGFloat = 0

    private var animationTimer: Timer?
    private var startTime: CFTimeInterval = 0

    private var bitmapContext: CGContext?
    private var bitmapColorSpace = CGColorSpaceCreateDeviceRGB()
    private weak var hostView: NSView?
    private var latestParticleImage: CGImage?
    private var latestGlowImage: CGImage?
    private var fieldSize: CGSize = .zero
    private var screenSize: CGSize = .zero
    private var screenScale: CGFloat = 2.0

    /// Inputs of the last applied layer presentation.
    private struct PresentationInputs: Equatable {
        let fieldSize: CGSize
        let departure: CGFloat
        let blurRadius: CGFloat
        let intensity: Double
        let visible: Bool
        let reduceMotion: Bool
    }
    private var appliedPresentation: PresentationInputs?

    /// Antialiased dot coverage rendered once by CoreGraphics, keyed by the
    /// dot radius in 1/256 device pixels.
    private struct CoverageStamp {
        let size: Int
        let alpha: [UInt8]
    }
    private var coverageStamps: [Int: CoverageStamp] = [:]
    private static let stampSteps: CGFloat = 256
    /// Tests render the CoreGraphics reference the stamps must match.
    var drawsDotsWithCoreGraphics = false

    // Pre-computed dot grid (position + base radius + color components)
    private struct Dot {
        let x: CGFloat, y: CGFloat
        let baseRadius: CGFloat
        let baseAlpha: CGFloat
        let r: CGFloat, g: CGFloat, b: CGFloat
    }
    private var dots: [Theme: [Dot]] = [:]
    private var displayedOrbColor: SIMD3<Double>?
    private var previousOrbColor: SIMD3<Double>?
    private var orbColorStartedAt: CFTimeInterval = 0
    /// The agent card's light turns black, easing like a theme change.
    private var darkLight = false
    private var darknessFrom: Double = 0
    private var darknessStartedAt: CFTimeInterval = 0
    private var displayedDarkness: Double = 0
    /// Screen fields crossfade from the theme they were showing.
    private var previousTheme: Theme?
    private var themeChangedAt: CFTimeInterval = 0
    static let themeCrossfadeDuration: TimeInterval = 0.45 * RelayMotion.durationScale

    private let spacing: CGFloat = 8
    private let maxDotRadius: CGFloat = 3
    private let minDotRadius: CGFloat = 0.3
    private let coverage: Coverage

    init(coverage: Coverage = .lowerScreen, style: Style = .overlay, scalesWithWidth: Bool = false) {
        self.coverage = coverage
        self.tileGrid = style == .panel
        self.scalesWithWidth = scalesWithWidth || style == .overlay
        if self.tileGrid {
            tileLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            particleLayer.addSublayer(tileLayer)
        }
        // Dark gradient behind particles: transparent at top, dark at bottom
        gradientLayer.colors = [
            NSColor(white: 0, alpha: 0).cgColor,
            NSColor(white: 0, alpha: 0.75).cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)  // top in AppKit coords
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)    // bottom
        gradientLayer.opacity = 0
        gradientLayer.isHidden = coverage == .agentOrb || tileGrid
        gradientLayer.actions = ["opacity": NSNull()]

        particleLayer.opacity = 0
        particleLayer.actions = ["opacity": NSNull()]
        motionBlur.name = "motionBlur"
    }

    deinit {
        animationTimer?.invalidate()
    }

    // MARK: - Public

    func attach(to hostView: NSView) {
        self.hostView = hostView
        if let layer = hostView.layer {
            attach(to: layer)
        }
        layoutInBounds(hostView.bounds)
    }

    /// Draws into a plain layer, such as one panel inside a larger view.
    /// Call `layoutInBounds` with the layer's bounds.
    func attach(to layer: CALayer) {
        layer.addSublayer(gradientLayer)
        layer.addSublayer(particleLayer)
    }

    func layoutInBounds(_ bounds: CGRect, backingScale: CGFloat? = nil) {
        let fieldH = bounds.height * coverage.boundsFraction
        gradientLayer.frame = bounds

        let resolvedScale = backingScale ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let resolvedColorSpace = displayColorSpace()
        if bounds.size != screenSize || resolvedScale != screenScale
            || resolvedColorSpace != bitmapColorSpace {
            screenSize = bounds.size
            fieldSize = CGSize(width: bounds.width, height: fieldH)
            screenScale = resolvedScale
            bitmapColorSpace = resolvedColorSpace
            rebuildContext()
            dots.removeAll()
            if currentTheme != nil, reduceMotion {
                renderFrame()
            }
        }
        applyPresentation()
    }

    /// Keeps panel particles to these rounded panels, given in field
    /// points with y up. Nothing draws between them. One light roams freely
    /// over them all and may light several at once.
    func setPanels(_ rects: [CGRect], cornerRadius: CGFloat) {
        guard rects != panels || cornerRadius != panelCornerRadius else { return }
        panels = rects
        panelCornerRadius = cornerRadius
        route = []
        routeRandom = RouteRandom(state: 0)
        if currentTheme != nil, reduceMotion {
            renderFrame()
        }
    }

    /// The panels the field shows on: the whole field when none are set.
    private func panelAreas(in size: CGSize) -> [CGRect] {
        panels.isEmpty ? [CGRect(origin: .zero, size: size)] : panels
    }

    /// Where the light is `elapsed` seconds along its route. It sweeps on a
    /// smooth curve through waypoints scattered right across the panels,
    /// edges included. Its speed eases between waypoints and never jumps.
    private func routePoint(at elapsed: Double) -> CGPoint {
        let span = panels.dropFirst().reduce(panels[0]) { $0.union($1) }
        if route.isEmpty {
            route = [(CGPoint(x: span.midX, y: span.midY), 0)]
        }
        while route.count < 3 || route[route.count - 2].time <= elapsed {
            let previous = route[route.count - 1]
            var point = previous.point
            // Prefer a waypoint well away from the last, so the light keeps travelling.
            for _ in 0..<4 {
                point = CGPoint(x: CGFloat.random(in: span.minX...span.maxX, using: &routeRandom),
                                y: CGFloat.random(in: span.minY...span.maxY, using: &routeRandom))
                if hypot(point.x - previous.point.x, point.y - previous.point.y)
                    > 0.4 * hypot(span.width, span.height) { break }
            }
            let distance = hypot(point.x - previous.point.x, point.y - previous.point.y)
            let speed = Self.panelLightSpeed * CGFloat.random(in: 0.75...1.25, using: &routeRandom)
            route.append((point, previous.time + max(1, Double(distance / speed))))
        }

        var index = route.count - 2
        while index > 0, route[index].time > elapsed { index -= 1 }
        /// The velocity through a waypoint, from its neighbours. It starts at rest.
        func velocity(_ i: Int) -> CGVector {
            guard i > 0 else { return .zero }
            let span = CGFloat(route[i + 1].time - route[i - 1].time)
            return CGVector(dx: (route[i + 1].point.x - route[i - 1].point.x) / span,
                            dy: (route[i + 1].point.y - route[i - 1].point.y) / span)
        }
        // A cubic Hermite curve between the two waypoints either side.
        let from = route[index]
        let to = route[index + 1]
        let duration = CGFloat(to.time - from.time)
        let s = CGFloat(elapsed - from.time) / duration
        let leave = velocity(index)
        let arrive = velocity(index + 1)
        let start = 2 * s * s * s - 3 * s * s + 1
        let end = 3 * s * s - 2 * s * s * s
        let outward = (s * s * s - 2 * s * s + s) * duration
        let inward = (s * s * s - s * s) * duration
        return CGPoint(
            x: start * from.point.x + end * to.point.x + outward * leave.dx + inward * arrive.dx,
            y: start * from.point.y + end * to.point.y + outward * leave.dy + inward * arrive.dy)
    }

    /// Turns the agent card's light black beneath its tiles, or back to its
    /// theme's colour. A hidden field changes at once; a shown one eases.
    func setDarkLight(_ dark: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        guard dark != darkLight else { return }
        darkLight = dark
        darknessFrom = currentTheme == nil ? (dark ? 1 : 0) : displayedDarkness
        darknessStartedAt = now
        if reduceMotion, currentTheme != nil { renderFrame(at: now) }
    }

    func setIntensity(_ value: Double) {
        intensityMultiplier = max(0, min(1, value))
        applyPresentation()
    }

    /// Driven by the same presentation clock as the transcription pill.
    func setDeparture(_ value: CGFloat, blurRadius: CGFloat = 0) {
        departure = max(0, min(1, value))
        self.blurRadius = max(0, blurRadius)
        applyPresentation()
    }

    private func applyPresentation() {
        // The overlay re-applies its presentation on every 30 Hz display tick.
        // Unchanged inputs must not dirty the layer tree each tick (RR-440).
        let inputs = PresentationInputs(
            fieldSize: fieldSize,
            departure: departure,
            blurRadius: blurRadius,
            intensity: intensityMultiplier,
            visible: currentTheme != nil,
            reduceMotion: reduceMotion
        )
        guard inputs != appliedPresentation else { return }
        appliedPresentation = inputs
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        particleLayer.transform = CATransform3DIdentity
        particleLayer.frame = CGRect(origin: .zero, size: fieldSize)
        tileLayer.frame = particleLayer.bounds
        let scale = reduceMotion ? 1 : 1 - (1 - RelayMotion.Style.surface.hiddenScale) * departure
        particleLayer.transform = RelayLayerMotion.centeredScale(scale, on: particleLayer)
        particleLayer.opacity = currentTheme == nil ? 0 : Float(intensityMultiplier * (1 - departure))
        gradientLayer.opacity = currentTheme == nil ? 0 : Float(intensityMultiplier * (1 - departure))
        if currentTheme != nil, !reduceMotion, departure > 0, departure < 1, blurRadius > 0 {
            motionBlur.setValue(blurRadius, forKey: kCIInputRadiusKey)
            particleLayer.filters = [motionBlur]
        } else {
            // Keep resting, hidden, and reduced-motion fields unfiltered.
            particleLayer.filters = nil
        }
        CATransaction.commit()
    }

    func transition(to theme: Theme?, reduceMotion: Bool = false,
                    now: CFTimeInterval = CACurrentMediaTime()) {
        let resolvedReduceMotion = reduceMotion || theme == .workspace
        guard theme != currentTheme || resolvedReduceMotion != self.reduceMotion else { return }
        let drawsOrb = coverage == .agentOrb || tileGrid
        if drawsOrb, theme != currentTheme {
            previousOrbColor = displayedOrbColor
            orbColorStartedAt = now
        }
        if !drawsOrb, let currentTheme, let theme, currentTheme != theme,
           !resolvedReduceMotion {
            previousTheme = currentTheme
            themeChangedAt = now
        } else if theme != currentTheme {
            previousTheme = nil
        }
        currentTheme = theme
        self.reduceMotion = resolvedReduceMotion
        applyPresentation()

        guard theme != nil else {
            displayedOrbColor = nil
            previousOrbColor = nil
            stopAnimation()
            return
        }

        if resolvedReduceMotion {
            stopAnimation()
            renderFrame(at: now)
        } else {
            startAnimation(now: now)
        }
    }

    // MARK: - Animation loop

    private func startAnimation(now: CFTimeInterval) {
        guard animationTimer == nil else { return }
        startTime = now
        renderFrame(at: now)
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

    func renderFrame(at time: CFTimeInterval = CACurrentMediaTime()) {
        guard let theme = currentTheme, let ctx = bitmapContext else { return }
        let size = fieldSize
        guard size.width > 0, size.height > 0 else { return }

        let elapsed = reduceMotion ? 0 : time - startTime
        let scale = screenScale

        let grid: [Dot]
        if tileGrid {
            renderTileGrid(theme: theme, size: size, elapsed: elapsed, now: time, into: ctx)
            return
        } else if coverage == .agentOrb {
            grid = buildOrbGrid(theme: theme, size: size, elapsed: elapsed, now: time)
        } else {
            guard let cached = cachedGrid(for: theme, size: size) else { return }
            grid = cached
        }

        // Clear
        ctx.clear(CGRect(x: 0, y: 0, width: Int(size.width * scale), height: Int(size.height * scale)))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)

        var arrival: CGFloat = 1
        if let previousTheme {
            arrival = RelayMotion.changeCurve.progress(
                CGFloat((time - themeChangedAt) / Self.themeCrossfadeDuration)
            )
            if arrival < 1, let previousGrid = cachedGrid(for: previousTheme, size: size) {
                drawDots(previousGrid, theme: previousTheme, elapsed: elapsed, alphaScale: 1 - arrival, in: ctx)
            } else {
                self.previousTheme = nil
                arrival = 1
            }
        }
        drawDots(grid, theme: theme, elapsed: elapsed, alphaScale: arrival, in: ctx)

        ctx.restoreGState()
        let image = ctx.makeImage()
        latestParticleImage = image
        particleLayer.contents = image
    }

    private func cachedGrid(for theme: Theme, size: CGSize) -> [Dot]? {
        if dots[theme] == nil {
            dots[theme] = convertedToBitmapColorSpace(buildDotGrid(theme: theme, size: size))
        }
        return dots[theme]
    }

    /// Converts the device-RGB dot colours once per grid, matching the
    /// conversion Core Animation otherwise applied to every frame's pixels.
    private func convertedToBitmapColorSpace(_ grid: [Dot]) -> [Dot] {
        let deviceRGB = CGColorSpaceCreateDeviceRGB()
        guard bitmapColorSpace != deviceRGB else { return grid }
        var converted: [SIMD3<Double>: SIMD3<Double>] = [:]
        return grid.map { dot in
            let source = SIMD3(Double(dot.r), Double(dot.g), Double(dot.b))
            let rgb: SIMD3<Double>
            if let known = converted[source] {
                rgb = known
            } else {
                let components = CGColor(colorSpace: deviceRGB, components: [dot.r, dot.g, dot.b, 1])?
                    .converted(to: bitmapColorSpace, intent: .defaultIntent, options: nil)?
                    .components
                if let components, components.count >= 3 {
                    rgb = SIMD3(Double(components[0]), Double(components[1]), Double(components[2]))
                } else {
                    rgb = source
                }
                converted[source] = rgb
            }
            return Dot(x: dot.x, y: dot.y, baseRadius: dot.baseRadius, baseAlpha: dot.baseAlpha,
                       r: CGFloat(rgb.x), g: CGFloat(rgb.y), b: CGFloat(rgb.z))
        }
    }

    /// Screen-field dot centres sit on device-pixel corners at the usual 1x
    /// and 2x scales, so each dot's coverage depends only on its radius.
    private var dotsAlignToPixels: Bool {
        guard coverage != .agentOrb else { return false }
        let half = spacing / 2 * screenScale
        let step = spacing * screenScale
        return half == half.rounded() && step == step.rounded()
    }

    private func drawDots(
        _ grid: [Dot],
        theme: Theme,
        elapsed: Double,
        alphaScale: CGFloat,
        in ctx: CGContext
    ) {
        guard alphaScale > 0.001 else { return }
        // Filling ~10k CoreGraphics ellipse paths per frame kept the main
        // thread busy whenever the overlay animated (RR-440). Aligned fields
        // composite cached CoreGraphics coverage instead; the result matches
        // within a few 8-bit levels at antialiased edges.
        let pixels = dotsAlignToPixels && !drawsDotsWithCoreGraphics
            ? ctx.data?.assumingMemoryBound(to: UInt8.self) : nil
        for dot in grid {
            // The card's silhouette changes through the density field. Keep
            // its dot centres fixed so the halftone grid stays crisp.
            let wave: CGFloat
            if coverage == .agentOrb {
                wave = 0
            } else {
                // Diagonal waves at different angles and speeds.
                let wave1 = sin(Double(dot.x) * 0.012 - Double(dot.y) * 0.008 - elapsed * 4.2)
                let wave2 = sin(Double(dot.x) * 0.007 + Double(dot.y) * 0.011 - elapsed * 2.7) * 0.4
                let wave3 = sin(Double(dot.x) * 0.004 - elapsed * 1.1) * 0.3
                wave = CGFloat(wave1 + wave2 + wave3) / 1.7
            }
            let radiusScale: CGFloat = 1.0 + wave * 0.2
            let radius = dot.baseRadius * radiusScale
            guard radius > 0.1 else { continue }

            // Preserve the exact design color for the static workspace matrix.
            let baseAlpha = theme == .workspace
                ? dot.baseAlpha
                : dot.baseAlpha * (1.0 + wave * 0.1)
            let alpha = baseAlpha * alphaScale
            guard baseAlpha > 0.02, alpha > 0.002 else { continue }

            if let pixels {
                stampDot(dot, radius: radius, alpha: alpha, into: pixels, context: ctx)
                continue
            }
            ctx.setFillColor(red: dot.r, green: dot.g, blue: dot.b, alpha: alpha)
            ctx.fillEllipse(in: CGRect(
                x: dot.x - radius, y: dot.y - radius,
                width: radius * 2, height: radius * 2))
        }
    }

    /// Source-over composites one dot into the premultiplied RGBA bitmap.
    private func stampDot(
        _ dot: Dot,
        radius: CGFloat,
        alpha: CGFloat,
        into pixels: UnsafeMutablePointer<UInt8>,
        context ctx: CGContext
    ) {
        let stamp = coverageStamp(radiusPixels: radius * screenScale)
        let half = stamp.size / 2
        let centerX = Int((dot.x * screenScale).rounded())
        let centerY = Int((dot.y * screenScale).rounded())
        let width = ctx.width
        let height = ctx.height
        let bytesPerRow = ctx.bytesPerRow
        let opacity = Float(max(0, min(1, alpha)))
        let red = Float(max(0, min(1, dot.r))) * opacity * 255
        let green = Float(max(0, min(1, dot.g))) * opacity * 255
        let blue = Float(max(0, min(1, dot.b))) * opacity * 255
        let cover = opacity * 255
        stamp.alpha.withUnsafeBufferPointer { mask in
            for row in 0..<stamp.size {
                // Bitmap memory runs top-down; device y runs bottom-up.
                let y = height - centerY - half + row
                guard y >= 0, y < height else { continue }
                let line = pixels + y * bytesPerRow
                for column in 0..<stamp.size {
                    let coverage = mask[row * stamp.size + column]
                    guard coverage > 0 else { continue }
                    let x = centerX - half + column
                    guard x >= 0, x < width else { continue }
                    let weight = Float(coverage) / 255
                    let pixel = line + x * 4
                    let sourceAlpha = cover * weight
                    let keep = 1 - sourceAlpha / 255
                    pixel[0] = UInt8(min(255, (red * weight + Float(pixel[0]) * keep).rounded()))
                    pixel[1] = UInt8(min(255, (green * weight + Float(pixel[1]) * keep).rounded()))
                    pixel[2] = UInt8(min(255, (blue * weight + Float(pixel[2]) * keep).rounded()))
                    pixel[3] = UInt8(min(255, (sourceAlpha + Float(pixel[3]) * keep).rounded()))
                }
            }
        }
    }

    private func coverageStamp(radiusPixels: CGFloat) -> CoverageStamp {
        let key = Int((radiusPixels * Self.stampSteps).rounded())
        if let stamp = coverageStamps[key] { return stamp }
        let radius = CGFloat(key) / Self.stampSteps
        let half = Int(radius.rounded(.up)) + 1
        let size = half * 2
        var alpha = [UInt8](repeating: 0, count: size * size)
        alpha.withUnsafeMutableBytes { buffer in
            guard let mask = CGContext(
                data: buffer.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return }
            mask.setFillColor(gray: 0, alpha: 1)
            mask.fillEllipse(in: CGRect(
                x: CGFloat(half) - radius, y: CGFloat(half) - radius,
                width: radius * 2, height: radius * 2))
        }
        let stamp = CoverageStamp(size: size, alpha: alpha)
        coverageStamps[key] = stamp
        return stamp
    }

    // MARK: - Dot grid generation

    /// The card orb's deforming liquid volume, in field points.
    private struct OrbField {
        var lobes: [(x: Double, y: Double, rx: Double, ry: Double)]
        let size: CGSize
        let scale: Double
        let centreX: Double
        let centreY: Double
        /// A stretch of the whole volume along a unit direction, narrowing
        /// it across that direction to keep its area. 1 leaves it as it is.
        var lean: (x: Double, y: Double, stretch: Double) = (1, 0, 1)

        /// The summed lobe density, about 1.6 where the lobes overlap most.
        func density(atX x: CGFloat, y: CGFloat) -> Double {
            var nx = Double(x - size.width / 2) / scale
            var ny = Double(y - size.height / 2) / scale
            if lean.stretch != 1 {
                let along = (nx * lean.x + ny * lean.y) / lean.stretch
                let across = (ny * lean.x - nx * lean.y) * lean.stretch.squareRoot()
                nx = along * lean.x - across * lean.y
                ny = along * lean.y + across * lean.x
            }
            nx += centreX
            ny += centreY
            var density = 0.0
            for lobe in lobes {
                let dx = (nx - lobe.x) / lobe.rx
                let dy = (ny - lobe.y) / lobe.ry
                density += exp(-2 * (dx * dx + dy * dy))
            }
            return density
        }

        /// How far inside the volume a point sits, from 0 outside to 1 at the core.
        func body(atX x: CGFloat, y: CGFloat) -> Double {
            Self.body(density: density(atX: x, y: y))
        }

        static func body(density: Double) -> Double {
            max(0, min(1, (density - 0.035) / 0.85))
        }
    }

    /// Overlapping, deforming lobes that form one continuous liquid volume.
    /// Opposing stretches redistribute its shape without a breathing scale
    /// animation or moving the grid itself. `depth` scales how far it deforms.
    private static func orbLobes(elapsed: Double, depth: Double) -> [(x: Double, y: Double, rx: Double, ry: Double)] {
        let stretch = sin(elapsed * 0.72) * 0.10 * depth
        let curl = sin(elapsed * 0.53) * 0.055 * depth
        return [
            (-0.27 + curl, -0.15 + sin(elapsed * 0.61) * 0.055 * depth,
             0.64 + stretch, 0.59 / (1 + stretch)),
            (0.26 - curl, 0.28 + sin(elapsed * 0.47) * 0.055 * depth,
             0.54 - stretch * 0.4, 0.57 + sin(elapsed * 0.58) * 0.045 * depth),
            (0.20 + sin(elapsed * 0.43) * 0.065 * depth, -0.26 - curl * 0.5,
             0.50 + sin(elapsed * 0.67) * 0.035 * depth, 0.47 + stretch * 0.4)
        ]
    }

    /// The card orb fits the agent card below its title, refitting its
    /// changing volume each frame. Reduced Motion freezes it. Panel
    /// particles keep one size and centre, so its deformation shows: a
    /// third larger than at rest in the card at full width.
    private func orbField(size: CGSize, elapsed: Double) -> OrbField {
        let onPanels = !panels.isEmpty
        let lobes = Self.orbLobes(elapsed: elapsed, depth: onPanels ? Self.panelMorphDepth : 1)
        let frame = onPanels ? Self.orbLobes(elapsed: 0, depth: 1) : lobes
        let left = frame.map { $0.x - $0.rx * 1.3 }.min()!
        let right = frame.map { $0.x + $0.rx * 1.3 }.max()!
        let bottom = frame.map { $0.y - $0.ry * 1.3 }.min()!
        let top = frame.map { $0.y + $0.ry * 1.3 }.max()!
        let fitWidth = (scalesWithWidth ? size.width : Self.panelLightWidth) - 24
        let fitHeight = coverage == .agentOrb ? size.height - 240 : .greatestFiniteMagnitude
        let scale: Double = min(max(1, fitWidth) / (right - left),
                                max(1, fitHeight) / (top - bottom)) * (onPanels ? Self.panelLightGrowth : 1)
        return OrbField(lobes: lobes, size: size, scale: scale,
                        centreX: (left + right) / 2, centreY: (bottom + top) / 2)
    }

    /// The theme's orb colour, eased from the colour shown before the last theme change.
    private func easedOrbColor(theme: Theme, monochrome: SIMD3<Double>, now: CFTimeInterval) -> SIMD3<Double> {
        let color = NSColor(hue: theme.baseHue, saturation: theme.baseSaturation,
                            brightness: 1, alpha: 1).usingColorSpace(.sRGB)!
        let target = theme.baseSaturation == 0
            ? monochrome
            : SIMD3(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
        let progress = reduceMotion ? 1 : max(0, min(1, (now - orbColorStartedAt) / 0.3))
        let blend = progress * progress * (3 - 2 * progress)
        let previous = previousOrbColor ?? target
        let eased = previous + (target - previous) * blend
        displayedOrbColor = eased
        return eased
    }

    private func buildOrbGrid(theme: Theme, size: CGSize, elapsed: Double, now: CFTimeInterval) -> [Dot] {
        // The monochrome orb fades from a white core to the card's navy
        // (#11161D) at its sparse edge instead of staying flat white.
        let rim = easedOrbColor(theme: theme, monochrome: SIMD3(17.0 / 255, 22.0 / 255, 29.0 / 255), now: now)
        let field = orbField(size: size, elapsed: elapsed)
        let step: CGFloat = 10
        let cols = Int(size.width / step)
        let rows = Int(size.height / step)
        var result: [Dot] = []
        result.reserveCapacity(cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let x = CGFloat(col) * step + (size.width - CGFloat(cols - 1) * step) / 2
                let y = CGFloat(row) * step + (size.height - CGFloat(rows - 1) * step) / 2
                let body = field.body(atX: x, y: y)
                guard body > 0.001 else { continue }
                let highlight = min(1, body / 0.7)
                let white = highlight * highlight * (3 - 2 * highlight)
                let rgb = rim + (SIMD3<Double>(repeating: 1) - rim) * white
                result.append(Dot(
                    x: x, y: y,
                    baseRadius: step * 0.25 * pow(body, 0.72),
                    baseAlpha: min(1, body * 5),
                    r: rgb.x, g: rgb.y, b: rgb.z
                ))
            }
        }
        return result
    }

    /// The tile grid, extending past the field's edges so no border line shows.
    private func tileGridRect(size: CGSize) -> (rect: CGRect, pitch: CGFloat) {
        let pitch = scalesWithWidth
            ? min(Self.panelTilePitch, max(8, size.width / Self.tilesAcross))
            : Self.panelTilePitch
        let columns = (size.width / pitch).rounded(.up) + 1
        let rows = (size.height / pitch).rounded(.up) + 1
        let rect = CGRect(x: (size.width - columns * pitch) / 2, y: (size.height - rows * pitch) / 2,
                          width: columns * pitch, height: rows * pitch)
        return (rect, pitch)
    }

    /// Draws one frame of panel particles. The orb's light roams the panel
    /// (below the agent card's title), glowing in the theme's colour and whitening towards its
    /// core, as the dot orb does. At its core the tiles are circles standing
    /// apart with the light all round them. Away from it they grow and square
    /// off until they meet edge to edge, so the light narrows to seams that
    /// close and the panel stays seamless where it is dark.
    private func renderTileGrid(theme: Theme, size: CGSize, elapsed: Double,
                                now: CFTimeInterval, into ctx: CGContext) {
        guard let glowLight, let glowPixels = glowLight.data?.assumingMemoryBound(to: UInt8.self) else { return }
        func smooth(_ value: Double) -> Double {
            let t = max(0, min(1, value))
            return t * t * (3 - 2 * t)
        }
        let rim = easedOrbColor(theme: theme, monochrome: SIMD3(0.45, 0.50, 0.60), now: now)
        let darkening = reduceMotion ? 1 : smooth((now - darknessStartedAt) / 0.3)
        let darkness = darknessFrom + ((darkLight ? 1 : 0) - darknessFrom) * darkening
        displayedDarkness = darkness
        let lightTime = elapsed * (panels.isEmpty ? Self.tileLightPace : Self.panelMorphPace)
        var field = orbField(size: size, elapsed: lightTime)
        let (grid, pitch) = tileGridRect(size: size)
        let columns = Int((grid.width / pitch).rounded())
        let rows = Int((grid.height / pitch).rounded())

        // A copy of the orb wanders on a slow path that never quite repeats.
        // On panels it roams freely over them all instead. Reduced Motion
        // holds it at its starting point.
        let areas = panelAreas(in: size)
        let phase = lightTime * 2 * .pi / Self.lightWanderPeriod
        let topReserve = coverage == .agentOrb ? Self.tileGridTopReserve : 0
        func wander(in area: CGRect) -> CGPoint {
            CGPoint(
                x: area.midX
                    + area.width * 0.2 * CGFloat(0.78 * sin(phase + 0.5) + 0.22 * sin(1.93 * phase + 1.7)),
                y: area.midY - topReserve / 2
                    + area.height * 0.15 * CGFloat(0.75 * sin(0.77 * phase + 2.3) + 0.25 * sin(1.41 * phase + 0.4)))
        }
        let lightCentre = panels.isEmpty
            ? wander(in: areas[0])
            : routePoint(at: elapsed)
        if !panels.isEmpty {
            // The light leans into its motion: its lobes trail behind along
            // the route, following its curves, and it stretches along its
            // heading the faster it goes.
            for (index, lag) in Self.panelLobeLag.enumerated() where lag > 0 {
                let behind = routePoint(at: max(0, elapsed - lag))
                field.lobes[index].x += Double(behind.x - lightCentre.x) / field.scale
                field.lobes[index].y += Double(behind.y - lightCentre.y) / field.scale
            }
            let earlier = routePoint(at: max(0, elapsed - 0.05))
            let speed = hypot(lightCentre.x - earlier.x, lightCentre.y - earlier.y) / 0.05
            if speed > 1 {
                field.lean = (Double((lightCentre.x - earlier.x) / 0.05 / speed),
                              Double((lightCentre.y - earlier.y) / 0.05 / speed),
                              1 + 0.35 * min(1, Double(speed / (Self.panelLightSpeed * 1.25))))
            }
        }

        // The field is smooth, so sample its density coarsely and interpolate.
        let coarse: CGFloat = 8
        let coarseColumns = Int((size.width / coarse).rounded(.up)) + 1
        let coarseRows = Int((size.height / coarse).rounded(.up)) + 1
        var densities = [Double](repeating: 0, count: coarseColumns * coarseRows)
        for row in 0..<coarseRows {
            for column in 0..<coarseColumns {
                densities[row * coarseColumns + column] = field.density(
                    atX: size.width / 2 + CGFloat(column) * coarse - lightCentre.x,
                    y: size.height / 2 + CGFloat(row) * coarse - lightCentre.y)
            }
        }
        // The agent card keeps the tiles along its border closed and unlit
        // for a tile and a half, then fades them in over three. Workspace
        // panels light right up to their rounded edges; only the soft glow
        // beneath the tiles stops a sample short, so it never spills out.
        let edgeRadius = panels.isEmpty ? 0 : panelCornerRadius
        /// 1 well inside a panel, falling to 0 at its edge (the agent card's
        /// closed band), and 0 outside every panel.
        func borderFade(atX x: CGFloat, y: CGFloat) -> Double {
            var toBorder = -CGFloat.infinity
            for area in areas {
                // Distance in from the panel's rounded outline.
                let dx = max(area.minX + edgeRadius - x, x - (area.maxX - edgeRadius), 0)
                let dy = max(area.minY + edgeRadius - y, y - (area.maxY - edgeRadius), 0)
                let inside = dx > 0 && dy > 0
                    ? edgeRadius - hypot(dx, dy)
                    : min(x - area.minX, y - area.minY, area.maxX - x, area.maxY - y)
                toBorder = max(toBorder, inside)
            }
            guard panels.isEmpty else {
                return Double(max(0, min(1, (toBorder - Self.glowSampleSpacing) / Self.glowSampleSpacing)))
            }
            return Double(max(0, min(1, (toBorder - 1.5 * pitch) / (3 * pitch))))
        }
        /// The lobes' summed density, interpolated between the coarse samples.
        func density(atX x: CGFloat, y: CGFloat) -> Double {
            let fx = min(max(Double(x / coarse), 0), Double(coarseColumns - 1))
            let fy = min(max(Double(y / coarse), 0), Double(coarseRows - 1))
            let x0 = min(Int(fx), coarseColumns - 2)
            let y0 = min(Int(fy), coarseRows - 2)
            let tx = fx - Double(x0)
            let ty = fy - Double(y0)
            let i = y0 * coarseColumns + x0
            let lower = densities[i] + (densities[i + 1] - densities[i]) * tx
            let upper = densities[i + coarseColumns]
                + (densities[i + coarseColumns + 1] - densities[i + coarseColumns]) * tx
            return lower + (upper - lower) * ty
        }
        /// 0 outside the light, rising to 1 only where its lobes overlap most.
        func heat(atX x: CGFloat, y: CGFloat) -> Double {
            max(0, min(1, (density(atX: x, y: y) - 0.035) / 1.55))
        }
        /// How far the tiles stand open: 1 at the light's core, falling evenly
        /// with distance from it to 0 where they have closed over it.
        func tileOpen(_ heat: Double) -> Double {
            // The lobes fall off as bell curves, so undo one to get a distance
            // from the core, measured in lobe radii.
            let density = heat * 1.55 + 0.035
            let fromCore = (-0.5 * log(min(density / 1.6, 1))).squareRoot()
            return max(0, min(1, 1 - (fromCore - 0.2) / 1.1))
        }
        /// On Workspace panels, how fully a tile is drawn. Tiles stay solid a
        /// little past the glow's edge, so the light shows only in the seams,
        /// then fade out over about two tiles to reveal what lies beneath.
        func presence(atX x: CGFloat, y: CGFloat) -> Double {
            guard !panels.isEmpty else { return 1 }
            let fromCore = (-0.5 * log(min(max(density(atX: x, y: y), 1e-6) / 1.6, 1))).squareRoot()
            return smooth((1 - (fromCore - 0.2) / 1.1 + 0.5) / 0.3)
        }

        // The light beneath the tiles, sampled at low resolution and scaled
        // by Core Animation on the GPU. It dims only as the seams between the
        // tiles narrow shut, so it stays bright in whatever gap is left.
        let spacing = Self.glowSampleSpacing
        for row in 0..<glowLight.height {
            // Bitmap memory runs top-down; field y runs bottom-up.
            let y = (CGFloat(glowLight.height - 1 - row) + 0.5) * spacing
            let line = glowPixels + row * glowLight.bytesPerRow
            for column in 0..<glowLight.width {
                let pixel = line + column * 4
                let x = (CGFloat(column) + 0.5) * spacing
                let fade = borderFade(atX: x, y: y)
                guard fade > 0 else {
                    pixel.update(repeating: 0, count: 4)
                    continue
                }
                let localHeat = heat(atX: x, y: y)
                // On Workspace loader panels the light beneath the tiles is
                // pure black, and on the agent card while it is dark.
                let rgb = panels.isEmpty
                    ? (rim + (SIMD3<Double>(repeating: 1) - rim) * smooth((localHeat - 0.3) / 0.7)) * (1 - darkness)
                    : SIMD3<Double>(repeating: 0)
                let alpha = smooth(tileOpen(localHeat) / 0.5) * smooth(fade)
                pixel[0] = UInt8((rgb.x * alpha * 255).rounded())
                pixel[1] = UInt8((rgb.y * alpha * 255).rounded())
                pixel[2] = UInt8((rgb.z * alpha * 255).rounded())
                pixel[3] = UInt8((alpha * 255).rounded())
            }
        }

        // Tiles at full resolution above the light, in the panels' own colour.
        // They stay square until 40% open and are fully round from 85%. On
        // Workspace panels, tiles appear only around the light, so whatever
        // lies beneath stays in view elsewhere and the light passes over it.
        let tiles = CGMutablePath()
        var rimTiles: [(path: CGPath, alpha: CGFloat)] = []
        for column in 0..<columns {
            for row in 0..<rows {
                let x0 = grid.minX + CGFloat(column) * pitch
                let y0 = grid.minY + CGFloat(row) * pitch
                let cell = CGRect(x: x0, y: y0, width: pitch, height: pitch)
                guard panels.isEmpty || panels.contains(where: { $0.intersects(cell) }) else { continue }
                let open = CGFloat(tileOpen(heat(atX: x0 + pitch / 2, y: y0 + pitch / 2))
                    * borderFade(atX: x0 + pitch / 2, y: y0 + pitch / 2))
                let presence = CGFloat(presence(atX: x0 + pitch / 2, y: y0 + pitch / 2))
                guard presence > 0 else { continue }
                let side = pitch * (1 - Self.tileCoreGap * open)
                let corner = side / 2 * CGFloat(smooth((Double(open) - 0.4) / 0.45))
                let inset = (pitch - side) / 2
                let tile = CGRect(x: x0 + inset, y: y0 + inset, width: side, height: side)
                if presence < 1 {
                    rimTiles.append((CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner,
                                            transform: nil), presence))
                } else {
                    tiles.addRoundedRect(in: tile, cornerWidth: corner, cornerHeight: corner)
                }
            }
        }
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.saveGState()
        ctx.scaleBy(x: screenScale, y: screenScale)
        if !panels.isEmpty {
            let outline = CGMutablePath()
            for panel in panels {
                outline.addRoundedRect(in: panel, cornerWidth: panelCornerRadius, cornerHeight: panelCornerRadius)
            }
            ctx.addPath(outline)
            ctx.clip()
        }
        ctx.setFillColor(BoardDarkSurfaceStyle.panelFillNSColor.cgColor)
        ctx.addPath(tiles)
        ctx.fillPath()
        for rim in rimTiles {
            ctx.setAlpha(rim.alpha)
            ctx.addPath(rim.path)
            ctx.fillPath()
        }
        ctx.restoreGState()

        let image = ctx.makeImage()
        latestParticleImage = image
        latestGlowImage = glowLight.makeImage()
        particleLayer.contents = latestGlowImage
        tileLayer.contents = image
    }

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
                if theme == .workspace || theme == .idle {
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
        if tileGrid {
            let glowWidth = Int((fieldSize.width / Self.glowSampleSpacing).rounded(.up))
            let glowHeight = Int((fieldSize.height / Self.glowSampleSpacing).rounded(.up))
            glowLight = glowWidth > 0 && glowHeight > 0
                ? CGContext(data: nil, width: glowWidth, height: glowHeight,
                            bitsPerComponent: 8, bytesPerRow: 0, space: bitmapColorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                : nil
        }
        let w = Int(fieldSize.width * screenScale)
        let h = Int(fieldSize.height * screenScale)
        guard w > 0, h > 0 else {
            bitmapContext = nil
            return
        }
        bitmapContext = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: bitmapColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        if bitmapContext == nil, bitmapColorSpace != CGColorSpaceCreateDeviceRGB() {
            bitmapColorSpace = CGColorSpaceCreateDeviceRGB()
            rebuildContext()
        }
    }

    /// Screen fields render in their window's colour space. A device-RGB
    /// bitmap made Core Animation colour-convert every frame on the main
    /// thread (RR-440). The card orb rebuilds its colours every frame, and a
    /// view outside a window keeps device RGB. The tile grid draws in sRGB so
    /// its tiles match the panels' sRGB fill exactly.
    private func displayColorSpace() -> CGColorSpace {
        let deviceRGB = CGColorSpaceCreateDeviceRGB()
        if tileGrid { return CGColorSpace(name: CGColorSpace.sRGB) ?? deviceRGB }
        guard coverage != .agentOrb, let window = hostView?.window else { return deviceRGB }
        let space = (window.colorSpace ?? window.screen?.colorSpace ?? NSScreen.main?.colorSpace)?
            .cgColorSpace
        guard let space, space.model == .rgb else { return deviceRGB }
        return space
    }

    var isAnimationRunning: Bool {
        animationTimer != nil
    }

    var tilePitch: CGFloat {
        tileGridRect(size: fieldSize).pitch
    }

    /// A seeded SplitMix64 generator, so the light takes the same route on every run.
    private struct RouteRandom: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    var renderedParticleFrame: CGRect {
        particleLayer.frame
    }

    var renderedGradientFrame: CGRect {
        gradientLayer.frame
    }

    var renderedGlowImage: CGImage? {
        latestGlowImage
    }

    var renderedParticleImage: CGImage? {
        latestParticleImage
    }
}
