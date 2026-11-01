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

        let bones = try XCTUnwrap(view.layer?.sublayers?.last)
        XCTAssertEqual(bones.opacity, 0.33, "The bones sit back at a third opacity")
        let layers = try XCTUnwrap(bones.sublayers as? [CAShapeLayer])
        XCTAssertEqual(layers.count, FluxColumnsAnimation.steps + 1, "A layer per snake phase, then the outlines")
        let dotLayers = layers.dropLast()
        for (phase, dots) in dotLayers.enumerated() {
            XCTAssertFalse(try XCTUnwrap(dots.path).isEmpty, "The terminal has dots in phase \(phase)")
            let flux = try XCTUnwrap(dots.animation(forKey: SkeletonLoaderView.shimmerKey) as? CAKeyframeAnimation)
            XCTAssertEqual(flux.keyPath, "fillColor")
            XCTAssertEqual(flux.calculationMode, .linear, "The dots fade smoothly between steps")
            XCTAssertEqual(flux.repeatCount, .infinity)
            XCTAssertEqual(flux.duration, 1.5, accuracy: 0.001, "A cycle as long as Flux Columns'")
            XCTAssertEqual(flux.keyTimes?.count, FluxColumnsAnimation.steps + 1)
            let colors = FluxColumnsAnimation.colors(forPhase: phase)
            XCTAssertEqual(try XCTUnwrap(flux.values as? [CGColor]), colors + [colors[0]], "Each cycle ends where it began")
        }
        let outline = try XCTUnwrap(layers.last)
        XCTAssertFalse(try XCTUnwrap(outline.path).isEmpty, "The terminal has an outline")
        XCTAssertNil(outline.fillColor)
        XCTAssertEqual(outline.strokeColor, SkeletonLoaderView.boneBaseColor.cgColor)
        XCTAssertEqual(outline.lineWidth, SkeletonLoaderView.outlineWidth)
        XCTAssertNil(outline.animation(forKey: SkeletonLoaderView.shimmerKey), "Outlines stay still")
    }

    func testEachSnakeHeadStepsAlongItsColumnWithAFadingTail() {
        let palette = FluxColumnsAnimation.palette
        XCTAssertEqual(palette.first, SkeletonLoaderView.boneHighlightColor.cgColor, "The head is the old highlight")
        XCTAssertEqual(palette.count, FluxColumnsAnimation.steps)
        XCTAssertEqual(palette.last?.alpha, 0, "The end of the tail fades out to the background")
        XCTAssertEqual(palette.last?.copy(alpha: 1), SkeletonLoaderView.boneBaseColor.cgColor, "It fades without changing colour")
        for step in 0..<FluxColumnsAnimation.steps {
            let lit = (0..<FluxColumnsAnimation.steps).map { FluxColumnsAnimation.colors(forPhase: $0)[step] }
            XCTAssertEqual(lit[step], palette[0], "Step \(step) lights phase \(step)")
            let behind = (step + FluxColumnsAnimation.steps - 1) % FluxColumnsAnimation.steps
            XCTAssertEqual(lit[behind], palette[1], "The dot it just left fades")
        }
    }

    func testFilledBonesAreDrawnAsDotMatrices() {
        let pitch = SkeletonLoaderView.dotPitch
        let dotRadius = SkeletonLoaderView.dotDiameter / 2

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
        XCTAssertLessThan(iconDots.count, 36, "A rounded icon drops its corner dots")
        XCTAssertGreaterThan(iconDots.count, 28)
    }

    func testAlternateColumnsRiseAndFall() {
        let steps = FluxColumnsAnimation.steps
        let square = SkeletonLoaderView.dots(in: CGRect(x: 0, y: 2, width: 24, height: 24), cornerRadius: 0)
        let columns = Dictionary(grouping: square) { $0.centre.x }.sorted { $0.key < $1.key }.map(\.value)
        XCTAssertEqual(columns.count, 6)
        for (index, column) in columns.enumerated() {
            let topToBottom = column.sorted { $0.centre.y < $1.centre.y }.map(\.fluxPhase)
            XCTAssertEqual(topToBottom.count, 6)
            // The head lights phase 0 first, so a rising snake's phases
            // count down the column and a falling one's count up.
            let stride = index % 2 == 0 ? steps - 1 : 1
            for (upper, lower) in zip(topToBottom, topToBottom.dropFirst()) {
                XCTAssertEqual(lower, (upper + stride) % steps, "Column \(index + 1): \(topToBottom)")
            }
        }
    }

    func testSnakesLineUpAcrossBones() {
        let upper = SkeletonLoaderView.dots(in: CGRect(x: 0, y: 2, width: 24, height: 8), cornerRadius: 0)
        let lower = SkeletonLoaderView.dots(in: CGRect(x: 0, y: 10, width: 24, height: 8), cornerRadius: 0)
        XCTAssertNotEqual(upper.map(\.fluxPhase), lower.map(\.fluxPhase),
                          "Bones at different heights light at different moments")
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
