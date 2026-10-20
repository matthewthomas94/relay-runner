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

/// The construction timeline of one annotated surface, in seconds after the
/// surface's own start. Scattered dots converge on the contour while it grows
/// from a small dotted square into place; a cursor dot then walks the contour
/// counting dots placed, and the contents inside sketch in last.
enum SkeletonConstruction {
    /// Start-to-end ratio of the growing contour. No overshoot.
    static let startScale: CGFloat = 0.42
    static let scatterDuration: TimeInterval = 0.3
    static let scatterJitter: CGFloat = 10
    static let scatterSpacing: CGFloat = 15
    static let outlineDelay: TimeInterval = 0.1
    static let growDuration: TimeInterval = 0.4
    /// The contour grows on a plain ease-out. The kit's enter curve settles in
    /// the first fifth of its duration, which hides the growth at any frame rate.
    static let growCurve = RelayMotion.Curve(x1: 0.2, y1: 0, x2: 0.2, y2: 1)
    static let cursorDelay: TimeInterval = 0.3
    static let cursorDuration: TimeInterval = 0.36
    static let readoutDuration: TimeInterval = 0.9
    static let innerDelay: TimeInterval = 0.42
    static let chromeArrival: TimeInterval = 0.2

    /// Resting (fully constructed) chrome opacities.
    static let handleOpacity: Float = 0.55
    static let guideOpacity: Float = 0.14
    static let readoutOpacity: Float = 0.62
    static let bracketOpacity: Float = 0.4
    static let gridOpacity: Float = 0.08
    static let gridConstructionOpacity: Float = 0.22

    /// Width a contour needs before it earns design-tool chrome.
    static let annotatedMinimumWidth: CGFloat = 200
    static let annotatedMinimumHeight: CGFloat = 40
    static let annotatedLimit = 3

    /// How long one loader takes to finish constructing after it appears.
    static var duration: TimeInterval {
        0.04 + SkeletonLoaderView.traceStagger + innerDelay
            + SkeletonLoaderView.traceDuration + SkeletonLoaderView.traceStagger
    }

    static func readout(width: CGFloat, height: CGFloat, time: TimeInterval) -> String {
        String(format: "%d × %d  t+%.2fs", Int(width.rounded()), Int(height.rounded()), time)
    }

    static func counter(placed: Int, total: Int) -> String {
        String(format: "%03d·%03d", placed, total)
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

/// A dot-matrix sketch of the incoming screen, constructed the way a design
/// tool draws a layout: dots scatter and converge on each surface's contour,
/// the contour grows into place between corner handles and dotted guides, a
/// monospace readout and dot counter annotate it, and the contents trace in.
/// A quiet sweep keeps longer waits alive. The host owns the transition to
/// real content; this drawing never delays readiness. Core Animation runs
/// the motion without per-frame main-thread work.
final class SkeletonLoaderView: NSView {
    static let dotSpacing: CGFloat = 5
    static let fieldSpacing: CGFloat = 16
    static let traceDuration: TimeInterval = 0.36
    static let traceStagger: TimeInterval = 0.18
    static let traceKey = "skeletonTrace"
    static let arrivalKey = "skeletonArrival"
    static let sweepKey = "skeletonSweep"
    static let handoffKey = "skeletonHandoff"
    private static let restingLocations: [NSNumber] = [0, 0, 0, 0, 1]

    let skeleton: SkeletonLoaderLayout

    /// Everything the ready UI replaces along the scan edge.
    private let sketchLayer = CALayer()
    private let panelsLayer = CAShapeLayer()
    private let fieldLayer = CAShapeLayer()
    private let scatterLayer = CALayer()
    private let bonesGradient = CAGradientLayer()
    private let bonesMask = CALayer()
    private let guideChromeLayer = CALayer()
    /// Handles, readouts, counters and cursors outlive the scan and fade last.
    private let handleChromeLayer = CALayer()
    private var strokes: [CAShapeLayer] = []
    private var drawing: [SkeletonBone] = []
    private var annotations: [Annotation] = []
    private var drawnBounds: CGRect?
    private var animating = false

    private(set) var bones: [SkeletonBone] = []

    /// The design-tool chrome around one annotated surface.
    private struct Annotation {
        let rect: CGRect
        let strokeIndex: Int
        let total: Int
        let scatter: CAShapeLayer
        let scatterStart: CGPath
        let handles: CAShapeLayer
        let guides: CAShapeLayer
        let grid: CAShapeLayer
        let brackets: CAShapeLayer
        let readout: CATextLayer
        let counter: CATextLayer
        let cursor: CAShapeLayer
        let cursorPath: CGPath
    }

    override var isFlipped: Bool { true }

    init(layout: SkeletonLoaderLayout, label: String) {
        self.skeleton = layout
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(sketchLayer)

        panelsLayer.fillColor = BoardDarkSurfaceStyle.panelFillNSColor.cgColor
        sketchLayer.addSublayer(panelsLayer)

        let ink = SettingsSurfaceColor.mutedTextNSColor
        fieldLayer.fillColor = ink.withAlphaComponent(0.10).cgColor
        sketchLayer.addSublayer(fieldLayer)
        sketchLayer.addSublayer(guideChromeLayer)
        sketchLayer.addSublayer(scatterLayer)
        bonesGradient.colors = [
            ink.withAlphaComponent(0.32).cgColor,
            ink.withAlphaComponent(0.32).cgColor,
            ink.withAlphaComponent(0.72).cgColor,
            ink.withAlphaComponent(0.32).cgColor,
            ink.withAlphaComponent(0.32).cgColor,
        ]
        bonesGradient.startPoint = CGPoint(x: 0, y: 0)
        bonesGradient.endPoint = CGPoint(x: 1, y: 1)
        bonesGradient.locations = Self.restingLocations
        bonesGradient.mask = bonesMask
        sketchLayer.addSublayer(bonesGradient)
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
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// The surfaces that carry handles, guides, a readout and a dot counter.
    var annotatedRects: [CGRect] { annotations.map(\.rect) }

    /// Whether the ready UI is currently replacing this sketch.
    var isHandingOff: Bool { sketchLayer.mask?.name == SkeletonAssembly.maskName }

    override func layout() {
        super.layout()
        guard drawnBounds != bounds else { refreshAnimation(); return }
        drawnBounds = bounds
        bones = Self.bones(for: skeleton, in: bounds)
        let scale = window?.backingScaleFactor ?? 2
        let ink = SettingsSurfaceColor.mutedTextNSColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let surfaces = Self.panels(for: skeleton, in: bounds)
        let panels = CGMutablePath()
        for panel in surfaces {
            panels.addRoundedRect(in: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 16, cornerHeight: 16)
        }
        for container in [sketchLayer, panelsLayer, fieldLayer, scatterLayer, bonesGradient, bonesMask,
                          guideChromeLayer, handleChromeLayer] {
            container.frame = bounds
        }
        panelsLayer.path = panels
        fieldLayer.path = Self.fieldPath(in: bounds)
        drawing = surfaces.map { SkeletonBone(rect: $0, radius: 16, style: .outline) } + bones
        while strokes.count > drawing.count { strokes.removeLast().removeFromSuperlayer() }
        for (index, bone) in drawing.enumerated() {
            if index == strokes.count {
                let stroke = CAShapeLayer()
                stroke.fillColor = nil
                stroke.strokeColor = NSColor.black.cgColor
                stroke.lineWidth = 1.8
                stroke.lineCap = .round
                stroke.lineJoin = .round
                stroke.lineDashPattern = [0.01, NSNumber(value: Double(Self.dotSpacing - 0.01))]
                bonesMask.addSublayer(stroke)
                strokes.append(stroke)
            }
            // Local coordinates let a contour grow about its own centre.
            let stroke = strokes[index]
            let path = Self.wirePath(for: bone)
            let box = path.boundingBoxOfPath.isNull ? bone.rect : path.boundingBoxOfPath
            stroke.bounds = CGRect(origin: .zero, size: box.size)
            stroke.position = CGPoint(x: box.midX, y: box.midY)
            stroke.transform = CATransform3DIdentity
            stroke.contentsScale = scale
            var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            stroke.path = path.copy(using: &shift)
            stroke.opacity = index < surfaces.count ? 0.45 : (bone.style == .outline ? 0.7 : 1)
        }

        scatterLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guideChromeLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        handleChromeLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        annotations = SkeletonConstruction.annotatedRects(surfaces: surfaces, bones: bones).compactMap { rect in
            guard let strokeIndex = drawing.firstIndex(where: { $0.rect == rect }) else { return nil }
            return makeAnnotation(for: rect, radius: drawing[strokeIndex].radius, strokeIndex: strokeIndex,
                                  ink: ink, scale: scale)
        }
        CATransaction.commit()
        refreshAnimation()
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

    // MARK: Chrome

    private func makeAnnotation(
        for rect: CGRect, radius: CGFloat, strokeIndex: Int, ink: NSColor, scale: CGFloat
    ) -> Annotation {
        let inked = ink.cgColor
        func shape(_ parent: CALayer, fill: Bool, lineWidth: CGFloat = 1, dash: [NSNumber]? = nil) -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.frame = bounds
            shape.contentsScale = scale
            shape.fillColor = fill ? inked : nil
            shape.strokeColor = fill ? nil : inked
            shape.lineWidth = lineWidth
            shape.lineCap = .round
            shape.lineDashPattern = dash
            parent.addSublayer(shape)
            return shape
        }
        func label(_ text: String, origin: CGPoint) -> CATextLayer {
            let label = CATextLayer()
            label.contentsScale = scale
            label.font = AppTypography.terminalGridFont(size: 9, weight: .medium)
            label.fontSize = 9
            label.foregroundColor = inked
            label.alignmentMode = .left
            label.truncationMode = .none
            label.isWrapped = false
            label.string = text
            label.frame = CGRect(origin: origin, size: CGSize(width: max(40, rect.width), height: 12))
            label.opacity = SkeletonConstruction.readoutOpacity
            handleChromeLayer.addSublayer(label)
            return label
        }

        let contour = rect.insetBy(dx: 1, dy: 1)
        let contourRadius = max(0, radius - 1)
        let points = Self.perimeterPoints(of: contour, radius: contourRadius, spacing: SkeletonConstruction.scatterSpacing)
        let scatter = shape(scatterLayer, fill: true)
        scatter.path = Self.dots(at: points, radius: 1.3)
        scatter.opacity = 0
        let scatterStart = Self.dots(at: Self.scattered(points, seed: strokeIndex), radius: 1.3)

        let handles = shape(handleChromeLayer, fill: true)
        handles.path = Self.handlesPath(around: rect)
        handles.opacity = SkeletonConstruction.handleOpacity

        let guides = shape(guideChromeLayer, fill: false, dash: [1, 3])
        guides.path = Self.guidesPath(around: rect, in: bounds)
        guides.opacity = SkeletonConstruction.guideOpacity

        let inner = rect.insetBy(dx: 10, dy: 10)
        let grid = shape(guideChromeLayer, fill: true)
        grid.path = Self.innerGridPath(in: inner)
        grid.opacity = SkeletonConstruction.gridOpacity

        let brackets = shape(guideChromeLayer, fill: false)
        brackets.path = Self.bracketsPath(around: inner)
        brackets.opacity = SkeletonConstruction.bracketOpacity

        let total = Int((Self.perimeter(of: contour, radius: contourRadius) / Self.dotSpacing).rounded())
        let readoutAbove = rect.minY - bounds.minY >= 16
        let readout = label(
            SkeletonConstruction.readout(width: rect.width, height: rect.height,
                                         time: SkeletonConstruction.readoutDuration),
            origin: readoutAbove ? CGPoint(x: rect.minX, y: rect.minY - 15) : CGPoint(x: rect.minX + 10, y: rect.minY + 8)
        )
        let counterBelow = bounds.maxY - rect.maxY >= 16
        let counter = label(
            SkeletonConstruction.counter(placed: total, total: total),
            origin: counterBelow ? CGPoint(x: rect.minX, y: rect.maxY + 3) : CGPoint(x: inner.minX + 12, y: inner.maxY - 13)
        )

        let cursor = shape(handleChromeLayer, fill: true)
        cursor.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
        cursor.path = CGPath(ellipseIn: cursor.bounds, transform: nil)
        cursor.position = points.first ?? CGPoint(x: contour.minX + contourRadius, y: contour.minY)
        cursor.opacity = 0
        let cursorPath = CGMutablePath()
        cursorPath.addRoundedRect(in: contour, cornerWidth: contourRadius, cornerHeight: contourRadius)

        return Annotation(
            rect: rect, strokeIndex: strokeIndex, total: total, scatter: scatter, scatterStart: scatterStart,
            handles: handles, guides: guides, grid: grid, brackets: brackets, readout: readout,
            counter: counter, cursor: cursor, cursorPath: cursorPath
        )
    }

    private func annotation(containing bone: SkeletonBone) -> Annotation? {
        annotations.first { $0.rect != bone.rect && $0.rect.contains(bone.rect) }
    }

    // MARK: Motion

    /// Hidden loaders and Reduce Motion keep the completed sketch, without
    /// running animations. A geometry/layout pass must not restart the trace.
    func updateAnimation(visible: Bool, reduceMotion: Bool) {
        let active = visible && !reduceMotion && !bones.isEmpty
        guard active != animating else { return }
        animating = active
        guard active else {
            fieldLayer.removeAllAnimations()
            bonesGradient.removeAllAnimations()
            strokes.forEach { $0.removeAllAnimations() }
            for annotation in annotations {
                [annotation.scatter, annotation.handles, annotation.guides, annotation.grid, annotation.brackets,
                 annotation.readout, annotation.counter, annotation.cursor].forEach { $0.removeAllAnimations() }
            }
            return
        }

        let enter = RelayMotion.enterCurve.mediaTimingFunction
        let fieldArrival = CABasicAnimation(keyPath: "opacity")
        fieldArrival.fromValue = 0
        fieldArrival.toValue = 1
        fieldArrival.duration = RelayMotion.enterDuration
        fieldArrival.timingFunction = enter
        fieldLayer.add(fieldArrival, forKey: Self.traceKey)

        let now = CACurrentMediaTime()
        func start(of rect: CGRect) -> TimeInterval {
            let fraction = max(0, min(1, (rect.minY - bounds.minY) / max(1, bounds.height)))
            return 0.04 + fraction * Self.traceStagger
        }
        func basic(_ keyPath: String, from: Any, to: Any, duration: TimeInterval, at time: TimeInterval,
                   on layer: CALayer) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.beginTime = layer.convertTime(now, from: nil) + time
            animation.fillMode = .backwards
            animation.timingFunction = enter
            return animation
        }
        func keyframes(_ keyPath: String, values: [Any], keyTimes: [NSNumber], duration: TimeInterval,
                       at time: TimeInterval, on layer: CALayer, discrete: Bool = false) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = keyTimes
            animation.duration = duration
            animation.beginTime = layer.convertTime(now, from: nil) + time
            animation.fillMode = .backwards
            animation.calculationMode = discrete ? .discrete : .linear
            animation.timingFunction = discrete ? nil : enter
            return animation
        }

        for annotation in annotations {
            let t0 = start(of: annotation.rect)
            let stroke = strokes[annotation.strokeIndex]
            // The path grows rather than the layer, so the dots keep their
            // spacing and fill in along the contour as it reaches full size.
            let grow = basic("path", from: Self.contourStart(for: stroke), to: stroke.path as Any,
                             duration: SkeletonConstruction.growDuration,
                             at: t0 + SkeletonConstruction.outlineDelay, on: stroke)
            grow.timingFunction = SkeletonConstruction.growCurve.mediaTimingFunction
            stroke.add(grow, forKey: Self.traceKey)
            stroke.add(basic("opacity", from: 0, to: stroke.opacity, duration: 0.1,
                             at: t0 + SkeletonConstruction.outlineDelay, on: stroke), forKey: Self.arrivalKey)

            let scatter = annotation.scatter
            scatter.add(basic("path", from: annotation.scatterStart, to: scatter.path as Any,
                              duration: SkeletonConstruction.scatterDuration, at: t0, on: scatter), forKey: Self.traceKey)
            scatter.add(keyframes("opacity", values: [0, 0.55, 0.55, 0], keyTimes: [0, 0.1, 0.5, 1],
                                  duration: SkeletonConstruction.outlineDelay + SkeletonConstruction.growDuration,
                                  at: t0, on: scatter), forKey: Self.arrivalKey)

            for chrome in [annotation.handles, annotation.guides, annotation.brackets] as [CALayer] {
                chrome.add(basic("opacity", from: 0, to: chrome.opacity, duration: SkeletonConstruction.chromeArrival,
                                 at: t0 + 0.05, on: chrome), forKey: Self.arrivalKey)
            }
            // Guides sit bolder while the contour settles between them.
            annotation.guides.add(keyframes(
                "opacity", values: [0, 0.3, 0.3, SkeletonConstruction.guideOpacity], keyTimes: [0, 0.25, 0.6, 1],
                duration: SkeletonConstruction.innerDelay + 0.2, at: t0 + 0.05, on: annotation.guides
            ), forKey: Self.arrivalKey)
            // The inner grid fills bold while contents are placed, then recedes.
            let gridSpan = SkeletonConstruction.innerDelay + Self.traceDuration
            annotation.grid.add(keyframes(
                "opacity",
                values: [0, SkeletonConstruction.gridConstructionOpacity, SkeletonConstruction.gridConstructionOpacity,
                         SkeletonConstruction.gridOpacity],
                keyTimes: [0, NSNumber(value: 0.15 / gridSpan), NSNumber(value: SkeletonConstruction.innerDelay / gridSpan), 1],
                duration: gridSpan, at: t0 + 0.15, on: annotation.grid
            ), forKey: Self.arrivalKey)

            // The readout clock runs while this surface is under construction.
            let ticks = 22
            annotation.readout.add(keyframes(
                "string",
                values: (0...ticks).map {
                    SkeletonConstruction.readout(
                        width: annotation.rect.width, height: annotation.rect.height,
                        time: SkeletonConstruction.readoutDuration * Double($0) / Double(ticks)
                    )
                },
                keyTimes: (0...ticks).map { NSNumber(value: Double($0) / Double(ticks)) },
                duration: SkeletonConstruction.readoutDuration, at: t0, on: annotation.readout, discrete: true
            ), forKey: Self.traceKey)
            annotation.readout.add(basic("opacity", from: 0, to: annotation.readout.opacity,
                                         duration: SkeletonConstruction.chromeArrival, at: t0, on: annotation.readout),
                                   forKey: Self.arrivalKey)

            // The cursor walks the contour once, placing and counting dots.
            let cursorAt = t0 + SkeletonConstruction.cursorDelay
            let steps = 16
            annotation.counter.add(keyframes(
                "string",
                values: (0...steps).map {
                    SkeletonConstruction.counter(placed: annotation.total * $0 / steps, total: annotation.total)
                },
                keyTimes: (0...steps).map { NSNumber(value: Double($0) / Double(steps)) },
                duration: SkeletonConstruction.cursorDuration, at: cursorAt, on: annotation.counter, discrete: true
            ), forKey: Self.traceKey)
            annotation.counter.add(basic("opacity", from: 0, to: annotation.counter.opacity,
                                         duration: SkeletonConstruction.chromeArrival, at: cursorAt - 0.1,
                                         on: annotation.counter), forKey: Self.arrivalKey)
            let walk = CAKeyframeAnimation(keyPath: "position")
            walk.path = annotation.cursorPath
            walk.calculationMode = .paced
            walk.duration = SkeletonConstruction.cursorDuration
            walk.beginTime = annotation.cursor.convertTime(now, from: nil) + cursorAt
            walk.fillMode = .backwards
            walk.timingFunction = RelayMotion.changeCurve.mediaTimingFunction
            annotation.cursor.add(walk, forKey: Self.traceKey)
            annotation.cursor.add(keyframes("opacity", values: [0, 1, 1, 0], keyTimes: [0, 0.1, 0.85, 1],
                                            duration: SkeletonConstruction.cursorDuration + 0.12, at: cursorAt,
                                            on: annotation.cursor), forKey: Self.arrivalKey)
        }

        let annotatedStrokes = Set(annotations.map(\.strokeIndex))
        for (index, bone) in drawing.enumerated() where !annotatedStrokes.contains(index) {
            let stroke = strokes[index]
            let time: TimeInterval
            if let parent = annotation(containing: bone) {
                let fraction = max(0, min(1, (bone.rect.minY - parent.rect.minY) / max(1, parent.rect.height)))
                time = start(of: parent.rect) + SkeletonConstruction.innerDelay + fraction * Self.traceStagger
            } else {
                time = start(of: bone.rect) + SkeletonConstruction.outlineDelay
            }
            let trace = basic("strokeEnd", from: 0, to: 1, duration: Self.traceDuration, at: time, on: stroke)
            stroke.add(trace, forKey: Self.traceKey)
        }

        let sweep = CAKeyframeAnimation(keyPath: "locations")
        // Keep every stop in 0...1, including while the band enters/leaves.
        // Out-of-range stops can make a masked gradient disappear on macOS.
        sweep.values = [Self.restingLocations, [0, 0, 0.15, 0.3, 1], [0, 0.7, 0.85, 1, 1], [0, 1, 1, 1, 1]]
        sweep.keyTimes = [0, 0.15, 0.85, 1]
        sweep.duration = 2.2
        sweep.timingFunction = RelayMotion.changeCurve.mediaTimingFunction
        let cycle = CAAnimationGroup()
        cycle.animations = [sweep]
        cycle.duration = sweep.duration + 0.9
        cycle.beginTime = bonesGradient.convertTime(now, from: nil) + SkeletonConstruction.duration
        cycle.repeatCount = .infinity
        bonesGradient.add(cycle, forKey: Self.sweepKey)
    }

    // MARK: Handoff

    /// The ready UI replaces the sketch along one scan edge; handles and
    /// readouts linger past the edge and fade last, as a design tool's chrome
    /// does once the layout resolves.
    func animateHandoff(reduceMotion: Bool = RelayLayerMotion.reduceMotion, completion: (() -> Void)? = nil) {
        cancelHandoff()
        guard !reduceMotion else {
            completion?()
            return
        }
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

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak mask] in
            guard let self, let mask, self.sketchLayer.mask === mask else { return }
            self.sketchLayer.mask = nil
            completion?()
        }
        mask.path = CGPath(rect: end, transform: nil)
        sketchLayer.mask = mask
        mask.add(scan, forKey: Self.handoffKey)
        handleChromeLayer.opacity = 0
        handleChromeLayer.add(linger, forKey: Self.handoffKey)
        CATransaction.commit()
    }

    /// Keeps a reused loader whole, without running a stale completion.
    func cancelHandoff() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isHandingOff { sketchLayer.mask = nil }
        handleChromeLayer.removeAnimation(forKey: Self.handoffKey)
        handleChromeLayer.opacity = 1
        CATransaction.commit()
    }

    /// SwiftUI drives the handoff frame by frame through its transition.
    func setHandoffProgress(_ progress: CGFloat?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
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

    // MARK: Chrome geometry

    static func perimeter(of rect: CGRect, radius: CGFloat) -> CGFloat {
        let r = min(radius, rect.width / 2, rect.height / 2)
        return 2 * (rect.width - 2 * r) + 2 * (rect.height - 2 * r) + 2 * .pi * r
    }

    /// Points along a rounded contour, clockwise from the top-left corner's
    /// end, in the loader's flipped coordinates.
    static func perimeterPoints(of rect: CGRect, radius: CGFloat, spacing: CGFloat) -> [CGPoint] {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let w = rect.width - 2 * r
        let h = rect.height - 2 * r
        let arc = CGFloat.pi * r / 2
        let length = perimeter(of: rect, radius: r)
        guard length > 0, spacing > 0 else { return [] }
        let count = max(4, Int((length / spacing).rounded()))
        func point(at distance: CGFloat) -> CGPoint {
            var s = distance
            if s < w { return CGPoint(x: rect.minX + r + s, y: rect.minY) }
            s -= w
            if s < arc { return onArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), r, from: -.pi / 2, s) }
            s -= arc
            if s < h { return CGPoint(x: rect.maxX, y: rect.minY + r + s) }
            s -= h
            if s < arc { return onArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), r, from: 0, s) }
            s -= arc
            if s < w { return CGPoint(x: rect.maxX - r - s, y: rect.maxY) }
            s -= w
            if s < arc { return onArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), r, from: .pi / 2, s) }
            s -= arc
            if s < h { return CGPoint(x: rect.minX, y: rect.maxY - r - s) }
            s -= h
            return onArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), r, from: .pi, min(s, arc))
        }
        return (0..<count).map { point(at: length * CGFloat($0) / CGFloat(count)) }
    }

    private static func onArc(center: CGPoint, _ r: CGFloat, from angle: CGFloat, _ distance: CGFloat) -> CGPoint {
        let theta = angle + (r > 0 ? distance / r : 0)
        return CGPoint(x: center.x + r * cos(theta), y: center.y + r * sin(theta))
    }

    /// Deterministic jitter so a loader re-sketches the same way each time.
    static func scattered(_ points: [CGPoint], seed: Int) -> [CGPoint] {
        points.enumerated().map { index, point in
            CGPoint(x: point.x + jitter(index * 2, seed: seed), y: point.y + jitter(index * 2 + 1, seed: seed))
        }
    }

    private static func jitter(_ index: Int, seed: Int) -> CGFloat {
        var hash = UInt32(truncatingIfNeeded: index &* 73_856_093) ^ UInt32(truncatingIfNeeded: seed &* 19_349_663)
        hash ^= hash >> 13
        hash = hash &* 0x5bd1_e995
        hash ^= hash >> 15
        return (CGFloat(hash % 1_000) / 1_000 - 0.5) * 2 * SkeletonConstruction.scatterJitter
    }

    static func dots(at points: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for point in points {
            path.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        return path
    }

    /// Square handles centred on the bounding-box corners.
    static func handlesPath(around rect: CGRect, size: CGFloat = 3) -> CGPath {
        let path = CGMutablePath()
        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            path.addRect(CGRect(x: corner.x - size / 2, y: corner.y - size / 2, width: size, height: size))
        }
        return path
    }

    /// Dotted guides extend each edge to the page, leaving the contour clear.
    static func guidesPath(around rect: CGRect, in bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        let gap: CGFloat = 6
        for y in [rect.minY, rect.maxY] {
            if rect.minX - gap > bounds.minX {
                path.move(to: CGPoint(x: bounds.minX, y: y))
                path.addLine(to: CGPoint(x: rect.minX - gap, y: y))
            }
            if rect.maxX + gap < bounds.maxX {
                path.move(to: CGPoint(x: rect.maxX + gap, y: y))
                path.addLine(to: CGPoint(x: bounds.maxX, y: y))
            }
        }
        for x in [rect.minX, rect.maxX] {
            if rect.minY - gap > bounds.minY {
                path.move(to: CGPoint(x: x, y: bounds.minY))
                path.addLine(to: CGPoint(x: x, y: rect.minY - gap))
            }
            if rect.maxY + gap < bounds.maxY {
                path.move(to: CGPoint(x: x, y: rect.maxY + gap))
                path.addLine(to: CGPoint(x: x, y: bounds.maxY))
            }
        }
        return path
    }

    /// A second dot grid, offset half a step from the field, doubles the dot
    /// density inside the surface under construction.
    static func innerGridPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let spacing = fieldSpacing
        guard rect.width > spacing, rect.height > spacing else { return path }
        var y = rect.minY + spacing / 2
        while y <= rect.maxY - spacing / 4 {
            var x = rect.minX + spacing / 2
            while x <= rect.maxX - spacing / 4 {
                path.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                x += spacing
            }
            y += spacing
        }
        return path
    }

    /// Crop marks bracket the content area inside the contour.
    static func bracketsPath(around rect: CGRect, arm: CGFloat = 6) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > arm * 2, rect.height > arm * 2 else { return path }
        for (corner, dx, dy) in [
            (CGPoint(x: rect.minX, y: rect.minY), arm, arm), (CGPoint(x: rect.maxX, y: rect.minY), -arm, arm),
            (CGPoint(x: rect.minX, y: rect.maxY), arm, -arm), (CGPoint(x: rect.maxX, y: rect.maxY), -arm, -arm),
        ] {
            path.move(to: CGPoint(x: corner.x + dx, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy))
        }
        return path
    }

    // MARK: Geometry

    /// Text becomes a dotted baseline; icons and containers keep their contour.
    /// The contour's resting path scaled about the centre of its layer.
    static func contourStart(for stroke: CAShapeLayer) -> CGPath {
        guard let path = stroke.path else { return CGMutablePath() }
        let centre = CGPoint(x: stroke.bounds.midX, y: stroke.bounds.midY)
        var transform = CGAffineTransform(translationX: centre.x, y: centre.y)
            .scaledBy(x: SkeletonConstruction.startScale, y: SkeletonConstruction.startScale)
            .translatedBy(x: -centre.x, y: -centre.y)
        return path.copy(using: &transform) ?? path
    }

    static func wirePath(for bone: SkeletonBone) -> CGPath {
        let path = CGMutablePath()
        let rect = bone.rect.insetBy(dx: 1, dy: 1)
        guard rect.width > 0, rect.height > 0 else { return path }
        if bone.style == .fill && bone.rect.width > bone.rect.height * 2 {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        } else if bone.style == .fill && bone.rect.width <= dotSpacing * 2 {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        } else {
            let radius = max(0, bone.radius - 1)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }

    static func fieldPath(in bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        guard bounds.width > 0, bounds.height > 0 else { return path }
        let inset = Self.fieldSpacing / 2
        for y in stride(from: bounds.minY + inset, through: bounds.maxY - inset, by: Self.fieldSpacing) {
            for x in stride(from: bounds.minX + inset, through: bounds.maxX - inset, by: Self.fieldSpacing) {
                path.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
            }
        }
        return path
    }

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
