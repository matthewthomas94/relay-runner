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
        let icon = CGPoint(x: 3, y: 4)
        let target = CGPoint(x: 50, y: 60)
        let state = PermissionCompanionAnimationPlanner.state(
            elapsed: 1.0,
            idlePoint: CGPoint(x: 1, y: 2),
            iconCenter: icon,
            targetCenter: target,
            reduceMotion: true
        )

        XCTAssertEqual(state.phase, .staticHint)
        XCTAssertNil(state.ghostCenter)
        XCTAssertGreaterThan(state.dropCueOpacity, 0)
        XCTAssertEqual(state.directionalHint?.start, icon)
        XCTAssertEqual(state.directionalHint?.end, target)
        XCTAssertFalse(PermissionCompanionDemoTimerPolicy.shouldRunTimer(reduceMotion: true, isPaused: false))
        XCTAssertFalse(PermissionCompanionDemoTimerPolicy.shouldRunTimer(reduceMotion: false, isPaused: true))
        XCTAssertTrue(PermissionCompanionDemoTimerPolicy.shouldRunTimer(reduceMotion: false, isPaused: false))
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

    func testSettingsFinderTargetRectAllowsBelowListPlacementOnOrdinaryWindow() {
        let settings = CGRect(x: 120, y: 120, width: 760, height: 620)
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let target = PermissionSettingsWindowFinder.targetRect(in: settings)

        let plan = PermissionCompanionPlacementPlanner.plan(
            settingsFrame: settings,
            targetRect: target,
            visibleFrame: visible
        )

        XCTAssertEqual(plan.anchor, .belowList)
        XCTAssertTrue(settings.contains(plan.frame))
        XCTAssertEqual(plan.frame.maxY, target.minY - PermissionCompanionPlacementPlanner.preferredGap)
        XCTAssertFalse(plan.frame.intersects(target))
    }

    func testPendingDiscoveryFallbackIsBottomCenter() {
        let visible = CGRect(x: -300, y: 40, width: 900, height: 700)
        let frame = PermissionCompanionPlacementPlanner.pendingDiscoveryFallbackFrame(visibleFrame: visible)

        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertEqual(frame.minY, visible.minY + PermissionCompanionPlacementPlanner.preferredGap)
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

    func testFallbackPlanDefaultsAccessibilityPurposeToRelayActions() {
        let plan = PermissionCompanionFallbackPlan.make(
            permission: .accessibility,
            purpose: "",
            bundleURL: URL(fileURLWithPath: "/Applications/Relay Runner.app"),
            fileExists: { _ in true }
        )

        XCTAssertTrue(plan.instructions.contains("Relay Actions"))
        XCTAssertTrue(plan.instructions.contains("clicking"))
        XCTAssertTrue(plan.instructions.contains("pressing keys"))
        XCTAssertFalse(plan.instructions.contains("trigger keys"))
        XCTAssertTrue(plan.accessibilityLabel.contains("UI automation"))
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
        XCTAssertEqual(PermissionSetupNotchState.granted(.accessibility).label, "Accessibility granted")

        let presentation = AppState.setupNotchPresentation(
            onboardingActive: false,
            permissionState: .screenRecording
        )
        XCTAssertEqual(presentation?.activityLabels, ["Screen recording"])
        let grantedPresentation = AppState.setupNotchPresentation(
            onboardingActive: false,
            permissionState: .granted(.accessibility)
        )
        XCTAssertEqual(grantedPresentation?.status, .working)
        XCTAssertEqual(grantedPresentation?.activityLabels, ["Accessibility granted"])
        XCTAssertNil(AppState.setupNotchPresentation(onboardingActive: false, permissionState: nil))
    }

    func testCompanionTileStyleMatchesReferenceConstants() {
        XCTAssertEqual(PermissionCompanionPlacementPlanner.companionSize, CGSize(width: 140, height: 142))
        XCTAssertEqual(PermissionCompanionTileStyle.size, CGSize(width: 140, height: 142))
        XCTAssertEqual(PermissionCompanionTileStyle.cornerRadius, 16)
        XCTAssertEqual(PermissionCompanionTileStyle.iconSize, 90)
        XCTAssertEqual(PermissionCompanionTileStyle.normalBorderOpacity, 0)
    }

    func testNativeHandCursorArtworkFollowsDragPhase() {
        XCTAssertEqual(PermissionCompanionCursorArtwork.artwork(for: .staticHint), .openHand)
        XCTAssertEqual(PermissionCompanionCursorArtwork.artwork(for: .approach), .openHand)
        XCTAssertEqual(PermissionCompanionCursorArtwork.artwork(for: .press), .closedHand)
        XCTAssertEqual(PermissionCompanionCursorArtwork.artwork(for: .drag), .closedHand)
        XCTAssertEqual(PermissionCompanionCursorArtwork.artwork(for: .release), .openHand)
        XCTAssertEqual(PermissionCompanionCursorArtwork.artwork(for: .hold), .openHand)
        XCTAssertEqual(PermissionCompanionCursorArtwork.artwork(for: .reset), .openHand)

        let frame = PermissionCompanionCursorArtwork.drawFrame(
            for: CGPoint(x: 80, y: 90),
            imageSize: CGSize(width: 32, height: 32),
            hotSpot: CGPoint(x: 7, y: 9)
        )
        XCTAssertEqual(frame.origin, CGPoint(x: 73, y: 81))
        XCTAssertEqual(frame.size, CGSize(width: 32, height: 32))
    }

    func testDragPayloadUsesNativeURLAndFinderFileRepresentations() {
        let url = URL(fileURLWithPath: "/Applications/Relay Runner.app")
        let writer = AppFileDragPasteboardWriter(url: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RR-177-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let types = writer.writableTypes(for: pasteboard)

        XCTAssertTrue(types.contains(.fileURL))
        XCTAssertTrue(types.contains(AppFileDragPayload.finderFileListType))
        XCTAssertNotNil(writer.pasteboardPropertyList(forType: .fileURL))
        XCTAssertEqual(
            writer.pasteboardPropertyList(forType: AppFileDragPayload.finderFileListType) as? [String],
            [url.path]
        )
    }

    func testDragImageFrameStaysUnderCursor() {
        let frame = AppFileDragPayload.draggingFrame(
            cursorPoint: CGPoint(x: 120, y: 80),
            imageSize: CGSize(width: 72, height: 72)
        )

        XCTAssertEqual(frame.midX, 120)
        XCTAssertEqual(frame.midY, 80)
        XCTAssertEqual(frame.size, CGSize(width: 72, height: 72))
    }

    func testGrantDuringDragClearsDeferralBeforePostingGrantReady() {
        let permissions = FakePermissionSetupPermissions()
        let companion = FakePermissionSetupCompanion()
        var notchStates: [PermissionSetupNotchState?] = []
        var posts: [(PermissionKind, PermissionSetupSource)] = []
        var coordinator: PermissionSetupCoordinator!
        coordinator = PermissionSetupCoordinator(
            permissions: permissions,
            setSetupNotchState: { notchStates.append($0) },
            postGrantReady: { kind, source in
                XCTAssertFalse(coordinator.shouldDeferAutoAdvance(for: kind))
                posts.append((kind, source))
            },
            companion: companion,
            successAcknowledgementDelay: 0
        )

        permissions.statuses[.accessibility] = .denied
        coordinator.request(.accessibility, source: .onboarding, purpose: "Relay Actions")
        companion.setRealDragActive(true)
        permissions.statuses[.accessibility] = .granted
        coordinator.permissionStatusChanged(.accessibility, status: .granted)

        XCTAssertTrue(coordinator.isGrantDeferredByDrag)

        companion.setRealDragActive(false)

        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.0, .accessibility)
        XCTAssertEqual(posts.first?.1, .onboarding)
        XCTAssertEqual(companion.successRequests.count, 1)
        XCTAssertTrue(notchStates.contains(.granted(.accessibility)))
        XCTAssertNil(notchStates.last!)
        XCTAssertNil(coordinator.activePermission)

        coordinator.permissionStatusChanged(.accessibility, status: .granted)
        XCTAssertEqual(posts.count, 1)
    }

    func testMicrophoneDenialPostsEndedWithoutGrantAfterClearingNotch() {
        let permissions = FakePermissionSetupPermissions()
        let companion = FakePermissionSetupCompanion()
        var notchStates: [PermissionSetupNotchState?] = []
        var ended: [(PermissionKind, PermissionSetupSource)] = []
        var coordinator: PermissionSetupCoordinator!
        coordinator = PermissionSetupCoordinator(
            permissions: permissions,
            setSetupNotchState: { notchStates.append($0) },
            postEndedWithoutGrant: { kind, source in
                XCTAssertNil(coordinator.activePermission)
                XCTAssertNil(notchStates.last!)
                ended.append((kind, source))
            },
            companion: companion,
            successAcknowledgementDelay: 0
        )

        coordinator.request(.microphone, source: .onboarding, purpose: "Voice")
        let cancelCountAfterStart = companion.cancelCount
        permissions.microphoneCompletion?(false)

        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.0, .microphone)
        XCTAssertEqual(ended.first?.1, .onboarding)
        XCTAssertEqual(notchStates, [.microphone, nil])
        XCTAssertEqual(companion.cancelCount, cancelCountAfterStart + 1)
    }

    func testSettingsLifecycleEndPostsEndedWithoutGrantAfterClearingNotch() {
        let permissions = FakePermissionSetupPermissions()
        let companion = FakePermissionSetupCompanion()
        var notchStates: [PermissionSetupNotchState?] = []
        var ended: [(PermissionKind, PermissionSetupSource)] = []
        var coordinator: PermissionSetupCoordinator!
        coordinator = PermissionSetupCoordinator(
            permissions: permissions,
            setSetupNotchState: { notchStates.append($0) },
            postEndedWithoutGrant: { kind, source in
                XCTAssertNil(coordinator.activePermission)
                XCTAssertNil(notchStates.last!)
                ended.append((kind, source))
            },
            companion: companion,
            successAcknowledgementDelay: 0
        )

        permissions.statuses[.inputMonitoring] = .denied
        coordinator.request(.inputMonitoring, source: .onboarding, purpose: "Hotkeys")
        let cancelCountAfterStart = companion.cancelCount
        companion.endLifecycle()

        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.0, .inputMonitoring)
        XCTAssertEqual(ended.first?.1, .onboarding)
        XCTAssertEqual(notchStates, [.inputMonitoring, nil])
        XCTAssertEqual(companion.cancelCount, cancelCountAfterStart + 1)
    }
}

private final class FakePermissionSetupPermissions: PermissionSetupPermissionManaging {
    var statuses: [PermissionKind: PermissionStatus] = [:]
    var microphoneCompletion: ((Bool) -> Void)?
    private(set) var promptedAccessibility = false
    private(set) var promptedInputMonitoring = false
    private(set) var promptedScreenRecording = false
    private(set) var registeredInputMonitoring = false
    private(set) var openedSettings: [PermissionKind] = []

    func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .denied
    }

    func requestMicrophonePrompt(completion: @escaping (Bool) -> Void) {
        microphoneCompletion = completion
    }

    func promptAccessibility() {
        promptedAccessibility = true
    }

    func registerForInputMonitoringList() {
        registeredInputMonitoring = true
    }

    func promptInputMonitoring() {
        promptedInputMonitoring = true
    }

    func promptScreenRecording() {
        promptedScreenRecording = true
    }

    func openSettings(for kind: PermissionKind) {
        openedSettings.append(kind)
    }
}

private final class FakePermissionSetupCompanion: PermissionSetupCompanionControlling {
    var isRealDragActive = false
    private(set) var shownRequests: [PermissionSetupRequest] = []
    private(set) var successRequests: [PermissionSetupRequest] = []
    private(set) var cancelCount = 0
    private var onDragStateChanged: ((Bool) -> Void)?
    private var onLifecycleEnded: (() -> Void)?

    func show(request: PermissionSetupRequest,
              onDragStateChanged: @escaping (Bool) -> Void,
              onLifecycleEnded: @escaping () -> Void) {
        shownRequests.append(request)
        self.onDragStateChanged = onDragStateChanged
        self.onLifecycleEnded = onLifecycleEnded
    }

    func showSuccess(for request: PermissionSetupRequest) {
        successRequests.append(request)
    }

    func cancel() {
        cancelCount += 1
        isRealDragActive = false
    }

    func setRealDragActive(_ active: Bool) {
        isRealDragActive = active
        onDragStateChanged?(active)
    }

    func endLifecycle() {
        onLifecycleEnded?()
    }
}
