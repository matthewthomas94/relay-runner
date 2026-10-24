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
        let coordinates = try NSRegularExpression(pattern: "^\\d{3}·\\d{3}$")
        let tag = try NSRegularExpression(pattern: "^[A-Z]+ \\d+×\\d+$")
        let dimension = try NSRegularExpression(pattern: "^\\d+ × \\d+$")
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
            XCTAssertEqual(texts.count, view.annotatedRects.count * 3 + view.keyRects.count,
                           "\(layout): a readout, a tag and a coordinate per element, a size per key box")
            for text in texts {
                let string = try XCTUnwrap(text.string as? String)
                let range = NSRange(string.startIndex..., in: string)
                XCTAssertTrue([readout, coordinates, tag, dimension].contains { $0.firstMatch(in: string, range: range) != nil },
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

    func testConstructionReadoutsMatchTheLander() {
        XCTAssertEqual(SkeletonConstruction.readout(width: 320.4, height: 180, time: 0), "320 × 180  t+0.00s")
        XCTAssertEqual(SkeletonConstruction.readout(width: 1_024, height: 64, time: 0.5), "1024 × 64  t+0.50s")
        XCTAssertEqual(SkeletonConstruction.coordinates(x: 22, y: 130), "022·130")
        XCTAssertEqual(SkeletonConstruction.coordinates(x: -3, y: 130.4), "000·130")
        XCTAssertEqual(SkeletonConstruction.dimension(width: 108, height: 108), "108 × 108")
        XCTAssertEqual(SkeletonConstruction.tag(name: "svg", width: 108, height: 108), "SVG 108×108")
    }

    func testGenerationTimelineMatchesTheLander() {
        XCTAssertEqual(SkeletonGeneration.dotsWindow, 0.0...0.3)
        XCTAssertEqual(SkeletonGeneration.outlineWindow, 0.1...0.42)
        XCTAssertEqual(SkeletonGeneration.partsWindow, 0.28...0.74)
        XCTAssertEqual(SkeletonGeneration.revealWindow.lowerBound, 0.74)
        XCTAssertGreaterThanOrEqual(SkeletonGeneration.holdProgress, SkeletonGeneration.partsWindow.upperBound,
                                    "The sketch holds once every part has traced")
        XCTAssertLessThanOrEqual(SkeletonGeneration.holdProgress, SkeletonGeneration.revealWindow.lowerBound,
                                 "and before anything starts to release")
        XCTAssertLessThan(SkeletonGeneration.holdProgress, SkeletonGeneration.cleanWindow.lowerBound)
        for value in [0.06, 0.3, 0.5, 0.96] {
            XCTAssertEqual(SkeletonGeneration.eased(SkeletonGeneration.inverseEaseOut(value)), value, accuracy: 0.001,
                           "A flyer lands exactly when the traced outline reaches its point")
        }
        XCTAssertEqual(SkeletonGeneration.smooth(0, 1, 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SkeletonGeneration.smooth(0.2, 0.4, 0.1), 0)
        XCTAssertEqual(SkeletonGeneration.smooth(0.2, 0.4, 0.9), 1)
        XCTAssertEqual(SkeletonGeneration.span(0.1...0.5, 0.3), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SkeletonGeneration.hash(3), SkeletonGeneration.hash(3), "The sketch repeats exactly")
        XCTAssertNotEqual(SkeletonGeneration.hash(3), SkeletonGeneration.hash(4))
        XCTAssertEqual(SkeletonGeneration.wireDotRadius * 2, 3, "Wire dots are the notch glyph's 3pt dot")
        XCTAssertEqual(SkeletonGeneration.wireGap, 5, "on the glyph's 5pt pitch")
    }

    func testTracedPathsPlaceWholeDotsThatCrawl() throws {
        let rect = CGRect(x: 10, y: 10, width: 300, height: 120)
        let right = SkeletonGeneration.SampledPath.half(of: rect, radius: 16, right: true)
        let left = SkeletonGeneration.SampledPath.half(of: rect, radius: 16, right: false)
        let perimeter = 2 * (300 - 32) + 2 * (120 - 32) + 2 * CGFloat.pi * 16
        XCTAssertEqual(right.length + left.length, perimeter, accuracy: 1)
        XCTAssertEqual(right.point(at: 0), CGPoint(x: rect.midX, y: rect.minY), "Both halves start at top centre")
        XCTAssertEqual(left.point(at: 0), CGPoint(x: rect.midX, y: rect.minY))
        XCTAssertEqual(right.point(at: right.length).y, rect.maxY, accuracy: 0.001, "and end at bottom centre")
        XCTAssertEqual(left.point(at: left.length).y, rect.maxY, accuracy: 0.001)
        for half in [right, left] {
            for distance in stride(from: CGFloat(0), through: half.length, by: 7) {
                XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(half.point(at: distance)), "\(distance)")
            }
        }
        let closed = SkeletonGeneration.SampledPath.roundedRect(rect, radius: 16)
        XCTAssertEqual(closed.length, perimeter, accuracy: 1)

        let full = SkeletonGeneration.trace(right, progress: 1, elapsedMs: 0, gap: 5)
        XCTAssertNil(full.head, "A finished trace has no head")
        XCTAssertEqual(full.dots.count, Int(right.length / 5) + 1)
        let partial = SkeletonGeneration.trace(right, progress: 0.5, elapsedMs: 0, gap: 5)
        XCTAssertEqual(partial.dots.count, Int(right.length * 0.5 / 5) + 1, "Dots are placed whole, never clipped")
        XCTAssertEqual(try XCTUnwrap(partial.head), try XCTUnwrap(partial.dots.last), "The head rides the last placed dot")
        let crawled = SkeletonGeneration.trace(right, progress: 0.5, elapsedMs: 100, gap: 5)
        XCTAssertNotEqual(crawled.dots.first, partial.dots.first, "Dots crawl along the path over time")
        XCTAssertEqual(SkeletonGeneration.trace(right, progress: 0, elapsedMs: 0, gap: 5).dots.count, 0)
    }

    func testSceneTurnsSurfacesIntoElementsAndBonesIntoParts() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1_400, height: 760)
        let layout = SkeletonLoaderLayout.board(columnTop: boardTop)
        let panels = SkeletonLoaderView.panels(for: layout, in: bounds)
        let bones = SkeletonLoaderView.bones(for: layout, in: bounds)
        let scene = SkeletonGeneration.scene(bounds: bounds, surfaces: panels, bones: bones)
        XCTAssertEqual(scene.elements.map(\.rect), panels, "Each column is an element")
        XCTAssertEqual(scene.elements.map(\.parts.count).reduce(0, +), bones.count, "Every bone is some element's part")
        for element in scene.elements {
            XCTAssertEqual(element.flyers.count, SkeletonGeneration.flyerCount)
            XCTAssertEqual(element.guides.count, 4)
            XCTAssertEqual(element.halves.count, 2)
            let keys = element.parts.filter(\.key)
            XCTAssertFalse(keys.isEmpty, "The largest cards are keys")
            XCTAssertLessThanOrEqual(keys.count, SkeletonGeneration.maxKeysPerElement)
            XCTAssertTrue(keys.allSatisfy { $0.kind == .frame && $0.strokes.count == 2 }, "Key boxes trace as two halves")
            for part in element.parts {
                XCTAssertTrue(element.rect.contains(part.rect))
                XCTAssertGreaterThanOrEqual(part.start, SkeletonGeneration.partsWindow.lowerBound)
                XCTAssertLessThanOrEqual(part.end, SkeletonGeneration.partsWindow.upperBound + 0.0001)
                if part.kind == .text {
                    let stroke = try XCTUnwrap(part.strokes.first)
                    XCTAssertEqual(stroke.path.point(at: 0).y, stroke.path.point(at: stroke.path.length).y,
                                   "Text is one dotted baseline, not a filled bar")
                    XCTAssertTrue(stroke.caps)
                }
            }
            XCTAssertTrue(zip(element.parts, element.parts.dropFirst()).allSatisfy { $0.start <= $1.start },
                          "Parts start in reading order")
            for flyer in element.flyers {
                XCTAssertGreaterThan(flyer.arrival, flyer.start)
                XCTAssertTrue(SkeletonGeneration.outlineWindow.contains(flyer.arrival))
                XCTAssertTrue(element.rect.insetBy(dx: -1, dy: -1).contains(flyer.to), "Flyers land on the contour")
            }
        }
        XCTAssertFalse(scene.dots.isEmpty)
        for dot in scene.dots {
            XCTAssertTrue(bounds.contains(dot.center))
            XCTAssertTrue((0...1).contains(dot.edge))
            XCTAssertTrue(scene.elements.indices.contains(dot.element))
        }
        XCTAssertEqual(scene.keyRects.count, scene.elements.map { $0.parts.filter(\.key).count }.reduce(0, +))
    }

    func testFramesBuildUpThenHoldThenRelease() throws {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 520)
        let bones = SkeletonLoaderView.bones(for: .terminal, in: bounds)
        let scene = SkeletonGeneration.scene(bounds: bounds, surfaces: [], bones: bones)
        let count = scene.elements.count
        XCTAssertGreaterThan(count, 0)
        func frame(_ a: Double, ms: Double = 0) -> SkeletonGeneration.Frame {
            SkeletonGeneration.evaluate(scene, progress: Array(repeating: a, count: count), elapsedMs: ms)
        }
        let start = frame(0)
        XCTAssertTrue(start.wires.isEmpty, "Nothing is traced before the outline window")
        XCTAssertTrue(start.handles.isEmpty)
        XCTAssertLessThan(start.field.count, scene.dots.count / 2, "The field wakes from the centre, not all at once")

        let outlining = frame(0.25)
        XCTAssertFalse(outlining.wires.filter(\.strong).isEmpty, "Heads and flyers show while the contour traces")
        XCTAssertEqual(outlining.handles.count, count * 2, "The top handles have popped, the bottom pair not yet")
        let readout = try XCTUnwrap(outlining.labels.first { $0.kind == .readout })
        XCTAssertGreaterThan(readout.alpha, 0)
        XCTAssertTrue(readout.text.hasSuffix("s"))
        XCTAssertEqual(outlining.labels.first { $0.kind == .coordinates }?.alpha, 1, "The coordinate readout follows a live head")

        let building = frame(0.5)
        XCTAssertFalse(building.reticles.isEmpty, "A reticle frames the part under construction")
        XCTAssertTrue(building.labels.contains { $0.kind == .tag && $0.alpha > 0.5 })

        let held = frame(SkeletonGeneration.holdProgress, ms: 5_000)
        XCTAssertEqual(held.labels.first { $0.kind == .coordinates }?.alpha, 0, "Every trace has finished")
        XCTAssertEqual(held.handles.count, count * 4 + scene.keyRects.count * 4)
        XCTAssertGreaterThanOrEqual(held.field.count, scene.dots.filter { $0.edge > 0.05 }.count,
                                    "Every dot within reach of an element shows while the sketch holds")
        XCTAssertFalse(held.wires.isEmpty)
        let heldLater = frame(SkeletonGeneration.holdProgress, ms: 5_100)
        XCTAssertNotEqual(held.wires.map(\.center), heldLater.wires.map(\.center), "Dots keep crawling while the sketch holds")

        let released = frame(1.05)
        XCTAssertTrue(released.handles.isEmpty, "Handles have shrunk away")
        XCTAssertTrue(released.reticles.isEmpty)
        XCTAssertTrue(released.field.isEmpty, "The field has cleaned up")
        XCTAssertTrue(released.wires.allSatisfy { $0.alpha < 0.05 }, "The wireframe has faded")
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
        XCTAssertTrue(view.renderedProgress.allSatisfy { $0 > SkeletonGeneration.holdProgress },
                      "The handoff plays the release part of the timeline")
        view.setHandoffProgress(0.8)
        XCTAssertEqual(chrome.opacity, 0.5, accuracy: 0.001)
        view.setHandoffProgress(1)
        XCTAssertEqual(chrome.opacity, 0)
        view.setHandoffProgress(nil)
        XCTAssertFalse(view.isHandingOff, "A reused loader comes back whole")
        XCTAssertEqual(chrome.opacity, 1)
        XCTAssertEqual(view.renderedProgress, Array(repeating: SkeletonGeneration.holdProgress, count: view.annotatedRects.count))

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

    func testSketchAnimatesOnlyWhileVisibleAndNeverRestarts() throws {
        let view = SkeletonLoaderView(layout: .terminal, label: "Starting Claude")
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 667)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.hitTest(CGPoint(x: 450, y: 333)))
        XCTAssertEqual(view.accessibilityLabel(), "Starting Claude")
        XCTAssertFalse(view.isAnimating, "Detached loaders do no animation work")
        let held = Array(repeating: SkeletonGeneration.holdProgress, count: view.annotatedRects.count)
        XCTAssertEqual(view.renderedProgress, held, "A still loader shows the completed sketch")

        view.updateAnimation(visible: true, reduceMotion: false)
        XCTAssertTrue(view.isAnimating)
        let started = try XCTUnwrap(view.constructionStart)
        XCTAssertTrue(view.renderedProgress.allSatisfy { $0 < 0.05 }, "Construction starts from nothing")
        view.updateAnimation(visible: true, reduceMotion: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.constructionStart, started, "Refreshing or laying out a visible loader does not restart it")

        view.updateAnimation(visible: false, reduceMotion: false)
        XCTAssertFalse(view.isAnimating)
        XCTAssertEqual(view.renderedProgress, held, "Stopping motion shows the completed drawing")
        view.updateAnimation(visible: true, reduceMotion: true)
        XCTAssertFalse(view.isAnimating, "Reduce Motion shows the completed sketch")
        XCTAssertEqual(view.renderedProgress, held)
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
        XCTAssertTrue(view.isAnimating)
        let started = try XCTUnwrap(view.constructionStart)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.constructionStart, started)

        if let directory = ProcessInfo.processInfo.environment["RELAY_SKELETON_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("motion", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for frame in 0..<72 {
                view.renderFrame(elapsed: Double(frame) / 18)
                let bitmap = try render(try XCTUnwrap(view.layer), size: size)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent(String(format: "%03d.png", frame)))
            }
        }

        parent.isHidden = true
        XCTAssertFalse(view.isAnimating, "Hiding an ancestor stops offscreen work")
        parent.isHidden = false
        XCTAssertTrue(view.isAnimating)
        view.removeFromSuperview()
        XCTAssertFalse(view.isAnimating, "Detaching the loader stops its display link")
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
