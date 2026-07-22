import XCTest
@testable import relay_runner

final class AppStateLaunchTests: XCTestCase {
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

    func testOnboardingNotchOverrideUsesNotWorkingPresentation() {
        let presentation = AppState.onboardingNotchPresentation(active: true)

        XCTAssertEqual(presentation?.status, .notWorking)
        XCTAssertEqual(presentation?.activityLabels, ["Getting started"])
        XCTAssertNil(presentation?.workingProgressLabel)
        XCTAssertNil(AppState.onboardingNotchPresentation(active: false))
    }

    func testFirstRunExperienceLocksOrdinaryAppShell() {
        XCTAssertTrue(AppState.allowsAppShellAccess(firstRunExperienceActive: false))
        XCTAssertFalse(AppState.allowsAppShellAccess(firstRunExperienceActive: true))
    }

    func testCompletedSetupOverridesStaleCompilingStatus() {
        let readiness = AppState.setupRuntimeReadiness(
            engineStatusMessage: "Compiling parakeet-tdt-v2...",
            engineError: nil,
            setupSucceeded: true,
            startedAt: nil
        )

        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(readiness.statusDetail, "Loaded and listening")
    }
}
