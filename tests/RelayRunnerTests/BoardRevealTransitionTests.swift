import XCTest
@testable import relay_runner

final class BoardRevealTransitionTests: XCTestCase {
    func testRevealPlanStartsAsCenteredCompactNotchOnExternalDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

        let plan = BoardRevealTransitionPlanner.plan(for: screen, notchPlacement: nil)

        XCTAssertEqual(plan.compactFrame.width, BoardRevealTransitionPlanner.minimumCompactWidth)
        XCTAssertEqual(plan.compactFrame.height, NotchStatusPlacementPlanner.glyphSize.height)
        XCTAssertEqual(plan.compactFrame.midX, screen.width / 2)
        XCTAssertEqual(plan.fullWidthFrame, CGRect(x: 0, y: 0, width: 1512, height: 34))
        XCTAssertEqual(plan.expandedFrame, CGRect(x: 0, y: 0, width: 1512, height: 735))
        XCTAssertEqual(plan.glyphFrame.maxX, plan.compactFrame.maxX)
    }

    func testRevealPlanUsesNotchPlacementWhenAvailable() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 100, y: 50, width: 1512, height: 982),
            visibleFrame: CGRect(x: 100, y: 50, width: 1512, height: 944),
            auxiliaryTopLeftArea: CGRect(x: 100, y: 1000, width: 663, height: 32),
            auxiliaryTopRightArea: CGRect(x: 948, y: 1000, width: 664, height: 32)
        )
        let placement = try XCTUnwrap(NotchStatusPlacementPlanner.placement(for: geometry))

        let plan = BoardRevealTransitionPlanner.plan(for: geometry.frame, notchPlacement: placement)

        XCTAssertGreaterThanOrEqual(plan.compactFrame.width, placement.visibleFrame.width)
        XCTAssertEqual(plan.compactFrame.midX, placement.visibleFrame.midX - geometry.frame.minX)
        XCTAssertEqual(plan.glyphFrame.minX, placement.glyphScreenX - geometry.frame.minX)
        XCTAssertEqual(plan.fullWidthFrame.maxX, geometry.frame.width)
    }

    func testRevealPlanClampsExpandedHeightOnShortScreens() {
        let screen = CGRect(x: 0, y: 0, width: 960, height: 420)

        let plan = BoardRevealTransitionPlanner.plan(for: screen, notchPlacement: nil)

        XCTAssertEqual(
            plan.expandedFrame.height,
            screen.height - BoardRevealTransitionPlanner.bottomScreenMargin
        )
        XCTAssertGreaterThan(plan.expandedFrame.height, NotchStatusPlacementPlanner.glyphSize.height)
    }
}
