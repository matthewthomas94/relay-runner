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
}
