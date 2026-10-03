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

        let gradients = (view.layer?.sublayers ?? []).compactMap { $0 as? CAGradientLayer }
        XCTAssertEqual(gradients.count, 1, "Only the bones shimmer")
        let gradient = try XCTUnwrap(gradients.first)
        XCTAssertEqual(gradient.opacity, 0.33, "The bones sit back at a third opacity")
        let shimmer = try XCTUnwrap(gradient.animation(forKey: SkeletonLoaderView.shimmerKey) as? CAAnimationGroup)
        XCTAssertEqual(shimmer.repeatCount, .infinity)
        let sweep = try XCTUnwrap(shimmer.animations?.first as? CABasicAnimation)
        XCTAssertEqual(sweep.keyPath, "locations")
        XCTAssertLessThan(sweep.duration, shimmer.duration, "Each pass rests before the next")
        XCTAssertNotEqual(sweep.timingFunction, CAMediaTimingFunction(name: .linear))
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
