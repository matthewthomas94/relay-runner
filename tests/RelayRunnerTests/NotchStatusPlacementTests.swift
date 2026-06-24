import XCTest
@testable import relay_runner

final class NotchStatusPlacementTests: XCTestCase {
    func testPlacesSurfaceToRightOfNotchAndBelowMenuBarArea() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            auxiliaryTopRightArea: CGRect(x: 800, y: 944, width: 712, height: 38)
        )

        let placement = try XCTUnwrap(NotchStatusPlacementPlanner.placement(for: geometry))

        XCTAssertEqual(placement.visibleFrame.size, NotchStatusPlacementPlanner.surfaceSize)
        XCTAssertGreaterThanOrEqual(placement.visibleFrame.minX, geometry.auxiliaryTopRightArea.minX)
        XCTAssertLessThanOrEqual(placement.visibleFrame.maxX, geometry.auxiliaryTopRightArea.maxX)
        XCTAssertLessThanOrEqual(placement.visibleFrame.maxY, geometry.auxiliaryTopRightArea.minY)
        XCTAssertLessThan(placement.retractedFrame.minX, placement.visibleFrame.minX)
    }

    func testHidesSurfaceWhenDisplayDoesNotReportNotchArea() {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            auxiliaryTopRightArea: .zero
        )

        XCTAssertNil(NotchStatusPlacementPlanner.placement(for: geometry))
    }

    func testHidesSurfaceWhenNotchRightAreaCannotFitIcon() {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240),
            auxiliaryTopRightArea: CGRect(x: 300, y: 216, width: 20, height: 24)
        )

        XCTAssertNil(NotchStatusPlacementPlanner.placement(for: geometry))
    }
}
