import XCTest
@testable import relay_runner

final class BoardOverlayControllerToggleTests: XCTestCase {
    func testToggleWithoutProjectUsesNoSessionHandler() {
        let controller = BoardOverlayController(boardRouteResolver: { .unavailable })
        var noSessionCount = 0
        controller.setNoSessionHandler {
            noSessionCount += 1
        }

        controller.toggle()

        XCTAssertEqual(noSessionCount, 1)
        XCTAssertFalse(controller.isVisible)
    }

    func testToggleForWorkspaceUsesProgramBoardHandler() {
        let controller = BoardOverlayController(boardRouteResolver: { .programBoard })
        var programBoardCount = 0
        controller.setProgramBoardHandler {
            programBoardCount += 1
        }

        controller.toggle()

        XCTAssertEqual(programBoardCount, 1)
        XCTAssertFalse(controller.isVisible)
    }
}
