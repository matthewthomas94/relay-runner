import AppKit
import XCTest
@testable import relay_runner

final class PermissionSetupCoordinatorTests: XCTestCase {

    func testInteractionPauseDebouncesRepeatedActivityAndDrag() {
        var model = PermissionCompanionInteractionModel()

        let first = model.recordUserActivity(now: 0)
        let second = model.recordUserActivity(now: 0.1)

        XCTAssertTrue(model.isPaused)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.pendingTimerID, second)

        model.fireIdleTimer(first)
        XCTAssertTrue(model.isPaused)

        model.beginRealDrag()
        XCTAssertTrue(model.isPaused)
        XCTAssertNil(model.pendingTimerID)

        let afterDrag = model.endRealDrag()
        model.fireIdleTimer(afterDrag)
        XCTAssertFalse(model.isPaused)
    }

    func testAnimationApproachesIconThenCarriesIconGhostWithCursorToTarget() {
        let idle = CGPoint(x: 10, y: 40)
        let icon = CGPoint(x: 60, y: 80)
        let target = CGPoint(x: 240, y: 180)

        let approach = PermissionCompanionAnimationPlanner.state(
            elapsed: 0.4,
            idlePoint: idle,
            iconCenter: icon,
            targetCenter: target,
            reduceMotion: false
        )
        let press = PermissionCompanionAnimationPlanner.state(
            elapsed: 0.7,
            idlePoint: idle,
            iconCenter: icon,
            targetCenter: target,
            reduceMotion: false
        )
        let drag = PermissionCompanionAnimationPlanner.state(
            elapsed: 1.2,
            idlePoint: idle,
            iconCenter: icon,
            targetCenter: target,
            reduceMotion: false
        )

        XCTAssertEqual(approach.phase, .approach)
        XCTAssertGreaterThan(approach.cursor.x, idle.x)
        XCTAssertLessThan(approach.cursor.x, icon.x)
        XCTAssertEqual(press.cursor, icon)
        XCTAssertEqual(drag.phase, .drag)
        XCTAssertEqual(drag.ghostCenter, drag.cursor)
        XCTAssertGreaterThan(drag.cursor.x, icon.x)
        XCTAssertLessThan(drag.cursor.x, target.x)
    }

    func testReduceMotionUsesStaticHint() {
        let state = PermissionCompanionAnimationPlanner.state(
            elapsed: 1.0,
            idlePoint: CGPoint(x: 1, y: 2),
            iconCenter: CGPoint(x: 3, y: 4),
            targetCenter: CGPoint(x: 5, y: 6),
            reduceMotion: true
        )

        XCTAssertEqual(state.phase, .staticHint)
        XCTAssertNil(state.ghostCenter)
        XCTAssertGreaterThan(state.dropCueOpacity, 0)
    }

    func testPlacementPrefersReachableBelowListCandidateBeforeOutsideFallbacks() {
        let settings = CGRect(x: 120, y: 120, width: 760, height: 620)
        let target = CGRect(x: 430, y: 340, width: 330, height: 220)
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 900)

        let plan = PermissionCompanionPlacementPlanner.plan(
            settingsFrame: settings,
            targetRect: target,
            visibleFrame: visible
        )

        XCTAssertEqual(plan.anchor, .belowList)
        XCTAssertEqual(plan.frame.maxY, target.minY - PermissionCompanionPlacementPlanner.preferredGap)
        XCTAssertFalse(plan.frame.intersects(target))
    }

    func testPlacementDoesNotClampInvalidBelowListCandidateBackOverSettings() {
        let settings = CGRect(x: 20, y: 110, width: 560, height: 420)
        let target = CGRect(x: 250, y: 150, width: 260, height: 250)
        let visible = CGRect(x: 0, y: 0, width: 700, height: 560)

        let plan = PermissionCompanionPlacementPlanner.plan(
            settingsFrame: settings,
            targetRect: target,
            visibleFrame: visible
        )

        XCTAssertNotEqual(plan.anchor, .belowList)
        XCTAssertFalse(plan.frame.intersects(target))
        XCTAssertTrue(visible.contains(plan.frame))
    }

    func testPlacementWorksOnNegativeOriginDisplays() {
        let settings = CGRect(x: -1130, y: 160, width: 760, height: 600)
        let target = CGRect(x: -820, y: 360, width: 320, height: 220)
        let visible = CGRect(x: -1280, y: 40, width: 1280, height: 760)

        let plan = PermissionCompanionPlacementPlanner.plan(
            settingsFrame: settings,
            targetRect: target,
            visibleFrame: visible
        )

        XCTAssertTrue(visible.contains(plan.frame))
        XCTAssertFalse(plan.frame.intersects(target))
    }

    func testTopLeftWindowBoundsConvertAgainstMatchingDisplay() {
        let display = PermissionDisplayGeometry(
            displayID: 2,
            cgBounds: CGRect(x: -1280, y: 0, width: 1280, height: 800),
            appKitFrame: CGRect(x: -1280, y: 0, width: 1280, height: 800),
            visibleFrame: CGRect(x: -1280, y: 40, width: 1280, height: 760)
        )

        let frame = PermissionSettingsWindowFinder.appKitFrame(
            fromTopLeftBounds: CGRect(x: -1180, y: 120, width: 600, height: 420),
            display: display
        )

        XCTAssertEqual(frame, CGRect(x: -1180, y: 260, width: 600, height: 420))
    }

    func testFallbackPlanAlwaysProvidesRevealActionAndPlusInstructions() {
        let missing = PermissionCompanionFallbackPlan.make(
            permission: .accessibility,
            purpose: "click",
            bundleURL: URL(fileURLWithPath: "/tmp/Relay Runner"),
            fileExists: { _ in false }
        )
        let installed = PermissionCompanionFallbackPlan.make(
            permission: .screenRecording,
            purpose: "screenshot",
            bundleURL: URL(fileURLWithPath: "/Applications/Relay Runner.app"),
            fileExists: { _ in true }
        )

        XCTAssertFalse(missing.payloadEnabled)
        XCTAssertEqual(missing.revealURL.path, "/Applications")
        XCTAssertTrue(missing.instructions.contains("+ button"))
        XCTAssertTrue(installed.payloadEnabled)
        XCTAssertEqual(installed.payloadURL?.path, "/Applications/Relay Runner.app")
        XCTAssertTrue(installed.instructions.contains("+ button"))
    }

    func testHostedToolPermissionClassification() {
        XCTAssertEqual(RelayHostedTool.requiredPermission(for: "click"), .accessibility)
        XCTAssertEqual(RelayHostedTool.requiredPermission(for: "screenshot"), .screenRecording)
        XCTAssertNil(RelayHostedTool.requiredPermission(for: "frontmost_app"))
        XCTAssertTrue(RelayHostedTool.isMissingPermissionFailure(
            "Accessibility permission is not granted to Relay Runner",
            for: .accessibility
        ))
        XCTAssertTrue(RelayHostedTool.isMissingPermissionFailure(
            "Screen Recording permission is not granted to Relay Runner",
            for: .screenRecording
        ))
    }

    func testSetupNotchLabels() {
        XCTAssertEqual(PermissionSetupNotchState.gettingStarted.label, "Getting started")
        XCTAssertEqual(PermissionSetupNotchState(permission: .microphone).label, "Microphone")
        XCTAssertEqual(PermissionSetupNotchState(permission: .accessibility).label, "Accessibility")
        XCTAssertEqual(PermissionSetupNotchState(permission: .inputMonitoring).label, "Input monitoring")
        XCTAssertEqual(PermissionSetupNotchState(permission: .screenRecording).label, "Screen recording")

        let presentation = AppState.setupNotchPresentation(
            onboardingActive: false,
            permissionState: .screenRecording
        )
        XCTAssertEqual(presentation?.activityLabels, ["Screen recording"])
        XCTAssertNil(AppState.setupNotchPresentation(onboardingActive: false, permissionState: nil))
    }

    func testDragPayloadUsesFileURLPasteboardType() {
        let url = URL(fileURLWithPath: "/Applications/Relay Runner.app")
        let item = AppFileDragPayload.pasteboardItem(url: url)

        XCTAssertTrue(item.types.contains(.fileURL))
        XCTAssertEqual(item.string(forType: .fileURL), url.absoluteString)
    }
}
