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
        controller.setProgramBoardHandler { _ in
            programBoardCount += 1
        }

        controller.toggle()

        XCTAssertEqual(programBoardCount, 1)
        XCTAssertFalse(controller.isVisible)
    }

    func testUtilityWorkspaceUpgradeDecisionAddsWorkWhenRoutingAppears() {
        let project = ProjectResolver.LinkedProject(repoPath: URL(fileURLWithPath: "/repo"))

        XCTAssertEqual(
            BoardOverlayController.utilityRouteUpgrade(
                isVisible: true,
                showsWorkTab: false,
                route: .project(project)
            ),
            .project
        )
        XCTAssertEqual(
            BoardOverlayController.utilityRouteUpgrade(
                isVisible: true,
                showsWorkTab: false,
                route: .programBoard
            ),
            .programBoard
        )
        XCTAssertEqual(
            BoardOverlayController.utilityRouteUpgrade(
                isVisible: true,
                showsWorkTab: false,
                route: .unavailable
            ),
            .none
        )
        XCTAssertEqual(
            BoardOverlayController.utilityRouteUpgrade(
                isVisible: true,
                showsWorkTab: true,
                route: .programBoard
            ),
            .none
        )
    }
}
