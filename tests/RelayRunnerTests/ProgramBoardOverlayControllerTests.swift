import XCTest
@testable import relay_runner

final class ProgramBoardOverlayControllerTests: XCTestCase {
    func testSessionControlActionStartsSelectedProjectWhenInactive() {
        let action = ProgramBoardOverlayController.sessionControlAction(
            hasActiveSession: false,
            selectedProjectPath: "/repo/client-dashboard"
        )

        XCTAssertEqual(action, .start("/repo/client-dashboard"))
    }

    func testSessionControlActionStartsDefaultSessionWhenNoProjectSelected() {
        let action = ProgramBoardOverlayController.sessionControlAction(
            hasActiveSession: false,
            selectedProjectPath: nil
        )

        XCTAssertEqual(action, .start(nil))
    }

    func testSessionControlActionEndsActiveSession() {
        let action = ProgramBoardOverlayController.sessionControlAction(
            hasActiveSession: true,
            selectedProjectPath: "/repo/client-dashboard"
        )

        XCTAssertEqual(action, .end)
    }

    func testSessionToolbarPresentationSwitchesBetweenStartAndEnd() {
        XCTAssertEqual(
            ProgramSessionToolbarPresentation.resolve(hasActiveSession: false),
            ProgramSessionToolbarPresentation(
                title: "Start session",
                systemName: "play.fill",
                help: "Start a Relay Runner voice session"
            )
        )
        XCTAssertEqual(
            ProgramSessionToolbarPresentation.resolve(hasActiveSession: true),
            ProgramSessionToolbarPresentation(
                title: "End session",
                systemName: "stop.fill",
                help: "End the active Relay Runner voice session"
            )
        )
    }
}
