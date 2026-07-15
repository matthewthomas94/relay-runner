import XCTest
@testable import relay_runner

final class AppStateLaunchTests: XCTestCase {
    func testWorkspaceToggleResumesSuspendedProgramBoardDirectly() {
        XCTAssertEqual(
            AppState.workspaceToggleTarget(
                programBoardVisible: false,
                programBoardSuspended: true
            ),
            .programBoard
        )
        XCTAssertEqual(
            AppState.workspaceToggleTarget(
                programBoardVisible: false,
                programBoardSuspended: false
            ),
            .projectBoard
        )
    }

    func testLaunchPlanStartsOverlayWithoutMicrophonePermission() {
        let plan = AppState.launchPlan(for: .denied)

        XCTAssertTrue(plan.startsOverlay)
        XCTAssertFalse(plan.startsAwareness)
        XCTAssertEqual(plan.statusText, "Microphone permission needed")
    }

    func testLaunchPlanStartsOverlayAndAwarenessWhenMicrophoneGranted() {
        let plan = AppState.launchPlan(for: .granted)

        XCTAssertTrue(plan.startsOverlay)
        XCTAssertTrue(plan.startsAwareness)
        XCTAssertNil(plan.statusText)
    }

    func testSessionLaunchConfigCanUseScopedWorkingDirectoryWithoutMutatingSavedConfig() {
        var config = AppConfig()
        config.general.working_directory = "/Users/example/dev"

        let scoped = AppState.sessionLaunchConfig(
            from: config,
            workingDirectory: " /Users/example/dev/brain-stack "
        )
        let global = AppState.sessionLaunchConfig(from: config, workingDirectory: nil)
        let blank = AppState.sessionLaunchConfig(from: config, workingDirectory: "   ")

        XCTAssertEqual(scoped.general.working_directory, "/Users/example/dev/brain-stack")
        XCTAssertEqual(global.general.working_directory, "/Users/example/dev")
        XCTAssertEqual(blank.general.working_directory, "/Users/example/dev")
        XCTAssertEqual(config.general.working_directory, "/Users/example/dev")
    }

    func testSessionLaunchRequestDefaultsToEmbeddedAndPreservesExternalFallback() {
        var config = AppConfig()
        config.general.working_directory = "/Users/example/dev"

        let embedded = AppState.sessionLaunchRequest(
            from: config,
            workingDirectory: "/Users/example/dev/project"
        )
        let external = AppState.sessionLaunchRequest(
            from: config,
            workingDirectory: nil,
            destination: .externalTerminal
        )

        XCTAssertEqual(embedded.destination, .embedded)
        XCTAssertEqual(embedded.config.general.working_directory, "/Users/example/dev/project")
        XCTAssertEqual(external.destination, .externalTerminal)
        XCTAssertEqual(external.config.general.working_directory, "/Users/example/dev")
        XCTAssertEqual(config.general.working_directory, "/Users/example/dev")
    }
}
