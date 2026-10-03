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

        let bones = SkeletonLoaderView.bones(for: .board(columnTop: boardTop), in: bounds, clearing: .null)
        for panel in panels {
            let cards = bones.filter { $0.style == .outline && panel.contains($0.rect) }
            XCTAssertFalse(cards.isEmpty, "Every column shows cards")
        }
        let overviewCards = bones.filter { $0.style == .outline && panels[0].contains($0.rect) }
        XCTAssertEqual(overviewCards.first?.rect.height, ProgramBoardLayout.projectCardHeight)
    }

    func testTerminalSkeletonSketchesAWelcomeOutputAndPrompt() throws {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 667)
        let bones = SkeletonLoaderView.bones(for: .terminal, in: bounds, clearing: .null)
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

    func testBonesKeepClearOfTheLabel() {
        for (layout, size) in [
            (SkeletonLoaderLayout.board(columnTop: boardTop), CGSize(width: 1_400, height: 760)),
            (.terminal, CGSize(width: 900, height: 420)),
        ] {
            let view = SkeletonLoaderView(layout: layout, label: BoardUpdateStatus.workingLabel)
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.labelView.frame.midX, size.width / 2, accuracy: 1)
            XCTAssertEqual(view.labelView.frame.midY, size.height / 2, accuracy: 1)
            XCTAssertFalse(view.bones.isEmpty)
            for bone in view.bones {
                XCTAssertFalse(bone.rect.intersects(view.labelClearing), "\(layout): \(bone.rect)")
            }
        }
    }

    func testLoaderShimmersWithoutTakingClicks() throws {
        try XCTSkipIf(RelayLayerMotion.reduceMotion, "Reduce Motion holds the shimmer still")
        let view = SkeletonLoaderView(layout: .terminal, label: "Starting Claude")
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 667)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.hitTest(CGPoint(x: 450, y: 333)))
        XCTAssertEqual(view.accessibilityLabel(), "Starting Claude")

        let gradients = (view.layer?.sublayers ?? []).compactMap { $0 as? CAGradientLayer }
            + (view.labelView.layer?.sublayers ?? []).compactMap { $0 as? CAGradientLayer }
        XCTAssertEqual(gradients.count, 2, "The bones and the label each shimmer")
        XCTAssertEqual(gradients.first?.opacity, SkeletonLoaderView.boneOpacity, "The bones sit back behind the label")
        for gradient in gradients {
            let shimmer = try XCTUnwrap(gradient.animation(forKey: SkeletonLoaderView.shimmerKey) as? CAAnimationGroup)
            XCTAssertEqual(shimmer.repeatCount, .infinity)
            let sweep = try XCTUnwrap(shimmer.animations?.first as? CABasicAnimation)
            XCTAssertEqual(sweep.keyPath, "locations")
            XCTAssertLessThan(sweep.duration, shimmer.duration, "Each pass rests before the next")
            XCTAssertNotEqual(sweep.timingFunction, CAMediaTimingFunction(name: .linear))
        }
    }

    func testLabelChangesWithoutAWindowApplyAtOnce() {
        let view = SkeletonLoaderView(layout: .terminal, label: "Updating Codex")
        view.setLabel("Starting Codex", animated: true)
        XCTAssertEqual(view.labelView.text, "Starting Codex")
        XCTAssertEqual(view.accessibilityLabel(), "Starting Codex")
    }

    func testLoaderLabelsHaveNoEllipsis() {
        XCTAssertFalse(BoardUpdateStatus.workingLabel.contains("…"))
        XCTAssertFalse(BoardUpdateStatus.workingLabel.hasSuffix("..."))
    }
}
