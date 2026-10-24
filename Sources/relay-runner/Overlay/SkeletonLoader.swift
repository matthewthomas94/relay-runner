import AppKit
import QuartzCore
import SwiftUI

/// What a skeleton loader stands in for.
enum SkeletonLoaderLayout: Equatable {
    /// The Workspace board, with its columns starting `columnTop` points
    /// below the loader's top edge.
    case board(columnTop: CGFloat)
    /// A provider session in the embedded terminal.
    case terminal
    /// The Notes tab: the list of notes beside the open note.
    case notes
    /// The Settings tab: categories, their settings, and the agent card.
    case settings
    /// Workspace History: the archived tickets beside the open one.
    case history
}

/// A placeholder shape in a skeleton loader.
struct SkeletonBone: Equatable {
    enum Style: Equatable {
        case fill
        case outline
    }

    var rect: CGRect
    var radius: CGFloat
    var style: Style
}

/// The design-tool readouts the sketch writes while it constructs, and which
/// surfaces earn the full treatment. Motion lives in `SkeletonGeneration`.
enum SkeletonConstruction {
    /// Width a contour needs before it earns design-tool chrome.
    static let annotatedMinimumWidth: CGFloat = 200
    static let annotatedMinimumHeight: CGFloat = 40
    static let annotatedLimit = 3

    /// How long one element takes to finish constructing after it appears.
    static var duration: TimeInterval {
        SkeletonGeneration.duration * SkeletonGeneration.holdProgress
    }

    /// `320 × 180  t+0.00s`: the size counting up, and the clock.
    static func readout(width: CGFloat, height: CGFloat, time: TimeInterval) -> String {
        String(format: "%d × %d  t+%.2fs", Int(width.rounded()), Int(height.rounded()), time)
    }

    /// `300 × 120`: a key box's size counting up.
    static func dimension(width: CGFloat, height: CGFloat) -> String {
        String(format: "%d × %d", Int(width.rounded()), Int(height.rounded()))
    }

    /// `022·130`: where the live head is, in the element's space.
    static func coordinates(x: CGFloat, y: CGFloat) -> String {
        String(format: "%03d·%03d", max(0, Int(x.rounded())), max(0, Int(y.rounded())))
    }

    /// `FRAME 300×120`: the part under the reticle.
    static func tag(name: String, width: CGFloat, height: CGFloat) -> String {
        String(format: "%@ %d×%d", name.uppercased(), Int(width.rounded()), Int(height.rounded()))
    }

    /// Surfaces earn chrome when the layout has them; otherwise its widest
    /// outlines do, so the terminal welcome and prompt get the treatment.
    static func annotatedRects(surfaces: [CGRect], bones: [SkeletonBone]) -> [CGRect] {
        if !surfaces.isEmpty { return surfaces }
        let candidates = bones.filter {
            $0.style == .outline && $0.rect.width >= annotatedMinimumWidth && $0.rect.height >= annotatedMinimumHeight
        }
        var chosen: [CGRect] = []
        for bone in candidates.sorted(by: { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }) {
            guard chosen.count < annotatedLimit else { break }
            guard !chosen.contains(where: { $0.contains(bone.rect) || bone.rect.contains($0) }) else { continue }
            chosen.append(bone.rect)
        }
        return chosen.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }
}

/// A dot-matrix sketch of the incoming screen, generated the way the
/// libraries.dev hero generates its tiles: a dot field wakes from the centre,
/// a probe sweeps, guides and the contour trace in with dots crawling along
/// them, flyers land on the contour as it reaches them, corner handles pop
/// in, every part traces under a reticle with its tag, and monospace readouts
/// count the size, the clock and the live head's position. The host owns the
/// transition to real content; this drawing never delays readiness. A display
/// link evaluates each frame from `SkeletonGeneration` into pooled layers.
final class SkeletonLoaderView: NSView {
    static let handoffKey = "skeletonHandoff"
    static let alphaBuckets = 12

    let skeleton: SkeletonLoaderLayout

    /// Everything the ready UI replaces along the scan edge.
    private let sketchLayer = CALayer()
    private let fieldInkPool: [CAShapeLayer]
    private let fieldStrongPool: [CAShapeLayer]
    private let wireLinePool: [CAShapeLayer]
    private let wireStrongPool: [CAShapeLayer]
    /// Handles, reticles and readouts outlive the scan and fade last.
    private let handleChromeLayer = CALayer()
    private let handlePool: [CAShapeLayer]
    private var reticleLayers: [CAShapeLayer] = []
    private var readoutLayers: [CATextLayer] = []
    private var tagLayers: [CATextLayer] = []
    private var coordinateLayers: [CATextLayer] = []
    private var keyLayers: [[CATextLayer]] = []
    private var scene = SkeletonGeneration.Scene(bounds: .zero, elements: [], dots: [])
    private var drawnBounds: CGRect?
    private var displayLink: CADisplayLink?
    private var exitStart: CFTimeInterval?
    private var handoffProgress: CGFloat?
    private var handoffGeneration = 0
    private var handoffCompletion: (() -> Void)?

    private(set) var bones: [SkeletonBone] = []
    /// When the construction began; a layout pass never moves it.
    private(set) var constructionStart: CFTimeInterval?
    private(set) var isAnimating = false
    /// Each element's progress at the last rendered frame.
    private(set) var renderedProgress: [Double] = []

    private enum Palette {
        static let slate = NSColor(srgbRed: 148 / 255, green: 163 / 255, blue: 184 / 255, alpha: 1)
        static let ink = slate.withAlphaComponent(0.3).cgColor
        static let line = slate.withAlphaComponent(0.62).cgColor
        static let strong = NSColor(srgbRed: 203 / 255, green: 213 / 255, blue: 225 / 255, alpha: 1).cgColor
        static let surface = BoardDarkSurfaceStyle.panelFillNSColor.cgColor
    }

    override var isFlipped: Bool { true }

    init(layout: SkeletonLoaderLayout, label: String) {
        self.skeleton = layout
        fieldInkPool = Self.pool(fill: Palette.ink, stroke: nil, in: sketchLayer)
        fieldStrongPool = Self.pool(fill: Palette.strong, stroke: nil, in: sketchLayer)
        wireLinePool = Self.pool(fill: Palette.line, stroke: nil, in: sketchLayer)
        wireStrongPool = Self.pool(fill: Palette.strong, stroke: nil, in: sketchLayer)
        handlePool = Self.pool(fill: Palette.surface, stroke: Palette.strong, in: handleChromeLayer)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(sketchLayer)
        layer?.addSublayer(handleChromeLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshAnimation),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// One layer per opacity step, so thousands of dots are a dozen paths.
    private static func pool(fill: CGColor?, stroke: CGColor?, in parent: CALayer) -> [CAShapeLayer] {
        (0..<alphaBuckets).map { bucket in
            let layer = CAShapeLayer()
            layer.fillColor = fill
            layer.strokeColor = stroke
            layer.lineWidth = 1
            layer.opacity = Float(bucket + 1) / Float(alphaBuckets)
            parent.addSublayer(layer)
            return layer
        }
    }

    private static func bucket(_ alpha: Double) -> Int {
        min(alphaBuckets - 1, max(0, Int((alpha * Double(alphaBuckets)).rounded(.up)) - 1))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// The surfaces that carry an outline, handles, guides and readouts.
    var annotatedRects: [CGRect] { scene.elements.map(\.rect) }

    /// The boxes inside them that earn guides, handles and a size label.
    var keyRects: [CGRect] { scene.keyRects }

    /// Whether the ready UI is currently replacing this sketch.
    var isHandingOff: Bool { sketchLayer.mask?.name == SkeletonAssembly.maskName }

    override func layout() {
        super.layout()
        guard drawnBounds != bounds else { refreshAnimation(); return }
        drawnBounds = bounds
        bones = Self.bones(for: skeleton, in: bounds)
        scene = SkeletonGeneration.scene(bounds: bounds, surfaces: Self.panels(for: skeleton, in: bounds), bones: bones)
        let scale = window?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var sized: [CALayer] = [sketchLayer, handleChromeLayer]
        sized += fieldInkPool
        sized += fieldStrongPool
        sized += wireLinePool
        sized += wireStrongPool
        sized += handlePool
        for layer in sized {
            layer.frame = bounds
            layer.contentsScale = scale
        }
        (reticleLayers + readoutLayers + tagLayers + coordinateLayers + keyLayers.flatMap { $0 })
            .forEach { $0.removeFromSuperlayer() }
        reticleLayers = scene.elements.map { _ in
            let reticle = CAShapeLayer()
            reticle.frame = bounds
            reticle.contentsScale = scale
            reticle.fillColor = nil
            reticle.strokeColor = Palette.strong
            reticle.lineWidth = 1.2
            reticle.lineCap = .round
            reticle.opacity = 0
            handleChromeLayer.addSublayer(reticle)
            return reticle
        }
        readoutLayers = scene.elements.map { _ in makeLabel(size: 9, strong: false, scale: scale) }
        tagLayers = scene.elements.map { _ in makeLabel(size: 8, strong: true, scale: scale) }
        keyLayers = scene.elements.map { element in
            element.parts.filter(\.key).map { _ in makeLabel(size: 8, strong: true, scale: scale) }
        }
        coordinateLayers = scene.elements.map { _ in makeLabel(size: 8, strong: true, scale: scale) }
        CATransaction.commit()

        renderCurrent(now: CACurrentMediaTime())
        refreshAnimation()
    }

    private func makeLabel(size: CGFloat, strong: Bool, scale: CGFloat) -> CATextLayer {
        let label = CATextLayer()
        label.contentsScale = scale
        label.font = AppTypography.terminalGridFont(size: size, weight: .medium)
        label.fontSize = size
        label.foregroundColor = strong ? Palette.strong : Palette.line
        label.alignmentMode = .left
        label.truncationMode = .none
        label.isWrapped = false
        label.frame = CGRect(x: 0, y: 0, width: 240, height: size + 4)
        label.opacity = 0
        handleChromeLayer.addSublayer(label)
        return label
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(refreshAnimation),
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
        refreshAnimation()
    }

    override func viewDidHide() { super.viewDidHide(); refreshAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshAnimation() }

    @objc private func refreshAnimation() {
        updateAnimation(
            visible: window?.isVisible == true && window?.isMiniaturized == false && !isHiddenOrHasHiddenAncestor,
            reduceMotion: RelayLayerMotion.reduceMotion
        )
    }

    // MARK: Motion

    /// Hidden loaders and Reduce Motion show the completed sketch without a
    /// display link. A geometry/layout pass must not restart the construction.
    func updateAnimation(visible: Bool, reduceMotion: Bool) {
        let active = visible && !reduceMotion && !scene.elements.isEmpty
        guard active != isAnimating else { return }
        isAnimating = active
        displayLink?.invalidate()
        displayLink = nil
        guard active else {
            renderCurrent(now: CACurrentMediaTime())
            return
        }
        if constructionStart == nil { constructionStart = CACurrentMediaTime() }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        renderCurrent(now: CACurrentMediaTime())
    }

    @objc private func tick(_ link: CADisplayLink) {
        renderCurrent(now: link.targetTimestamp)
    }

    /// Elapsed time once every element has finished constructing.
    private var completeElapsed: TimeInterval {
        SkeletonGeneration.duration + SkeletonGeneration.elementStagger * Double(scene.elements.count)
    }

    private func renderCurrent(now: CFTimeInterval) {
        let elapsed = isAnimating ? (constructionStart.map { now - $0 } ?? 0) : completeElapsed
        var exit = handoffProgress.map(Double.init)
        if exit == nil, let exitStart {
            exit = SkeletonGeneration.clamp((now - exitStart) / SkeletonAssembly.duration)
        }
        renderFrame(elapsed: elapsed, exitFraction: exit)
    }

    /// Draws the sketch as it stands `elapsed` seconds after construction
    /// began. `exitFraction` plays the hand-off part of the timeline.
    func renderFrame(elapsed: TimeInterval, exitFraction: Double? = nil) {
        let progress = scene.elements.indices.map { index -> Double in
            let local = elapsed - Double(index) * SkeletonGeneration.elementStagger
            var a = min(SkeletonGeneration.holdProgress, max(0, local / SkeletonGeneration.duration))
            if let exitFraction {
                a = max(a, SkeletonGeneration.holdProgress
                    + (SkeletonGeneration.endProgress - SkeletonGeneration.holdProgress) * exitFraction)
            }
            return a
        }
        renderedProgress = progress
        apply(SkeletonGeneration.evaluate(scene, progress: progress, elapsedMs: elapsed * 1_000))
    }

    private func apply(_ frame: SkeletonGeneration.Frame) {
        let buckets = Self.alphaBuckets
        var fieldInk = [CGMutablePath?](repeating: nil, count: buckets)
        var fieldStrong = fieldInk
        var wireLine = fieldInk
        var wireStrong = fieldInk
        var handles = fieldInk
        func add(_ dot: SkeletonGeneration.Frame.Dot, to paths: inout [CGMutablePath?]) {
            let bucket = Self.bucket(dot.alpha)
            let path = paths[bucket] ?? CGMutablePath()
            path.addEllipse(in: CGRect(x: dot.center.x - dot.radius, y: dot.center.y - dot.radius,
                                       width: dot.radius * 2, height: dot.radius * 2))
            paths[bucket] = path
        }
        for dot in frame.field { dot.strong ? add(dot, to: &fieldStrong) : add(dot, to: &fieldInk) }
        for dot in frame.wires { dot.strong ? add(dot, to: &wireStrong) : add(dot, to: &wireLine) }
        for handle in frame.handles {
            let bucket = Self.bucket(handle.alpha)
            let path = handles[bucket] ?? CGMutablePath()
            path.addRect(CGRect(x: handle.center.x - handle.size / 2, y: handle.center.y - handle.size / 2,
                                width: handle.size, height: handle.size))
            handles[bucket] = path
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (pool, paths) in [(fieldInkPool, fieldInk), (fieldStrongPool, fieldStrong), (wireLinePool, wireLine),
                              (wireStrongPool, wireStrong), (handlePool, handles)] {
            for (layer, path) in zip(pool, paths) { layer.path = path }
        }
        for (index, layer) in reticleLayers.enumerated() {
            if let reticle = frame.reticles.first(where: { $0.element == index }) {
                layer.path = Self.reticlePath(around: reticle.rect, arm: reticle.arm)
                layer.opacity = Float(reticle.alpha)
            } else {
                layer.opacity = 0
            }
        }
        tagLayers.forEach { $0.opacity = 0 }
        for label in frame.labels {
            let layer: CATextLayer?
            switch label.kind {
            case .readout: layer = readoutLayers.indices.contains(label.element) ? readoutLayers[label.element] : nil
            case .tag: layer = tagLayers.indices.contains(label.element) ? tagLayers[label.element] : nil
            case .coordinates: layer = coordinateLayers.indices.contains(label.element) ? coordinateLayers[label.element] : nil
            case .keyDimension:
                layer = keyLayers.indices.contains(label.element) && keyLayers[label.element].indices.contains(label.key)
                    ? keyLayers[label.element][label.key] : nil
            }
            guard let layer else { continue }
            layer.string = label.text
            layer.frame.origin = CGPoint(x: label.baseline.x, y: label.baseline.y - layer.fontSize - 1)
            layer.opacity = Float(label.alpha)
        }
        CATransaction.commit()
    }

    /// Corner brackets, open along the edges.
    static func reticlePath(around rect: CGRect, arm: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for (corner, dx, dy) in [
            (CGPoint(x: rect.minX, y: rect.minY), arm, arm), (CGPoint(x: rect.maxX, y: rect.minY), -arm, arm),
            (CGPoint(x: rect.maxX, y: rect.maxY), -arm, -arm), (CGPoint(x: rect.minX, y: rect.maxY), arm, -arm),
        ] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx, y: corner.y))
        }
        return path
    }

    // MARK: Handoff

    /// The ready UI replaces the sketch along one scan edge while the
    /// timeline plays out its release: guides, readouts, key chrome, handles
    /// and dots let go in the reference order; handles and readouts linger
    /// past the edge and fade last.
    func animateHandoff(reduceMotion: Bool = RelayLayerMotion.reduceMotion, completion: (() -> Void)? = nil) {
        cancelHandoff()
        guard !reduceMotion else {
            completion?()
            return
        }
        exitStart = CACurrentMediaTime()
        let duration = SkeletonAssembly.duration
        let mask = CAShapeLayer()
        mask.name = SkeletonAssembly.maskName
        mask.frame = bounds
        mask.fillColor = NSColor.black.cgColor
        let start = SkeletonAssembly.clipRect(in: bounds, progress: 0, sketch: true)
        let end = SkeletonAssembly.clipRect(in: bounds, progress: 1, sketch: true)
        let scan = CABasicAnimation(keyPath: "path")
        scan.fromValue = CGPath(rect: start, transform: nil)
        scan.toValue = CGPath(rect: end, transform: nil)
        scan.duration = duration
        scan.timingFunction = RelayMotion.enterCurve.mediaTimingFunction

        let linger = CAKeyframeAnimation(keyPath: "opacity")
        linger.values = SkeletonAssembly.chromeOpacityStops.map { $0.opacity }
        linger.keyTimes = SkeletonAssembly.chromeOpacityStops.map { NSNumber(value: $0.progress) }
        linger.duration = duration
        linger.timingFunction = RelayMotion.enterCurve.mediaTimingFunction

        handoffGeneration &+= 1
        let generation = handoffGeneration
        handoffCompletion = completion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak mask] in
            // The host's completion removes this loader, so it must run once
            // the scan ends even if the mask was swapped meanwhile; only a
            // cancellation discards it.
            guard let self, self.handoffGeneration == generation else { return }
            if let mask, self.sketchLayer.mask === mask { self.sketchLayer.mask = nil }
            let completion = self.handoffCompletion
            self.handoffCompletion = nil
            completion?()
        }
        mask.path = CGPath(rect: end, transform: nil)
        sketchLayer.mask = mask
        mask.add(scan, forKey: Self.handoffKey)
        handleChromeLayer.opacity = 0
        handleChromeLayer.add(linger, forKey: Self.handoffKey)
        CATransaction.commit()
        if !isAnimating { renderCurrent(now: CACurrentMediaTime()) }
    }

    /// Keeps a reused loader whole, without running a stale completion.
    func cancelHandoff() {
        handoffGeneration &+= 1
        handoffCompletion = nil
        exitStart = nil
        handoffProgress = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isHandingOff { sketchLayer.mask = nil }
        handleChromeLayer.removeAnimation(forKey: Self.handoffKey)
        handleChromeLayer.opacity = 1
        CATransaction.commit()
        if !isAnimating { renderCurrent(now: CACurrentMediaTime()) }
    }

    /// SwiftUI drives the handoff frame by frame through its transition.
    func setHandoffProgress(_ progress: CGFloat?) {
        let changed = handoffProgress != progress
        handoffProgress = progress
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            if changed, !isAnimating { renderCurrent(now: CACurrentMediaTime()) }
        }
        guard let progress else {
            if isHandingOff { sketchLayer.mask = nil }
            handleChromeLayer.opacity = 1
            return
        }
        let mask = (sketchLayer.mask as? CAShapeLayer) ?? {
            let mask = CAShapeLayer()
            mask.name = SkeletonAssembly.maskName
            mask.fillColor = NSColor.black.cgColor
            sketchLayer.mask = mask
            return mask
        }()
        mask.frame = bounds
        mask.path = CGPath(rect: SkeletonAssembly.clipRect(in: bounds, progress: progress, sketch: true), transform: nil)
        handleChromeLayer.opacity = SkeletonAssembly.chromeOpacity(progress: progress)
    }

    /// Changes what VoiceOver announces.
    func setLabel(_ label: String) {
        setAccessibilityLabel(label)
    }

    // MARK: Layouts

    /// The surfaces behind the bones: the board's columns, the Notes
    /// library, or the Settings pane and its agent card. History sits on
    /// its own panel, so it needs none.
    static func panels(for layout: SkeletonLoaderLayout, in bounds: CGRect) -> [CGRect] {
        switch layout {
        case .board(let top):
            return boardPanels(columnTop: top, in: bounds)
        case .terminal:
            return []
        case .notes:
            return bounds.width > 0 && bounds.height > 0 ? [bounds] : []
        case .settings:
            let cardWidth = SettingsAgentCardLayout.width(availableWidth: bounds.width)
            let paneWidth = bounds.width - cardWidth - SettingsAgentCardLayout.spacing
            guard paneWidth > SettingsContentStyle.workspace.sidebarWidth + 1 + 160, bounds.height > 0 else { return [] }
            return [
                CGRect(x: bounds.minX, y: bounds.minY, width: paneWidth, height: bounds.height),
                CGRect(x: bounds.maxX - cardWidth, y: bounds.minY, width: cardWidth, height: bounds.height),
            ]
        case .history:
            return []
        }
    }

    private static func boardPanels(columnTop top: CGFloat, in bounds: CGRect) -> [CGRect] {
        let padding = BoardSurfaceLayout.horizontalPadding
        let spacing = BoardSurfaceLayout.columnSpacing
        let count = CGFloat(ProgramBoardLane.allCases.count + 1)
        let width = (bounds.width - padding * 2 - spacing * (count - 1)) / count
        let height = min(
            BoardSurfaceLayout.columnHeight,
            bounds.height - top - ProgramBoardBackdropStyle.bottomPadding
        )
        guard width > 0, height > 0 else { return [] }
        return (0..<Int(count)).map { index in
            CGRect(
                x: bounds.minX + padding + CGFloat(index) * (width + spacing),
                y: bounds.minY + top,
                width: width,
                height: height
            )
        }
    }

    static func bones(for layout: SkeletonLoaderLayout, in bounds: CGRect) -> [SkeletonBone] {
        switch layout {
        case .board:
            return boardBones(panels: panels(for: layout, in: bounds))
        case .terminal:
            return terminalBones(in: bounds)
        case .notes:
            return notesBones(in: bounds)
        case .settings:
            return settingsBones(panels: panels(for: layout, in: bounds))
        case .history:
            return historyBones(in: bounds)
        }
    }

    /// Card heights for each lane, so the lanes read as different lists.
    private static let laneCardHeights: [[CGFloat]] = [
        [88, 72, 96, 72, 88],
        [72, 88],
        [96, 72, 88],
        [72, 72, 88, 72, 96, 72],
    ]

    private static func boardBones(panels: [CGRect]) -> [SkeletonBone] {
        var bones: [SkeletonBone] = []
        for (index, panel) in panels.enumerated() {
            // The column header: a title and an action.
            let headerMidY = panel.minY + ProgramBoardLayout.panelVerticalPadding
                + ProgramBoardLayout.workHeaderHeight / 2
            let titleWidth = min(96, panel.width * 0.3)
            bones.append(SkeletonBone(
                rect: CGRect(x: panel.minX + 24, y: headerMidY - 6, width: titleWidth, height: 12),
                radius: 6,
                style: .fill
            ))
            bones.append(SkeletonBone(
                rect: CGRect(x: panel.maxX - 24 - 24, y: headerMidY - 12, width: 24, height: 24),
                radius: 8,
                style: .fill
            ))

            // The cards, stacked until the column ends.
            let overview = index == 0
            let heights = overview
                ? Array(repeating: ProgramBoardLayout.projectCardHeight, count: 4)
                : laneCardHeights[(index - 1) % laneCardHeights.count]
            let spacing: CGFloat = overview ? ProgramBoardLayout.projectCardSpacing : 6
            var y = overview
                ? headerMidY + ProgramBoardLayout.workHeaderHeight / 2 + ProgramBoardLayout.projectHeaderToListSpacing
                : panel.minY + ProgramBoardLayout.workCardTopOffset
            for height in heights {
                let card = CGRect(x: panel.minX + 8, y: y, width: panel.width - 16, height: height)
                guard card.maxY <= panel.maxY - 16 else { break }
                bones.append(SkeletonBone(rect: card, radius: 14, style: .outline))
                bones.append(contentsOf: cardLines(in: card, wide: overview))
                y = card.maxY + spacing
            }
        }
        return bones
    }

    /// A title line and a shorter detail line inside a card.
    private static func cardLines(in card: CGRect, wide: Bool) -> [SkeletonBone] {
        let inset: CGFloat = 16
        let available = card.width - inset * 2
        guard available > 24 else { return [] }
        return [
            SkeletonBone(
                rect: CGRect(x: card.minX + inset, y: card.minY + inset, width: available * (wide ? 0.55 : 0.7), height: 10),
                radius: 5,
                style: .fill
            ),
            SkeletonBone(
                rect: CGRect(x: card.minX + inset, y: card.minY + inset + 20, width: available * (wide ? 0.8 : 0.45), height: 8),
                radius: 4,
                style: .fill
            ),
        ]
    }

    private static func terminalBones(in bounds: CGRect) -> [SkeletonBone] {
        let inset: CGFloat = 20
        let contentWidth = bounds.width - inset * 2
        guard contentWidth > 80, bounds.height > inset * 2 + 120 else { return [] }
        var bones: [SkeletonBone] = []

        // The provider's welcome box.
        let welcome = CGRect(x: bounds.minX + inset, y: bounds.minY + inset, width: min(contentWidth, 520), height: 112)
        bones.append(SkeletonBone(rect: welcome, radius: 10, style: .outline))
        for (offset, width, height) in [(26, 180, 12), (50, 280, 10), (70, 230, 10)] as [(CGFloat, CGFloat, CGFloat)] {
            bones.append(SkeletonBone(
                rect: CGRect(x: welcome.minX + 20, y: welcome.minY + offset, width: min(width, welcome.width - 40), height: height),
                radius: height / 2,
                style: .fill
            ))
        }

        // The prompt box, its footer, and the output lines above it.
        let footer = CGRect(x: bounds.minX + inset + 4, y: bounds.maxY - inset - 8, width: min(120, contentWidth), height: 8)
        let prompt = CGRect(x: bounds.minX + inset, y: footer.minY - 14 - 44, width: contentWidth, height: 44)
        let lineWidth = min(contentWidth, 640)
        var y = welcome.maxY + 24
        for fraction in [0.62, 0.48, 0.7, 0.36] as [CGFloat] {
            let line = CGRect(x: bounds.minX + inset, y: y, width: lineWidth * fraction, height: 10)
            guard line.maxY <= prompt.minY - 24 else { break }
            bones.append(SkeletonBone(rect: line, radius: 5, style: .fill))
            y += 22
        }
        guard prompt.minY > welcome.maxY + 24 else { return bones }
        bones.append(SkeletonBone(rect: prompt, radius: 10, style: .outline))
        bones.append(SkeletonBone(
            rect: CGRect(x: prompt.minX + 16, y: prompt.midY - 6, width: 10, height: 12),
            radius: 3,
            style: .fill
        ))
        bones.append(SkeletonBone(
            rect: CGRect(x: prompt.minX + 36, y: prompt.midY - 5, width: min(140, prompt.width - 52), height: 10),
            radius: 5,
            style: .fill
        ))
        bones.append(SkeletonBone(rect: footer, radius: 4, style: .fill))
        return bones
    }

    static let notesHeaderHeight: CGFloat = 60
    static let notesListWidth: CGFloat = 330
    private static let noteCardHeights: [CGFloat] = [84, 68, 84, 76, 68, 84, 76, 68]

    /// Mirrors the Notes library: a header with the note count, the list of
    /// notes under a search field, and the open note beside it.
    private static func notesBones(in bounds: CGRect) -> [SkeletonBone] {
        guard bounds.width > notesListWidth + 160, bounds.height > notesHeaderHeight + 120 else { return [] }
        var bones: [SkeletonBone] = []

        // The header's note count.
        bones.append(SkeletonBone(
            rect: CGRect(x: bounds.minX + 22, y: bounds.minY + notesHeaderHeight / 2 - 6, width: 96, height: 12),
            radius: 6,
            style: .fill
        ))

        // The search field and the notes under it.
        let bodyTop = bounds.minY + notesHeaderHeight + 1
        let list = CGRect(x: bounds.minX, y: bodyTop, width: notesListWidth, height: bounds.maxY - bodyTop)
            .insetBy(dx: 18, dy: 18)
        let search = CGRect(x: list.minX, y: list.minY, width: list.width, height: ProgramTicketPanelStyle.compactFieldHeight)
        bones.append(SkeletonBone(rect: search, radius: 8, style: .outline))
        var y = search.maxY + 12
        for height in noteCardHeights {
            let card = CGRect(x: list.minX, y: y, width: list.width, height: height)
            guard card.maxY <= list.maxY else { break }
            bones.append(SkeletonBone(rect: card, radius: 12, style: .outline))
            bones.append(contentsOf: cardLines(in: card, wide: false))
            y = card.maxY + 8
        }

        // The open note: a title, a byline, then its paragraphs.
        let detailMinX = bounds.minX + notesListWidth + 1 + 28
        let detailWidth = bounds.maxX - 28 - detailMinX
        let top = bodyTop + 28
        bones.append(SkeletonBone(
            rect: CGRect(x: detailMinX, y: top, width: min(320, detailWidth * 0.5), height: 16),
            radius: 8,
            style: .fill
        ))
        bones.append(SkeletonBone(
            rect: CGRect(x: detailMinX, y: top + 28, width: min(180, detailWidth * 0.3), height: 8),
            radius: 4,
            style: .fill
        ))
        y = top + 64
        for fraction in [0.92, 0.86, 0.9, 0.64, 0.88, 0.94, 0.8, 0.52] as [CGFloat] {
            let line = CGRect(x: detailMinX, y: y, width: min(detailWidth, 720) * fraction, height: 10)
            guard line.maxY <= bounds.maxY - 28 else { break }
            bones.append(SkeletonBone(rect: line, radius: 5, style: .fill))
            y += 20
        }
        return bones
    }

    static let historyListWidth: CGFloat = 330
    private static let historyCardHeights: [CGFloat] = [98, 82, 98, 98, 82]

    /// Mirrors Workspace History before a ticket is chosen: the search
    /// field, the archive policy and the archived tickets on the left, and
    /// the empty placeholder on the right.
    private static func historyBones(in bounds: CGRect) -> [SkeletonBone] {
        guard bounds.width > historyListWidth + 160, bounds.height > 240 else { return [] }
        var bones: [SkeletonBone] = []

        // The search field and its button.
        let list = CGRect(x: bounds.minX, y: bounds.minY, width: historyListWidth, height: bounds.height)
            .insetBy(dx: 18, dy: 18)
        let button = SharedActionButtonMetrics.controlHeight
        let field = ProgramTicketPanelStyle.compactFieldHeight
        let search = CGRect(x: list.minX, y: list.minY, width: list.width - 8 - button, height: field)
        bones.append(SkeletonBone(rect: search, radius: 8, style: .outline))
        bones.append(SkeletonBone(
            rect: CGRect(x: search.maxX + 8, y: search.midY - button / 2, width: button, height: button),
            radius: 8,
            style: .outline
        ))

        // The archive policy.
        var y = search.maxY + 12
        for fraction in [0.9, 0.94, 0.4] as [CGFloat] {
            bones.append(SkeletonBone(
                rect: CGRect(x: list.minX, y: y + 3, width: list.width * fraction, height: 8),
                radius: 4,
                style: .fill
            ))
            y += 15
        }

        // The archived tickets: an id and status, a title, then the badge.
        y += 12
        for height in historyCardHeights {
            let card = CGRect(x: list.minX, y: y, width: list.width, height: height)
            guard card.maxY <= list.maxY else { break }
            bones.append(SkeletonBone(rect: card, radius: BoardDarkSurfaceStyle.nestedCardCornerRadius, style: .outline))
            let inset: CGFloat = 12
            let available = card.width - inset * 2
            bones.append(SkeletonBone(
                rect: CGRect(x: card.minX + inset, y: card.minY + 14, width: 52, height: 8),
                radius: 4,
                style: .fill
            ))
            bones.append(SkeletonBone(
                rect: CGRect(x: card.maxX - inset - 36, y: card.minY + 14, width: 36, height: 8),
                radius: 4,
                style: .fill
            ))
            var lineY = card.minY + 34
            for fraction in (height >= 98 ? [0.85, 0.5] : [0.7]) as [CGFloat] {
                bones.append(SkeletonBone(
                    rect: CGRect(x: card.minX + inset, y: lineY, width: available * fraction, height: 10),
                    radius: 5,
                    style: .fill
                ))
                lineY += 18
            }
            bones.append(SkeletonBone(
                rect: CGRect(x: card.minX + inset, y: card.maxY - 22, width: available * 0.4, height: 8),
                radius: 4,
                style: .fill
            ))
            y = card.maxY + 8
        }

        // The placeholder: an icon over a title and a supporting line.
        let detail = CGRect(x: bounds.minX + historyListWidth + 1, y: bounds.minY, width: bounds.width - historyListWidth - 1, height: bounds.height)
        let top = detail.midY - (28 + 10 + 12 + 10 + 8) / 2
        bones.append(SkeletonBone(
            rect: CGRect(x: detail.midX - 14, y: top, width: 28, height: 28),
            radius: 14,
            style: .fill
        ))
        bones.append(SkeletonBone(
            rect: CGRect(x: detail.midX - 80, y: top + 38, width: 160, height: 12),
            radius: 6,
            style: .fill
        ))
        let subtitleWidth = min(260, detail.width - 56)
        bones.append(SkeletonBone(
            rect: CGRect(x: detail.midX - subtitleWidth / 2, y: top + 60, width: subtitleWidth, height: 8),
            radius: 4,
            style: .fill
        ))
        return bones
    }

    static let settingsFooterHeight: CGFloat = 54

    /// Mirrors the Settings tab: the category sidebar, a column of settings
    /// with their controls above the footer, and the agent card.
    private static func settingsBones(panels: [CGRect]) -> [SkeletonBone] {
        guard panels.count == 2 else { return [] }
        let pane = panels[0]
        let card = panels[1]
        let style = SettingsContentStyle.workspace
        var bones: [SkeletonBone] = []

        // The sidebar's heading and categories.
        bones.append(SkeletonBone(
            rect: CGRect(x: pane.minX + 16, y: pane.minY + 22, width: 72, height: 14),
            radius: 7,
            style: .fill
        ))
        let rowWidth = style.sidebarWidth - 20
        for index in 0..<SettingsCategory.allCases.count {
            let row = CGRect(
                x: pane.minX + 10,
                y: pane.minY + 78 + CGFloat(index) * (SettingsLayout.sidebarRowHeight + 4),
                width: rowWidth,
                height: SettingsLayout.sidebarRowHeight
            )
            guard row.maxY <= pane.maxY - 16 else { break }
            bones.append(SkeletonBone(
                rect: CGRect(x: row.minX + 10, y: row.midY - 6, width: 12, height: 12),
                radius: 3,
                style: .fill
            ))
            bones.append(SkeletonBone(
                rect: CGRect(x: row.minX + 32, y: row.midY - 5, width: rowWidth * (index.isMultiple(of: 2) ? 0.55 : 0.45), height: 10),
                radius: 5,
                style: .fill
            ))
        }

        // The settings: section titles, each over rows of a label and a control.
        let detailMinX = pane.minX + style.sidebarWidth + 1
        let columnWidth = min(style.detailMaxWidth, pane.maxX - detailMinX)
        let contentMinX = detailMinX + style.detailPadding.leading
        let contentWidth = columnWidth - style.detailPadding.leading - style.detailPadding.trailing
        let footerTop = pane.maxY - settingsFooterHeight
        let controlWidth = min(160, contentWidth * 0.3)
        let rowHeight = SharedActionButtonMetrics.controlHeight + SettingsLayout.rowVerticalPadding * 2
        var y = pane.minY + style.detailPadding.top
        sections: for rowCount in [3, 2, 3] {
            let title = CGRect(x: contentMinX, y: y, width: 120, height: 12)
            guard title.maxY + SettingsLayout.sectionTitleSpacing + rowHeight <= footerTop - style.detailPadding.bottom else { break }
            bones.append(SkeletonBone(rect: title, radius: 6, style: .fill))
            y = title.maxY + SettingsLayout.sectionTitleSpacing
            for row in 0..<rowCount {
                guard y + rowHeight <= footerTop - style.detailPadding.bottom else { break sections }
                let midY = y + rowHeight / 2
                bones.append(SkeletonBone(
                    rect: CGRect(x: contentMinX, y: midY - 5, width: min(220, contentWidth * (row.isMultiple(of: 2) ? 0.4 : 0.3)), height: 10),
                    radius: 5,
                    style: .fill
                ))
                bones.append(SkeletonBone(
                    rect: CGRect(
                        x: contentMinX + contentWidth - controlWidth,
                        y: midY - SharedActionButtonMetrics.controlHeight / 2,
                        width: controlWidth,
                        height: SharedActionButtonMetrics.controlHeight
                    ),
                    radius: 6,
                    style: .outline
                ))
                y += rowHeight
            }
            y += SettingsLayout.sectionSpacing
        }

        // The footer: a status on the left and an action on the right.
        let footerMidY = footerTop + settingsFooterHeight / 2
        let footerMinX = detailMinX + style.footerPadding.leading
        let footerMaxX = pane.maxX - style.footerPadding.trailing
        bones.append(SkeletonBone(
            rect: CGRect(x: footerMinX, y: footerMidY - 5, width: 10, height: 10),
            radius: 5,
            style: .fill
        ))
        bones.append(SkeletonBone(
            rect: CGRect(x: footerMinX + 18, y: footerMidY - 4, width: min(160, (footerMaxX - footerMinX) * 0.4), height: 8),
            radius: 4,
            style: .fill
        ))
        bones.append(SkeletonBone(
            rect: CGRect(x: footerMaxX - 72, y: footerMidY - SharedActionButtonMetrics.controlHeight / 2, width: 72, height: SharedActionButtonMetrics.controlHeight),
            radius: 6,
            style: .outline
        ))

        // The agent card's name and subtitle.
        let nameWidth = min(160, card.width * 0.6)
        bones.append(SkeletonBone(
            rect: CGRect(x: card.midX - nameWidth / 2, y: card.minY + 64, width: nameWidth, height: 18),
            radius: 9,
            style: .fill
        ))
        let subtitleWidth = min(120, card.width * 0.45)
        bones.append(SkeletonBone(
            rect: CGRect(x: card.midX - subtitleWidth / 2, y: card.minY + 64 + 18 + 12, width: subtitleWidth, height: 10),
            radius: 5,
            style: .fill
        ))
        return bones
    }
}

/// The skeleton loader for SwiftUI screens.
struct SkeletonLoader: NSViewRepresentable {
    let layout: SkeletonLoaderLayout
    let label: String

    func makeNSView(context: Context) -> SkeletonLoaderView {
        SkeletonLoaderView(layout: layout, label: label)
    }

    func updateNSView(_ view: SkeletonLoaderView, context: Context) {
        view.setLabel(label)
        view.setHandoffProgress(context.environment.skeletonHandoffProgress)
    }
}
