import AppKit
import XCTest
@testable import relay_runner

final class SkeletonLoaderTests: XCTestCase {
    private let boardTop = BoardSurfaceLayout.columnTopPadding - 34

    func testBoardSkeletonSketchesTheOverviewAndEachLane() {
        let bounds = CGRect(x: 0, y: 0, width: 1_400, height: 760)
        let panels = SkeletonLoaderView.panels(for: .board(columnTop: boardTop), in: bounds)
        XCTAssertEqual(panels.count, ProgramBoardLane.allCases.count + 1)
        XCTAssertEqual(panels.first?.minX, BoardSurfaceLayout.horizontalPadding)
        XCTAssertEqual(panels.last?.maxX ?? 0, bounds.width - BoardSurfaceLayout.horizontalPadding, accuracy: 0.001)
        XCTAssertEqual(panels[1].minX - panels[0].maxX, BoardSurfaceLayout.columnSpacing, accuracy: 0.001)
        for panel in panels {
            XCTAssertEqual(panel.minY, boardTop)
            XCTAssertLessThanOrEqual(panel.height, BoardSurfaceLayout.columnHeight)
            XCTAssertLessThanOrEqual(panel.maxY, bounds.maxY - ProgramBoardBackdropStyle.bottomPadding)
        }

        let bones = SkeletonLoaderView.bones(for: .board(columnTop: boardTop), in: bounds)
        for panel in panels {
            let cards = bones.filter { $0.style == .outline && panel.contains($0.rect) }
            XCTAssertFalse(cards.isEmpty, "Every column shows cards")
        }
        let overviewCards = bones.filter { $0.style == .outline && panels[0].contains($0.rect) }
        XCTAssertEqual(overviewCards.first?.rect.height, ProgramBoardLayout.projectCardHeight)
    }

    func testTerminalSkeletonSketchesAWelcomeOutputAndPrompt() throws {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 667)
        let bones = SkeletonLoaderView.bones(for: .terminal, in: bounds)
        XCTAssertTrue(SkeletonLoaderView.panels(for: .terminal, in: bounds).isEmpty)
        let outlines = bones.filter { $0.style == .outline }
        XCTAssertEqual(outlines.count, 2, "A welcome box and a prompt box")
        let welcome = try XCTUnwrap(outlines.min { $0.rect.minY < $1.rect.minY })
        let prompt = try XCTUnwrap(outlines.max { $0.rect.minY < $1.rect.minY })
        XCTAssertEqual(welcome.rect.minY, 20)
        XCTAssertGreaterThan(prompt.rect.minY, bounds.midY, "The prompt sits at the bottom")
        XCTAssertEqual(prompt.rect.width, bounds.width - 40)
        let output = bones.filter { $0.style == .fill && $0.rect.minY > welcome.rect.maxY && $0.rect.maxY < prompt.rect.minY }
        XCTAssertFalse(output.isEmpty, "Lines of output sit between them")
        for bone in bones {
            XCTAssertTrue(bounds.contains(bone.rect))
        }
    }

    func testNotesSkeletonSketchesTheListAndTheOpenNote() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1_400, height: 760)
        XCTAssertEqual(SkeletonLoaderView.panels(for: .notes, in: bounds), [bounds])
        let bones = SkeletonLoaderView.bones(for: .notes, in: bounds)
        let listEdge = SkeletonLoaderView.notesListWidth
        let outlines = bones.filter { $0.style == .outline }
        XCTAssertGreaterThan(outlines.count, 2, "A search field and several notes")
        for outline in outlines {
            XCTAssertLessThanOrEqual(outline.rect.maxX, listEdge, "The list keeps to the left")
            XCTAssertGreaterThan(outline.rect.minY, SkeletonLoaderView.notesHeaderHeight)
        }
        let search = try XCTUnwrap(outlines.min { $0.rect.minY < $1.rect.minY })
        XCTAssertEqual(search.rect.height, ProgramTicketPanelStyle.compactFieldHeight)
        let noteLines = bones.filter { $0.style == .fill && $0.rect.minX > listEdge }
        XCTAssertGreaterThan(noteLines.count, 3, "The open note shows a title and paragraphs")
        for bone in bones {
            XCTAssertTrue(bounds.contains(bone.rect), "\(bone.rect)")
        }
    }

    func testHistorySkeletonSketchesTheListAndThePlaceholder() throws {
        let bounds = CGRect(x: 0, y: 0, width: 940, height: 569)
        XCTAssertEqual(SkeletonLoaderView.panels(for: .history, in: bounds), [], "History brings its own panel")
        let bones = SkeletonLoaderView.bones(for: .history, in: bounds)
        let listEdge = SkeletonLoaderView.historyListWidth
        let outlines = bones.filter { $0.style == .outline }
        XCTAssertGreaterThan(outlines.count, 4, "A search field, its button and several tickets")
        for outline in outlines {
            XCTAssertLessThanOrEqual(outline.rect.maxX, listEdge, "The list keeps to the left")
        }
        let search = try XCTUnwrap(outlines.min { $0.rect.minY < $1.rect.minY })
        XCTAssertEqual(search.rect.height, ProgramTicketPanelStyle.compactFieldHeight)
        let placeholder = bones.filter { $0.rect.minX > listEdge }
        XCTAssertEqual(placeholder.count, 3, "An icon, a title and a supporting line")
        for bone in placeholder {
            XCTAssertEqual(bone.rect.midX, listEdge + 1 + (bounds.width - listEdge - 1) / 2, accuracy: 0.001)
        }
        for bone in bones {
            XCTAssertTrue(bounds.contains(bone.rect), "\(bone.rect)")
        }
    }

    func testSettingsSkeletonSketchesTheSidebarSettingsAndAgentCard() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1_400, height: 760)
        let panels = SkeletonLoaderView.panels(for: .settings, in: bounds)
        XCTAssertEqual(panels.count, 2, "The settings pane and the agent card")
        let pane = panels[0]
        let card = panels[1]
        XCTAssertEqual(card.width, SettingsAgentCardLayout.width(availableWidth: bounds.width))
        XCTAssertEqual(card.minX - pane.maxX, SettingsAgentCardLayout.spacing, accuracy: 0.001)
        XCTAssertEqual(card.maxX, bounds.maxX)

        let bones = SkeletonLoaderView.bones(for: .settings, in: bounds)
        let sidebarEdge = pane.minX + SettingsContentStyle.workspace.sidebarWidth
        let categoryIcons = bones.filter { $0.rect.maxX <= sidebarEdge && $0.rect.size == CGSize(width: 12, height: 12) }
        XCTAssertEqual(categoryIcons.count, SettingsCategory.allCases.count, "One row per category")
        let controls = bones.filter { $0.style == .outline && $0.rect.minX > sidebarEdge && pane.contains($0.rect) }
        XCTAssertGreaterThan(controls.count, 3, "Settings rows with their controls, and the footer action")
        for control in controls {
            XCTAssertEqual(control.rect.height, SharedActionButtonMetrics.controlHeight)
        }
        XCTAssertEqual(bones.filter { card.contains($0.rect) }.count, 2, "The agent's name and subtitle")
        for bone in bones {
            XCTAssertTrue(panels.contains { $0.contains(bone.rect) }, "\(bone.rect)")
        }
    }

    func testSkeletonsDrawOnlyConstructionChrome() throws {
        let readout = try NSRegularExpression(pattern: "^\\d+ × \\d+  t\\+\\d\\.\\d\\ds$")
        let counter = try NSRegularExpression(pattern: "^\\d{3}·\\d{3}$")
        for (layout, size) in [
            (SkeletonLoaderLayout.board(columnTop: boardTop), CGSize(width: 1_400, height: 760)),
            (.terminal, CGSize(width: 900, height: 420)),
            (.notes, CGSize(width: 1_400, height: 760)),
            (.settings, CGSize(width: 1_400, height: 760)),
            (.history, CGSize(width: 940, height: 569)),
        ] {
            let view = SkeletonLoaderView(layout: layout, label: BoardUpdateStatus.workingLabel)
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            XCTAssertFalse(view.bones.isEmpty, "\(layout)")
            XCTAssertTrue(view.subviews.isEmpty, "\(layout) has no label view")
            XCTAssertEqual(view.accessibilityLabel(), BoardUpdateStatus.workingLabel, "VoiceOver still hears the status")
            XCTAssertFalse(view.annotatedRects.isEmpty, "\(layout) annotates its main surfaces")
            let texts = textLayers(in: view.layer)
            XCTAssertEqual(texts.count, view.annotatedRects.count * 2, "\(layout): one readout and one counter per surface")
            for text in texts {
                let string = try XCTUnwrap(text.string as? String)
                let range = NSRange(string.startIndex..., in: string)
                XCTAssertTrue(readout.firstMatch(in: string, range: range) != nil
                              || counter.firstMatch(in: string, range: range) != nil,
                              "\(layout): \"\(string)\" is design-tool chrome, not copy")
                XCTAssertTrue(try XCTUnwrap(text.font as? NSFont).isFixedPitch, "\(layout): readouts are monospaced")
            }
        }
    }

    private func textLayers(in layer: CALayer?) -> [CATextLayer] {
        guard let layer else { return [] }
        var found = (layer as? CATextLayer).map { [$0] } ?? []
        for sublayer in layer.sublayers ?? [] { found += textLayers(in: sublayer) }
        return found + textLayers(in: layer.mask)
    }

    private func gradient(in layer: CALayer?) -> CAGradientLayer? {
        guard let layer else { return nil }
        if let gradient = layer as? CAGradientLayer { return gradient }
        for sublayer in layer.sublayers ?? [] {
            if let gradient = gradient(in: sublayer) { return gradient }
        }
        return nil
    }

    func testConstructionAnnotatesTheLargestTopLevelSurfaces() {
        let big = SkeletonBone(rect: CGRect(x: 0, y: 0, width: 600, height: 400), radius: 16, style: .outline)
        let nested = SkeletonBone(rect: CGRect(x: 20, y: 20, width: 300, height: 100), radius: 8, style: .outline)
        let text = SkeletonBone(rect: CGRect(x: 20, y: 500, width: 400, height: 12), radius: 6, style: .fill)
        let small = SkeletonBone(rect: CGRect(x: 700, y: 0, width: 120, height: 30), radius: 8, style: .outline)
        let second = SkeletonBone(rect: CGRect(x: 700, y: 100, width: 300, height: 200), radius: 16, style: .outline)
        let third = SkeletonBone(rect: CGRect(x: 700, y: 400, width: 260, height: 120), radius: 16, style: .outline)
        let fourth = SkeletonBone(rect: CGRect(x: 1_000, y: 400, width: 220, height: 60), radius: 16, style: .outline)
        let rects = SkeletonConstruction.annotatedRects(surfaces: [], bones: [fourth, text, small, nested, third, second, big])
        XCTAssertEqual(rects, [big.rect, second.rect, third.rect], "Top three by area, reading order, nothing nested")
        let panels = [CGRect(x: 0, y: 0, width: 500, height: 500), CGRect(x: 520, y: 0, width: 500, height: 500)]
        XCTAssertEqual(SkeletonConstruction.annotatedRects(surfaces: panels, bones: [big]), panels,
                       "Panels are the construction surfaces when a layout has them")
    }

    func testConstructionReadoutsAndDotCountsMatchTheLander() {
        XCTAssertEqual(SkeletonConstruction.readout(width: 320.4, height: 180, time: 0), "320 × 180  t+0.00s")
        XCTAssertEqual(SkeletonConstruction.readout(width: 1_024, height: 64, time: 0.5), "1024 × 64  t+0.50s")
        XCTAssertEqual(SkeletonConstruction.counter(placed: 22, total: 130), "022·130")
        XCTAssertEqual(SkeletonConstruction.counter(placed: 130, total: 130), "130·130")
        let rect = CGRect(x: 10, y: 10, width: 300, height: 120)
        let points = SkeletonLoaderView.perimeterPoints(of: rect, radius: 16, spacing: 15)
        XCTAssertGreaterThan(points.count, 20)
        XCTAssertEqual(SkeletonLoaderView.scattered(points, seed: 3).count, points.count,
                       "Every scattered dot converges onto exactly one contour dot")
        for point in points {
            XCTAssertTrue(rect.insetBy(dx: -1, dy: -1).contains(point), "\(point)")
        }
        XCTAssertNotEqual(SkeletonLoaderView.scattered(points, seed: 3), SkeletonLoaderView.scattered(points, seed: 4))
    }

    func testHandoffProgressScansTheSketchAndFadesChromeLast() throws {
        let view = SkeletonLoaderView(layout: .terminal, label: "Starting Claude")
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 667)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.isHandingOff)
        view.setHandoffProgress(0.5)
        XCTAssertTrue(view.isHandingOff)
        let chrome = try XCTUnwrap(view.layer?.sublayers?.last)
        XCTAssertEqual(chrome.opacity, 1, "Handles stay whole past the scan edge")
        view.setHandoffProgress(0.8)
        XCTAssertEqual(chrome.opacity, 0.5, accuracy: 0.001)
        view.setHandoffProgress(1)
        XCTAssertEqual(chrome.opacity, 0)
        view.setHandoffProgress(nil)
        XCTAssertFalse(view.isHandingOff, "A reused loader comes back whole")
        XCTAssertEqual(chrome.opacity, 1)

        view.animateHandoff(reduceMotion: false)
        XCTAssertTrue(view.isHandingOff)
        view.cancelHandoff()
        XCTAssertFalse(view.isHandingOff)
        XCTAssertEqual(chrome.opacity, 1)
        var completions = 0
        view.animateHandoff(reduceMotion: true) { completions += 1 }
        XCTAssertFalse(view.isHandingOff, "Reduce Motion skips the scan")
        XCTAssertEqual(completions, 1)
    }

    func testDotSketchTracesOnceWithoutTakingClicks() throws {
        let view = SkeletonLoaderView(layout: .terminal, label: "Starting Claude")
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 667)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.hitTest(CGPoint(x: 450, y: 333)))
        XCTAssertEqual(view.accessibilityLabel(), "Starting Claude")

        let gradient = try XCTUnwrap(gradient(in: view.layer))
        XCTAssertNil(gradient.animation(forKey: SkeletonLoaderView.sweepKey), "Detached loaders do no animation work")
        view.updateAnimation(visible: true, reduceMotion: false)
        let strokes = try XCTUnwrap(gradient.mask?.sublayers?.compactMap { $0 as? CAShapeLayer })
        XCTAssertEqual(strokes.count, view.bones.count)
        let traces = try strokes.map { try XCTUnwrap($0.animation(forKey: SkeletonLoaderView.traceKey) as? CABasicAnimation) }
        for trace in traces {
            XCTAssertTrue(["strokeEnd", "path"].contains(trace.keyPath ?? ""),
                          "Contours grow into place or trace along their path")
            XCTAssertEqual(trace.repeatCount, 0, "The drawing does not repeatedly empty and rebuild")
            XCTAssertLessThan(trace.duration, 0.6)
        }
        XCTAssertGreaterThan(try XCTUnwrap(traces.last).beginTime, try XCTUnwrap(traces.first).beginTime)
        view.updateAnimation(visible: true, reduceMotion: false)
        XCTAssertEqual(strokes[0].animation(forKey: SkeletonLoaderView.traceKey)?.beginTime, traces[0].beginTime,
                       "Refreshing an already visible loader does not restart it")
        let cycle = try XCTUnwrap(gradient.animation(forKey: SkeletonLoaderView.sweepKey) as? CAAnimationGroup)
        XCTAssertEqual(cycle.repeatCount, .infinity)
        let sweep = try XCTUnwrap(cycle.animations?.first as? CAKeyframeAnimation)
        XCTAssertEqual(sweep.keyPath, "locations")
        XCTAssertLessThan(sweep.duration, cycle.duration, "Each pass rests before the next")
        XCTAssertNotEqual(sweep.timingFunction, CAMediaTimingFunction(name: .linear))
        let stops = try XCTUnwrap(sweep.values as? [[NSNumber]])
        for frame in stops {
            let values = frame.map(\.doubleValue)
            XCTAssertEqual(values, values.sorted())
            XCTAssertTrue(values.allSatisfy { (0...1).contains($0) }, "The gradient stays renderable at every keyframe")
        }
    }

    func testHiddenAndReducedMotionLoadersStopAndRemainComplete() throws {
        let view = SkeletonLoaderView(layout: .notes, label: "Loading notes")
        view.frame = CGRect(x: 0, y: 0, width: 1_400, height: 760)
        view.layoutSubtreeIfNeeded()
        let gradient = try XCTUnwrap(gradient(in: view.layer))
        let strokes = try XCTUnwrap(gradient.mask?.sublayers?.compactMap { $0 as? CAShapeLayer })
        for (visible, reduceMotion) in [(false, false), (true, true)] {
            view.updateAnimation(visible: true, reduceMotion: false)
            XCTAssertNotNil(gradient.animation(forKey: SkeletonLoaderView.sweepKey))
            view.updateAnimation(visible: visible, reduceMotion: reduceMotion)
            XCTAssertNil(gradient.animationKeys())
            for stroke in strokes {
                XCTAssertNil(stroke.animationKeys())
                XCTAssertEqual(stroke.strokeEnd, 1, "Stopping motion shows the completed drawing")
                XCTAssertFalse(try XCTUnwrap(stroke.path).isEmpty)
            }
        }
    }

    @MainActor
    func testWindowVisibilityControlsMotionAndLayoutDoesNotRestartIt() throws {
        try XCTSkipIf(RelayLayerMotion.reduceMotion, "The system requests a static sketch")
        _ = NSApplication.shared
        let size = CGSize(width: 900, height: 520)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 200, y: 200), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        defer { window.orderOut(nil) }
        let parent = NSView(frame: CGRect(origin: .zero, size: size))
        let view = SkeletonLoaderView(layout: .terminal, label: "Starting session")
        view.frame = parent.bounds
        parent.addSubview(view)
        window.contentView = parent
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        let gradient = try XCTUnwrap(gradient(in: view.layer))
        let cycle = try XCTUnwrap(gradient.animation(forKey: SkeletonLoaderView.sweepKey))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(gradient.animation(forKey: SkeletonLoaderView.sweepKey)?.beginTime, cycle.beginTime)

        if let directory = ProcessInfo.processInfo.environment["RELAY_SKELETON_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("motion", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let started = Date()
            for frame in 0..<72 {
                RunLoop.main.run(until: started.addingTimeInterval(Double(frame) / 18))
                let bitmap = try render(try XCTUnwrap(view.layer?.presentation()), size: size)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent(String(format: "%03d.png", frame)))
            }
        }

        parent.isHidden = true
        XCTAssertNil(gradient.animationKeys(), "Hiding an ancestor stops offscreen work")
        parent.isHidden = false
        XCTAssertNotNil(gradient.animation(forKey: SkeletonLoaderView.sweepKey))
        view.removeFromSuperview()
        XCTAssertNil(gradient.animationKeys(), "Detaching the loader stops its repeating animation")
    }

    func testDotDrawingUsesBaselinesAndKeepsContoursInsideTheirBounds() {
        let text = SkeletonBone(rect: CGRect(x: 16, y: 30, width: 160, height: 12), radius: 6, style: .fill)
        let line = SkeletonLoaderView.wirePath(for: text).boundingBoxOfPath
        XCTAssertEqual(line.height, 0, "Text is one row of dots, not a filled bar")
        XCTAssertEqual(line.midY, text.rect.midY)
        let card = SkeletonBone(rect: CGRect(x: 10, y: 10, width: 260, height: 140), radius: 14, style: .outline)
        let outline = SkeletonLoaderView.wirePath(for: card).boundingBoxOfPath
        XCTAssertEqual(outline, card.rect.insetBy(dx: 1, dy: 1))
        for bounds in [CGRect.zero, CGRect(x: 0, y: 0, width: 12, height: 12), CGRect(x: 8, y: 20, width: 900, height: 667)] {
            let field = SkeletonLoaderView.fieldPath(in: bounds)
            if !field.isEmpty { XCTAssertTrue(bounds.contains(field.boundingBoxOfPath)) }
        }
    }

    /// Export the actual native layers for visual QA, without launching Relay.
    func testSketchRendering() throws {
        let directory = ProcessInfo.processInfo.environment["RELAY_SKELETON_RENDER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for (name, layout, size) in [
            ("workspace", SkeletonLoaderLayout.board(columnTop: boardTop), CGSize(width: 1_400, height: 760)),
            ("terminal", .terminal, CGSize(width: 900, height: 520)),
            ("notes", .notes, CGSize(width: 1_100, height: 640)),
            ("settings", .settings, CGSize(width: 1_400, height: 760)),
            ("history", .history, CGSize(width: 940, height: 569)),
        ] {
            let view = SkeletonLoaderView(layout: layout, label: "Loading")
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            let bitmap = try render(try XCTUnwrap(view.layer), size: size)
            let line = try XCTUnwrap(view.bones.first { $0.style == .fill && $0.rect.width > 40 })
            let y = Int(line.rect.midY * 2)
            let samples = (Int(line.rect.minX * 2)..<Int(line.rect.maxX * 2)).map {
                bitmap.colorAt(x: $0, y: y)?.usingColorSpace(.deviceRGB)?.blueComponent ?? 0
            }
            XCTAssertGreaterThan(try XCTUnwrap(samples.max()) - (samples.min() ?? 0), 0.05,
                                 "\(name): the baseline contains separated, visible dots")
            if let directory {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
    }

    private func render(_ layer: CALayer, size: CGSize) throws -> NSBitmapImageRep {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: CGSize(width: size.width * 2, height: size.height * 2)))
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }

    func testLabelChangesReachVoiceOver() {
        let view = SkeletonLoaderView(layout: .terminal, label: "Updating Codex")
        view.setLabel("Starting Codex")
        XCTAssertEqual(view.accessibilityLabel(), "Starting Codex")
    }

    func testLoaderLabelsHaveNoEllipsis() {
        XCTAssertFalse(BoardUpdateStatus.workingLabel.contains("…"))
        XCTAssertFalse(BoardUpdateStatus.workingLabel.hasSuffix("..."))
    }
}
