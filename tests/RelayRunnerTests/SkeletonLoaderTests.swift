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

    func testSkeletonsShowNoText() {
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
            XCTAssertFalse(containsText(view.layer), "\(layout) draws no text")
            XCTAssertEqual(view.accessibilityLabel(), BoardUpdateStatus.workingLabel, "VoiceOver still hears the status")
        }
    }

    private func containsText(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        if layer is CATextLayer { return true }
        return (layer.sublayers ?? []).contains { containsText($0) } || containsText(layer.mask)
    }

    func testLoaderShimmersWithoutTakingClicks() throws {
        try XCTSkipIf(RelayLayerMotion.reduceMotion, "Reduce Motion holds the shimmer still")
        let view = SkeletonLoaderView(layout: .terminal, label: "Starting Claude")
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 667)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.hitTest(CGPoint(x: 450, y: 333)))
        XCTAssertEqual(view.accessibilityLabel(), "Starting Claude")

        let sublayers = try XCTUnwrap(view.layer?.sublayers)
        let bones = try XCTUnwrap(sublayers.first { $0.sublayers?.count == DotPresence.cohorts })
        XCTAssertEqual(bones.opacity, FluxDotStyle.standard.opacity, "The dots look like the Workspace tabs' hover")
        let cohorts = try XCTUnwrap(bones.sublayers, "A layer per presence cohort")
        var dotLayers: [(phase: Int, layer: CAShapeLayer)] = []
        for cohort in cohorts {
            XCTAssertEqual(cohort.opacity, 1, "Outside a transition the whole field is there")
            let phases = try XCTUnwrap(cohort.sublayers as? [CAShapeLayer], "A layer per ripple phase")
            XCTAssertEqual(phases.count, DotRippleAnimation.phases)
            XCTAssertTrue(phases.contains { !($0.path?.isEmpty ?? true) }, "Every cohort has some of the terminal's dots")
            dotLayers += phases.enumerated().map { ($0.offset, $0.element) }
        }
        for (phase, dots) in dotLayers {
            XCTAssertEqual(dots.fillColor, SkeletonLoaderView.boneHighlightColor.cgColor, "Dots are the highlight; only their opacity moves")
            let ripple = try XCTUnwrap(dots.animation(forKey: SkeletonLoaderView.shimmerKey) as? CAKeyframeAnimation)
            XCTAssertEqual(ripple.keyPath, "opacity")
            XCTAssertEqual(ripple.calculationMode, .linear, "The dots fade smoothly between levels")
            let easing = try XCTUnwrap(ripple.timingFunctions)
            XCTAssertEqual(easing.count, DotRippleAnimation.keyTimes.count - 1, "Every segment is eased")
            for function in easing {
                var first: [Float] = [0, 0], second: [Float] = [0, 0]
                function.getControlPoint(at: 1, values: &first)
                function.getControlPoint(at: 2, values: &second)
                let curve = RelayMotion.loopCurve
                XCTAssertEqual(first + second, [curve.x1, curve.y1, curve.x2, curve.y2].map(Float.init), "With the loop curve")
            }
            XCTAssertEqual(ripple.repeatCount, .infinity)
            XCTAssertEqual(ripple.duration, 1.2, accuracy: 0.001, "Dotm's 1.5 s cycle at speed 1.25")
            XCTAssertEqual(ripple.keyTimes?.map(\.doubleValue), DotRippleAnimation.keyTimes)
            XCTAssertEqual(ripple.values as? [Float], DotRippleAnimation.levels, "Rest, peak, settle, rest")
            let delay = (Double(phase) * DotRippleAnimation.ringDelay).truncatingRemainder(dividingBy: 1) * ripple.duration
            let expectedOffset = (ripple.duration - delay).truncatingRemainder(dividingBy: ripple.duration)
            XCTAssertEqual(ripple.timeOffset, expectedOffset, accuracy: 0.0001, "Phase \(phase) runs 0.16 of a cycle per ring behind the origin")
        }
        let outline = try XCTUnwrap(sublayers.last as? CAShapeLayer)
        XCTAssertEqual(outline.opacity, SkeletonLoaderView.outlineOpacity, "Borders keep their faint look")
        XCTAssertFalse(try XCTUnwrap(outline.path).isEmpty, "The terminal has an outline")
        XCTAssertNil(outline.fillColor)
        XCTAssertEqual(outline.strokeColor, SkeletonLoaderView.boneBaseColor.cgColor)
        XCTAssertEqual(outline.lineWidth, SkeletonLoaderView.outlineWidth)
        XCTAssertNil(outline.animation(forKey: SkeletonLoaderView.shimmerKey), "Outlines stay still")
    }

    func testRippleLevelsFollowDotmSquare12() {
        // DotmSquare12 speed=1.25 opacityBase=0.12 opacityMid=0.42 opacityPeak=1.
        XCTAssertEqual(DotRippleAnimation.cycle, 1.2, accuracy: 0.0001)
        let levels = DotRippleAnimation.levels
        XCTAssertEqual(levels.count, 4)
        XCTAssertEqual(levels[0], 0.075, accuracy: 0.0001, "Rest: 0.625 of the base")
        XCTAssertEqual(levels[1], 1, "Peak")
        XCTAssertEqual(levels[2], 0.27, accuracy: 0.0001, "Settle: halfway between base and mid")
        XCTAssertEqual(levels[3], levels[0], "Each cycle ends where it began")
        XCTAssertEqual(DotRippleAnimation.keyTimes, [0, 0.34, 0.6, 1])

        XCTAssertEqual(DotRippleAnimation.ring(column: 1, row: 1), 0, "The origin is one in from the top-left")
        XCTAssertEqual(DotRippleAnimation.ring(column: 0, row: 0), 2)
        XCTAssertEqual(DotRippleAnimation.ring(column: 4, row: 4), 6, "The far corner of a 5 by 5 grid")
        XCTAssertEqual(DotRippleAnimation.ring(column: 30, row: 1), 29, "Wide fields keep counting")
        XCTAssertEqual(DotRippleAnimation.phase(forRing: 29, reduceMotion: false), 4,
                       "Ring 29 starts four cycles after ring 4, so they share a layer")
        XCTAssertEqual(DotRippleAnimation.delay(forPhase: 0), 0)
        XCTAssertEqual(DotRippleAnimation.delay(forPhase: 1), 0.16 * 1.2, accuracy: 0.0001)
        XCTAssertEqual(DotRippleAnimation.delay(forPhase: 7), 0.12 * 1.2, accuracy: 0.0001, "Ring 7 wraps past one cycle")

        // Still, under Reduce Motion: Dotm's gradient out from the origin,
        // mapped onto the triplet; rings past the sixth all rest alike.
        XCTAssertEqual(DotRippleAnimation.phase(forRing: 29, reduceMotion: true), 6)
        let resting = (0...7).map(DotRippleAnimation.restingOpacity(forRing:))
        XCTAssertEqual(resting[0], DotRippleAnimation.remapped(0.95), accuracy: 0.0001)
        XCTAssertEqual(resting[6], DotRippleAnimation.remapped(0.2), accuracy: 0.0001)
        XCTAssertEqual(resting[7], resting[6])
        for (nearer, farther) in zip(resting, resting.dropFirst()) {
            XCTAssertGreaterThanOrEqual(nearer, farther, "Dimmer with distance")
        }
        XCTAssertEqual(DotRippleAnimation.remapped(0.08), 0.12, accuracy: 0.0001, "Source base maps to the base")
        XCTAssertEqual(DotRippleAnimation.remapped(0.34), 0.42, accuracy: 0.0001, "Source mid maps to the mid")
        XCTAssertEqual(DotRippleAnimation.remapped(0.94), 1, accuracy: 0.0001, "Source peak maps to the peak")
        XCTAssertEqual(DotRippleAnimation.remapped(0.21), 0.12 + 0.3 * 0.5, accuracy: 0.0001, "Linear between stops")
    }

    func testFilledBonesAreDrawnAsDotMatrices() {
        let pitch = SkeletonLoaderView.dotPitch
        let dotRadius = SkeletonLoaderView.dotDiameter / 2
        let glyph = NotchStatusGlyph.neutral.dots
        for dot in glyph {
            XCTAssertEqual(dot.diameter, SkeletonLoaderView.dotDiameter, "The dots are the notch glyph's size")
        }
        let glyphColumns = Set(glyph.map(\.x)).sorted()
        XCTAssertEqual(glyphColumns[1] - glyphColumns[0], pitch, "On the glyph's grid")

        let bar = CGRect(x: 10, y: 20, width: 100, height: 10)
        let barDots = SkeletonLoaderView.dots(in: bar, cornerRadius: 5).map(\.centre)
        XCTAssertEqual(Set(barDots.map(\.y)).count, 2, "A text bar is two rows of dots")
        let firstRow = barDots.filter { $0.y == barDots[0].y }.map(\.x).sorted()
        for (left, right) in zip(firstRow, firstRow.dropFirst()) {
            XCTAssertEqual(right - left, pitch, accuracy: 0.001)
        }
        for dot in barDots {
            XCTAssertTrue(bar.insetBy(dx: dotRadius - 0.001, dy: dotRadius - 0.001).contains(dot), "\(dot)")
        }

        let iconDots = SkeletonLoaderView.dots(in: CGRect(x: 0, y: 0, width: 24, height: 24), cornerRadius: 8)
        XCTAssertEqual(iconDots.count, 5 * 5 - 4, "A rounded icon drops its corner dots")
    }

    func testDotsRoundTheirCornersLikeTheirShape() {
        let pitch = SkeletonLoaderView.dotPitch
        // A Workspace tab: the corner dots drop so the dots round like the
        // selected tab's fill.
        let tab = SkeletonLoaderView.dots(in: CGRect(x: 0, y: 0, width: 60, height: 24), cornerRadius: 6).map(\.centre)
        let xs = Set(tab.map(\.x)).sorted(), ys = Set(tab.map(\.y)).sorted()
        XCTAssertEqual(tab.count, xs.count * ys.count - 4, "Only the four corner dots drop")
        for corner in [CGPoint(x: xs.first!, y: ys.first!), CGPoint(x: xs.last!, y: ys.first!),
                       CGPoint(x: xs.first!, y: ys.last!), CGPoint(x: xs.last!, y: ys.last!)] {
            XCTAssertFalse(tab.contains(corner), "\(corner)")
        }
        XCTAssertTrue(tab.contains(CGPoint(x: xs.first! + pitch, y: ys.first!)))

        let avatar = SkeletonLoaderView.dots(in: CGRect(x: 0, y: 0, width: 24, height: 24), cornerRadius: 12)
        XCTAssertEqual(avatar.count, 5 * 5 - 4, "A round avatar stays round rather than a diamond")

        let bar = SkeletonLoaderView.dots(in: CGRect(x: 0, y: 0, width: 100, height: 10), cornerRadius: 5)
        XCTAssertEqual(bar.count, 2 * 20, "Two rows are too few to round, so a text bar keeps every dot")
    }

    func testRingsSpreadFromOneInFromTheTopLeft() {
        // A 5 by 5 square at the loader's corner, like DotmSquare12.
        let square = SkeletonLoaderView.dots(in: CGRect(x: 0, y: 0, width: 24, height: 24), cornerRadius: 0)
        XCTAssertEqual(square.count, 25)
        let columns = Dictionary(grouping: square) { $0.centre.x }.sorted { $0.key < $1.key }.map(\.value)
        let rings = columns.map { $0.sorted { $0.centre.y < $1.centre.y }.map(\.ring) }
        XCTAssertEqual(rings, [
            [2, 1, 2, 3, 4],
            [1, 0, 1, 2, 3],
            [2, 1, 2, 3, 4],
            [3, 2, 3, 4, 5],
            [4, 3, 4, 5, 6],
        ], "Manhattan distance from the second dot in from the top-left")
    }

    func testOneRippleCrossesEveryBone() {
        let upper = SkeletonLoaderView.dots(in: CGRect(x: 0, y: 2, width: 24, height: 8), cornerRadius: 0)
        let lower = SkeletonLoaderView.dots(in: CGRect(x: 0, y: 10, width: 24, height: 8), cornerRadius: 0)
        XCTAssertNotEqual(upper.map(\.ring), lower.map(\.ring),
                          "Bones at different heights light at different moments")
        for dot in lower {
            let column = Int((dot.centre.x / SkeletonLoaderView.dotPitch).rounded())
            let row = Int((dot.centre.y / SkeletonLoaderView.dotPitch).rounded())
            XCTAssertEqual(dot.ring, DotRippleAnimation.ring(column: column, row: row),
                           "Rings count from the loader's grid, not the bone's")
        }
    }

    func testHoverBackgroundFillsItsRoundedShapeWithShimmeringDots() throws {
        let view = FluxDotsView(cornerRadius: 6, style: .standard)
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 24)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.hitTest(CGPoint(x: 60, y: 12)), "Clicks reach the item underneath")
        XCTAssertEqual(view.dots.container.opacity, 1, "Hover dots are opaque so they show on dark backgrounds")
        var dotCount = 0
        for (cohort, phases) in view.dots.phaseLayers.enumerated() {
            for (phase, layer) in phases.enumerated() {
                let path = try XCTUnwrap(layer.path)
                if !path.isEmpty {
                    dotCount += path.componentsSeparated().count
                    XCTAssertTrue(view.bounds.contains(path.boundingBoxOfPath), "Cohort \(cohort) phase \(phase) stays inside the item")
                }
                XCTAssertEqual(layer.fillColor, FluxDotStyle.standard.highlight.cgColor, "In the hover colour")
                if !RelayLayerMotion.reduceMotion {
                    let ripple = try XCTUnwrap(layer.animation(forKey: SkeletonLoaderView.shimmerKey) as? CAKeyframeAnimation,
                                               "Cohort \(cohort) phase \(phase) shimmers")
                    XCTAssertEqual(ripple.values as? [Float], DotRippleAnimation.levels, "With the ripple's levels")
                }
            }
        }
        XCTAssertEqual(dotCount, SkeletonLoaderView.dots(in: view.bounds, cornerRadius: 6).count, "Every dot is drawn once")
    }

    func testDotsLandOnWholePixelsLikeTheGlyph() throws {
        // A tab's width follows its label, so its dots rarely start on a
        // whole pixel; half a pixel off, they blur and look smaller.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = FluxDotsView(cornerRadius: 6, style: .standard)
        view.frame = CGRect(x: 10.25, y: 20.25, width: 63.25, height: 24)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let diameter = try XCTUnwrap(NotchStatusGlyph.neutral.dots.first).diameter
        for layer in view.dots.phaseLayers.flatMap({ $0 }) {
            for dot in try XCTUnwrap(layer.path).componentsSeparated() {
                let rect = dot.boundingBoxOfPath
                let pixels = window.convertToBacking(view.convert(rect, to: nil))
                for edge in [pixels.minX, pixels.minY, pixels.maxX, pixels.maxY] {
                    XCTAssertEqual(edge, edge.rounded(), accuracy: 0.001, "\(rect) sits on whole pixels")
                }
                XCTAssertEqual(rect.width, diameter, accuracy: 0.001, "The glyph's dot size")
                XCTAssertEqual(rect.height, diameter, accuracy: 0.001, "The glyph's dot size")
            }
        }
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

    func testDotsAreDealtIntoScatteredFixedCohorts() {
        let bar = SkeletonLoaderView.dots(in: CGRect(x: 0, y: 0, width: 200, height: 60), cornerRadius: 0)
        XCTAssertEqual(Set(bar.map(\.cohort)).count, DotPresence.cohorts, "A panel-sized field uses every cohort")
        XCTAssertEqual(bar.map(\.cohort), SkeletonLoaderView.dots(in: CGRect(x: 0, y: 0, width: 200, height: 60), cornerRadius: 0).map(\.cohort),
                       "The deal is fixed, so a relayout never reshuffles the field")
        let columns = Dictionary(grouping: bar) { $0.centre.x }.values
        let stripes = columns.filter { Set($0.map(\.cohort)).count == 1 }.count
        XCTAssertLessThan(stripes, columns.count / 8, "Cohorts scatter rather than form stripes")
        for cohort in 0..<DotPresence.cohorts {
            let members = bar.filter { $0.cohort == cohort }
            XCTAssertGreaterThan(members.count, 0)
            XCTAssertGreaterThanOrEqual(Set(members.map(\.centre.x)).count * 2, members.count,
                                        "Cohort \(cohort) spreads across columns rather than clumping")
            XCTAssertGreaterThan(Set(members.map(\.centre.y)).count, 1, "Cohort \(cohort) spans rows")
        }
    }

    func testPresenceFadesCohortsInTurnAndBackOut() {
        for cohort in 0..<DotPresence.cohorts {
            XCTAssertEqual(DotPresence.opacity(ofCohort: cohort, presence: 0), 0, "Nothing is there at 0")
            XCTAssertEqual(DotPresence.opacity(ofCohort: cohort, presence: 1), 1, "Everything is there at 1")
        }
        XCTAssertEqual(DotPresence.opacity(ofCohort: 0, presence: DotPresence.fade / 2), 0.5, accuracy: 0.0001,
                       "The first cohort is halfway through its brief fade")
        XCTAssertEqual(DotPresence.opacity(ofCohort: DotPresence.cohorts - 1, presence: 0.2), 0, "The last has not started")
        let last = DotPresence.window(ofCohort: DotPresence.cohorts - 1)
        XCTAssertLessThanOrEqual(last.end, 1, "The last cohort finishes within the sweep")
        XCTAssertGreaterThan(last.end, 0.95, "And close to its end, so the sweep is spread evenly")
        let midFade = (0..<DotPresence.cohorts).filter {
            let opacity = DotPresence.opacity(ofCohort: $0, presence: 0.5)
            return opacity > 0 && opacity < 1
        }.count
        XCTAssertLessThanOrEqual(midFade, 4, "Only a few cohorts fade at once, so dots arrive one by one rather than as a block")
        var previous = DotPresence.window(ofCohort: 0)
        for cohort in 1..<DotPresence.cohorts {
            let window = DotPresence.window(ofCohort: cohort)
            XCTAssertGreaterThan(window.start, previous.start, "Each cohort starts after the last")
            XCTAssertLessThan(window.start, previous.end, "And overlaps it, so the field fills continuously")
            previous = window
        }
    }

    func testSettingPresenceShowsThatShareOfTheDotsAtOnce() {
        let view = FluxDotsView(cornerRadius: 6, style: .standard)
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 24)
        view.layoutSubtreeIfNeeded()
        view.dots.setPresence(0)
        XCTAssertTrue(view.dots.cohortLayers.allSatisfy { $0.opacity == 0 }, "Gone")
        view.dots.setPresence(0.5)
        let halfway = view.dots.cohortLayers.map(\.opacity)
        XCTAssertEqual(halfway.first, 1, "The first cohort has fully arrived")
        XCTAssertEqual(halfway.last, 0, "The last has not started")
        XCTAssertTrue(halfway.contains { $0 > 0 && $0 < 1 }, "Some are mid-fade")
        XCTAssertEqual(halfway, (0..<DotPresence.cohorts).map { DotPresence.opacity(ofCohort: $0, presence: 0.5) })
        view.dots.setPresence(1)
        XCTAssertTrue(view.dots.cohortLayers.allSatisfy { $0.opacity == 1 }, "All there")
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.dots.cohortLayers.allSatisfy { $0.opacity == 1 }, "A relayout keeps the presence")
    }

    func testAnimatedPresenceStaggersTheCohortsAndReversesOnTheWayOut() throws {
        let view = FluxDotsView(cornerRadius: 6, style: .standard)
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 24)
        view.layoutSubtreeIfNeeded()
        view.dots.setPresence(0)
        let duration: TimeInterval = 1
        view.dots.animatePresence(to: 1, duration: duration)
        var begins: [CFTimeInterval] = []
        for (cohort, layer) in view.dots.cohortLayers.enumerated() {
            let fade = try XCTUnwrap(layer.animation(forKey: FluxDotLayers.presenceKey) as? CABasicAnimation)
            XCTAssertEqual(fade.keyPath, "opacity")
            XCTAssertEqual(fade.fromValue as? Float, 0)
            XCTAssertEqual(fade.toValue as? Float, 1)
            XCTAssertEqual(fade.duration, DotPresence.fade * duration, accuracy: 0.0001, "Each cohort fades over its slice")
            XCTAssertEqual(fade.fillMode, .both, "It waits unseen for its turn and stays once in")
            XCTAssertEqual(layer.opacity, 1, "The model value is where it ends up")
            begins.append(fade.beginTime)
            if cohort > 0 {
                XCTAssertGreaterThan(fade.beginTime, begins[cohort - 1], "Cohort \(cohort) starts after the last")
            }
        }
        XCTAssertEqual(begins.last! - begins.first!, DotPresence.window(ofCohort: DotPresence.cohorts - 1).start * duration,
                       accuracy: 0.0001, "The last cohort starts where its slice of the sweep begins")

        view.dots.animatePresence(to: 0, duration: duration)
        var outBegins: [CFTimeInterval] = []
        for layer in view.dots.cohortLayers {
            let fade = try XCTUnwrap(layer.animation(forKey: FluxDotLayers.presenceKey) as? CABasicAnimation)
            XCTAssertEqual(fade.fromValue as? Float, 1)
            XCTAssertEqual(fade.toValue as? Float, 0)
            XCTAssertEqual(layer.opacity, 0)
            outBegins.append(fade.beginTime)
        }
        for (earlier, later) in zip(outBegins, outBegins.dropFirst()) {
            XCTAssertGreaterThan(earlier, later, "The last cohort to arrive leaves first")
        }

        let done = expectation(description: "Zero-length presence change completes at once")
        view.dots.animatePresence(to: 1, duration: 0) { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertTrue(view.dots.cohortLayers.allSatisfy { $0.opacity == 1 && $0.animation(forKey: FluxDotLayers.presenceKey) == nil })
    }
}
