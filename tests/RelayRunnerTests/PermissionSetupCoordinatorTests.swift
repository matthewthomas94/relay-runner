import AppKit
import SwiftUI
import XCTest
@testable import relay_runner

final class PermissionSetupCoordinatorTests: XCTestCase {

    func testInteractionPauseDebouncesRepeatedActivityAndDrag() {
        var model = PermissionCompanionInteractionModel()

        let first = model.recordUserActivity(now: 0)!
        let second = model.recordUserActivity(now: 0.1)!

        XCTAssertTrue(model.isPaused)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.pendingTimerID, second)

        model.fireIdleTimer(first)
        XCTAssertTrue(model.isPaused)

        model.beginRealDrag()
        XCTAssertTrue(model.isPaused)
        XCTAssertNil(model.pendingTimerID)

        let afterDrag = model.endRealDrag()!
        model.fireIdleTimer(afterDrag)
        XCTAssertFalse(model.isPaused)
    }

    func testInteractionHoverPausesOnceAndResumesOnceAfterExit() {
        var model = PermissionCompanionInteractionModel()

        XCTAssertTrue(model.beginHover())
        XCTAssertFalse(model.beginHover())
        XCTAssertTrue(model.isPaused)
        XCTAssertTrue(model.hoverActive)
        XCTAssertNil(model.pendingTimerID)

        XCTAssertNil(model.recordUserActivity())
        XCTAssertNil(model.pendingTimerID)

        let resume = model.endHover()
        XCTAssertNotNil(resume)
        XCTAssertNil(model.endHover())
        XCTAssertEqual(model.pendingTimerID, resume)

        model.fireIdleTimer(resume!)
        XCTAssertFalse(model.isPaused)
        XCTAssertFalse(model.hoverActive)
    }

    func testInteractionDragEndingWhileStillHoveringWaitsForExitBeforeResume() {
        var model = PermissionCompanionInteractionModel()

        XCTAssertTrue(model.beginHover())
        model.beginRealDrag()

        XCTAssertTrue(model.isPaused)
        XCTAssertTrue(model.hoverActive)
        XCTAssertNil(model.pendingTimerID)
        XCTAssertNil(model.endRealDrag())
        XCTAssertTrue(model.isPaused)
        XCTAssertTrue(model.hoverActive)
        XCTAssertNil(model.pendingTimerID)

        let resume = model.endHover()

        XCTAssertNotNil(resume)
        XCTAssertEqual(model.pendingTimerID, resume)
        XCTAssertNil(model.endHover())
        model.fireIdleTimer(resume!)
        XCTAssertFalse(model.isPaused)
        XCTAssertFalse(model.hoverActive)
    }

    func testInteractionDragEndingAfterHoverExitSchedulesOneResume() {
        var model = PermissionCompanionInteractionModel()

        XCTAssertTrue(model.beginHover())
        model.beginRealDrag()

        XCTAssertNil(model.endHover())
        XCTAssertTrue(model.isPaused)
        XCTAssertFalse(model.hoverActive)
        XCTAssertNil(model.pendingTimerID)

        let resume = model.endRealDrag()

        XCTAssertNotNil(resume)
        XCTAssertEqual(model.pendingTimerID, resume)
        XCTAssertNil(model.endRealDrag())
        XCTAssertEqual(model.pendingTimerID, resume)
        model.fireIdleTimer(resume!)
        XCTAssertFalse(model.isPaused)
    }

    func testDemoClockAccumulatesDisplayLinkElapsedAndFreezesWhilePaused() {
        var clock = PermissionCompanionDemoClock()

        clock.tick(timestamp: 10.0, isPaused: false)
        clock.tick(timestamp: 10.0083, isPaused: false)
        XCTAssertEqual(clock.elapsed, 0.0083, accuracy: 0.0001)

        clock.tick(timestamp: 12.0, isPaused: true)
        XCTAssertEqual(clock.elapsed, 0.0083, accuracy: 0.0001)

        clock.tick(timestamp: 20.0, isPaused: false)
        XCTAssertEqual(clock.elapsed, 0.0083, accuracy: 0.0001)
        clock.tick(timestamp: 20.0167, isPaused: false)
        XCTAssertEqual(clock.elapsed, 0.025, accuracy: 0.0001)
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
        let linearDragX = icon.x + (target.x - icon.x) * CGFloat((1.2 - 0.82) / 1.13)
        XCTAssertLessThan(drag.cursor.x, linearDragX)
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
        XCTAssertEqual(state.directionalHint?.start, icon)
        XCTAssertEqual(state.directionalHint?.end, target)
        XCTAssertFalse(PermissionCompanionDemoDisplayPolicy.shouldRunDisplayLink(reduceMotion: true, isPaused: false))
        XCTAssertFalse(PermissionCompanionDemoDisplayPolicy.shouldRunDisplayLink(reduceMotion: false, isPaused: true))
        XCTAssertTrue(PermissionCompanionDemoDisplayPolicy.shouldRunDisplayLink(reduceMotion: false, isPaused: false))
    }

    func testReleasePhaseKeepsGhostAtDestinationWithoutExtraCueState() {
        let state = PermissionCompanionAnimationPlanner.state(
            elapsed: 2.0,
            idlePoint: CGPoint(x: 1, y: 2),
            iconCenter: CGPoint(x: 20, y: 30),
            targetCenter: CGPoint(x: 90, y: 110),
            reduceMotion: false
        )

        XCTAssertEqual(state.phase, .release)
        XCTAssertNotNil(state.ghostCenter)
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
            bundleIdentity: { Self.relayIdentity(for: $0) },
            fileExists: Self.relayBundleFileExists,
            isExecutableFile: Self.relayBundleIsExecutable
        )

        XCTAssertFalse(missing.payloadEnabled)
        XCTAssertEqual(missing.revealURL.path, "/Applications")
        XCTAssertTrue(missing.instructions.contains("+ button"))
        XCTAssertTrue(installed.payloadEnabled)
        XCTAssertEqual(installed.payloadURL?.path, "/Applications/Relay Runner.app")
        XCTAssertTrue(installed.instructions.contains("+ button"))
    }

    func testFallbackPlanEnablesValidRelayRunnerBundleOutsideApplications() {
        let customInstall = URL(fileURLWithPath: "/Users/example/Applications/Relay Runner.app", isDirectory: true)
        let plan = PermissionCompanionFallbackPlan.make(
            permission: .inputMonitoring,
            purpose: "Hotkeys",
            bundleURL: customInstall,
            bundleIdentity: { Self.relayIdentity(for: $0) },
            fileExists: Self.relayBundleFileExists,
            isExecutableFile: Self.relayBundleIsExecutable
        )

        XCTAssertTrue(plan.payloadEnabled)
        XCTAssertEqual(plan.payloadURL?.path, customInstall.path)
        XCTAssertEqual(plan.revealURL.path, customInstall.path)
    }

    func testFallbackPlanRejectsInvalidRelayRunnerBundlePayloads() {
        let developmentCopy = URL(fileURLWithPath: "/Users/example/Downloads/Relay Runner.app", isDirectory: true)
        let otherApp = URL(fileURLWithPath: "/Applications/Other.app", isDirectory: true)
        let wrongBundleIdentifier = URL(fileURLWithPath: "/Users/example/WrongIdentifier/Relay Runner.app", isDirectory: true)
        let wrongExecutableName = URL(fileURLWithPath: "/Users/example/WrongExecutable/Relay Runner.app", isDirectory: true)
        let executableOutsideBundle = URL(fileURLWithPath: "/Users/example/OutsideExecutable/Relay Runner.app", isDirectory: true)
        let nonExecutable = URL(fileURLWithPath: "/Users/example/NonExecutable/Relay Runner.app", isDirectory: true)

        let missingIdentity = PermissionCompanionFallbackPlan.make(
            permission: .inputMonitoring,
            purpose: "Hotkeys",
            bundleURL: developmentCopy,
            fileExists: { _ in true }
        )
        let wrongBundle = PermissionCompanionFallbackPlan.make(
            permission: .inputMonitoring,
            purpose: "Hotkeys",
            bundleURL: otherApp,
            fileExists: { _ in true }
        )
        let wrongBundleIdentifierPlan = PermissionCompanionFallbackPlan.make(
            permission: .inputMonitoring,
            purpose: "Hotkeys",
            bundleURL: wrongBundleIdentifier,
            bundleIdentity: {
                PermissionCompanionAppBundleIdentity(
                    bundleIdentifier: "com.example.Other",
                    executableName: PermissionCompanionAppBundleIdentity.relayRunnerExecutableName,
                    executableURL: $0.appendingPathComponent("Contents/MacOS/relay-runner")
                )
            },
            fileExists: Self.relayBundleFileExists,
            isExecutableFile: Self.relayBundleIsExecutable
        )
        let wrongExecutablePlan = PermissionCompanionFallbackPlan.make(
            permission: .inputMonitoring,
            purpose: "Hotkeys",
            bundleURL: wrongExecutableName,
            bundleIdentity: {
                PermissionCompanionAppBundleIdentity(
                    bundleIdentifier: PermissionCompanionAppBundleIdentity.relayRunnerBundleIdentifier,
                    executableName: "RelayRunnerDev",
                    executableURL: $0.appendingPathComponent("Contents/MacOS/RelayRunnerDev")
                )
            },
            fileExists: { _ in true }
        )
        let outsideExecutablePlan = PermissionCompanionFallbackPlan.make(
            permission: .inputMonitoring,
            purpose: "Hotkeys",
            bundleURL: executableOutsideBundle,
            bundleIdentity: { _ in
                PermissionCompanionAppBundleIdentity(
                    bundleIdentifier: PermissionCompanionAppBundleIdentity.relayRunnerBundleIdentifier,
                    executableName: PermissionCompanionAppBundleIdentity.relayRunnerExecutableName,
                    executableURL: URL(fileURLWithPath: "/tmp/relay-runner")
                )
            },
            fileExists: { path in
                path == executableOutsideBundle.path || path == "/tmp/relay-runner"
            },
            isExecutableFile: { $0 == "/tmp/relay-runner" }
        )
        let nonExecutablePlan = PermissionCompanionFallbackPlan.make(
            permission: .inputMonitoring,
            purpose: "Hotkeys",
            bundleURL: nonExecutable,
            bundleIdentity: { Self.relayIdentity(for: $0) },
            fileExists: Self.relayBundleFileExists,
            isExecutableFile: { _ in false }
        )

        XCTAssertFalse(missingIdentity.payloadEnabled)
        XCTAssertNil(missingIdentity.payloadURL)
        XCTAssertEqual(missingIdentity.revealURL.path, developmentCopy.path)
        XCTAssertFalse(wrongBundle.payloadEnabled)
        XCTAssertNil(wrongBundle.payloadURL)
        XCTAssertFalse(wrongBundleIdentifierPlan.payloadEnabled)
        XCTAssertNil(wrongBundleIdentifierPlan.payloadURL)
        XCTAssertFalse(wrongExecutablePlan.payloadEnabled)
        XCTAssertNil(wrongExecutablePlan.payloadURL)
        XCTAssertFalse(outsideExecutablePlan.payloadEnabled)
        XCTAssertNil(outsideExecutablePlan.payloadURL)
        XCTAssertFalse(nonExecutablePlan.payloadEnabled)
        XCTAssertNil(nonExecutablePlan.payloadURL)
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

    func testHostedAppFileDragStartsOneSessionFromMouseDownEventAfterThreshold() {
        let view = AppFileDragView()
        view.frame = CGRect(x: 0, y: 0, width: 90, height: 90)
        view.bundleURL = URL(fileURLWithPath: "/Applications/Relay Runner.app", isDirectory: true)
        view.image = NSImage(size: CGSize(width: 90, height: 90))
        view.draggingEnabled = true

        let panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        defer { panel.close() }

        var startedSessions: [(itemCount: Int, event: NSEvent)] = []
        var dragStates: [Bool] = []
        var preventWindowOrderingCount = 0
        view.beginDraggingSessionHandler = { items, event in
            startedSessions.append((items.count, event))
        }
        view.onDragStateChanged = { dragStates.append($0) }
        view.preventWindowOrderingHandler = { preventWindowOrderingCount += 1 }

        let down = Self.mouseEvent(
            .leftMouseDown,
            location: CGPoint(x: 12, y: 12),
            windowNumber: panel.windowNumber,
            eventNumber: 1
        )
        let underThreshold = Self.mouseEvent(
            .leftMouseDragged,
            location: CGPoint(x: 14, y: 14),
            windowNumber: panel.windowNumber,
            eventNumber: 2
        )
        let overThreshold = Self.mouseEvent(
            .leftMouseDragged,
            location: CGPoint(x: 28, y: 27),
            windowNumber: panel.windowNumber,
            eventNumber: 3
        )
        let duplicateDrag = Self.mouseEvent(
            .leftMouseDragged,
            location: CGPoint(x: 44, y: 42),
            windowNumber: panel.windowNumber,
            eventNumber: 4
        )

        XCTAssertTrue(view.shouldDelayWindowOrdering(for: down))
        view.mouseDown(with: down)
        view.mouseDragged(with: underThreshold)
        XCTAssertTrue(startedSessions.isEmpty)

        view.mouseDragged(with: overThreshold)
        view.mouseDragged(with: duplicateDrag)

        XCTAssertEqual(startedSessions.count, 1)
        XCTAssertEqual(startedSessions.first?.itemCount, 1)
        XCTAssertTrue(startedSessions.first?.event === down)
        XCTAssertEqual(dragStates, [true])
        XCTAssertEqual(preventWindowOrderingCount, 1)
    }

    func testAppFileDragHoverUsesEdgesWithoutMouseMoveActivity() {
        let view = AppFileDragView()
        view.frame = CGRect(x: 0, y: 0, width: 90, height: 90)

        var hoverStates: [Bool] = []
        var interactionCount = 0
        view.onHoverChanged = { hoverStates.append($0) }
        view.onUserInteraction = { interactionCount += 1 }

        let moved = Self.mouseEvent(
            .mouseMoved,
            location: CGPoint(x: 12, y: 12),
            windowNumber: 0,
            eventNumber: 20
        )
        let entered = Self.mouseEvent(
            .mouseMoved,
            location: CGPoint(x: 12, y: 12),
            windowNumber: 0,
            eventNumber: 21
        )
        let exited = Self.mouseEvent(
            .mouseMoved,
            location: CGPoint(x: 120, y: 120),
            windowNumber: 0,
            eventNumber: 22
        )

        view.mouseEntered(with: entered)
        view.mouseMoved(with: moved)
        view.mouseMoved(with: moved)
        view.mouseExited(with: exited)

        XCTAssertEqual(hoverStates, [true, false])
        XCTAssertEqual(interactionCount, 0)
    }

    func testAppFileDragCallbacksKeepDemoPausedWhenDragEndsOverHoveringIcon() {
        let (view, panel) = Self.appDragViewInPanel()
        defer { panel.close() }

        let harness = PermissionCompanionInteractionHarness()
        harness.bind(to: view)

        Self.startDrag(from: view, in: panel, firstEventNumber: 23)
        view.onDragStateChanged(false)

        XCTAssertTrue(harness.model.isPaused)
        XCTAssertTrue(harness.model.hoverActive)
        XCTAssertTrue(harness.resumeTimers.isEmpty)

        view.mouseExited(with: Self.mouseEvent(
            .mouseMoved,
            location: CGPoint(x: 120, y: 120),
            windowNumber: panel.windowNumber,
            eventNumber: 26
        ))

        XCTAssertEqual(harness.resumeTimers.count, 1)
        XCTAssertEqual(harness.model.pendingTimerID, harness.resumeTimers.first)
    }

    func testAppFileDragCallbacksScheduleOneResumeWhenPointerExitsDuringDrag() {
        let (view, panel) = Self.appDragViewInPanel()
        defer { panel.close() }

        let harness = PermissionCompanionInteractionHarness()
        harness.bind(to: view)

        Self.startDrag(from: view, in: panel, firstEventNumber: 27)
        view.mouseExited(with: Self.mouseEvent(
            .mouseMoved,
            location: CGPoint(x: 120, y: 120),
            windowNumber: panel.windowNumber,
            eventNumber: 30
        ))

        XCTAssertTrue(harness.model.isPaused)
        XCTAssertFalse(harness.model.hoverActive)
        XCTAssertTrue(harness.resumeTimers.isEmpty)

        view.onDragStateChanged(false)
        view.onDragStateChanged(false)

        XCTAssertEqual(harness.resumeTimers.count, 1)
        XCTAssertEqual(harness.model.pendingTimerID, harness.resumeTimers.first)
    }

    func testAppFileDragSurvivesViewUpdateBetweenMouseDownAndThreshold() {
        let view = AppFileDragView()
        view.frame = CGRect(x: 0, y: 0, width: 90, height: 90)
        view.bundleURL = URL(fileURLWithPath: "/Applications/Relay Runner.app", isDirectory: true)
        view.image = NSImage(size: CGSize(width: 90, height: 90))
        view.draggingEnabled = true
        view.preventWindowOrderingHandler = {}

        let panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        defer { panel.close() }

        var startedSessions: [(itemCount: Int, event: NSEvent)] = []
        view.beginDraggingSessionHandler = { items, event in
            startedSessions.append((items.count, event))
        }

        let down = Self.mouseEvent(
            .leftMouseDown,
            location: CGPoint(x: 18, y: 18),
            windowNumber: panel.windowNumber,
            eventNumber: 10
        )
        view.mouseDown(with: down)

        view.bundleURL = URL(fileURLWithPath: "/Applications/Relay Runner.app", isDirectory: true)
        view.image = NSImage(size: CGSize(width: 90, height: 90))
        view.frame.size = CGSize(width: 90, height: 90)
        view.draggingEnabled = true

        let overThreshold = Self.mouseEvent(
            .leftMouseDragged,
            location: CGPoint(x: 32, y: 31),
            windowNumber: panel.windowNumber,
            eventNumber: 11
        )
        view.mouseDragged(with: overThreshold)

        XCTAssertEqual(startedSessions.count, 1)
        XCTAssertEqual(startedSessions.first?.itemCount, 1)
        XCTAssertTrue(startedSessions.first?.event === down)
    }

    func testHostedDraggableAppIconKeepsDragViewAcrossRootUpdatesDuringGesture() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Relay Runner.app", isDirectory: true)
        let hostingView = NSHostingView(rootView: Self.hostedDragIcon(bundleURL: bundleURL))
        hostingView.frame = CGRect(x: 0, y: 0, width: 90, height: 90)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        defer { panel.close() }

        hostingView.layoutSubtreeIfNeeded()
        guard let dragView = Self.firstSubview(of: AppFileDragView.self, in: hostingView) else {
            XCTFail("Expected hosted AppFileDragView")
            return
        }
        dragView.bundleURL = bundleURL
        dragView.image = NSImage(size: CGSize(width: 90, height: 90))
        dragView.draggingEnabled = true
        dragView.preventWindowOrderingHandler = {}

        var startedSessions: [(itemCount: Int, event: NSEvent)] = []
        dragView.beginDraggingSessionHandler = { items, event in
            startedSessions.append((items.count, event))
        }

        let down = Self.mouseEvent(
            .leftMouseDown,
            location: dragView.convert(CGPoint(x: 18, y: 18), to: nil),
            windowNumber: panel.windowNumber,
            eventNumber: 30
        )
        dragView.mouseDown(with: down)

        hostingView.rootView = Self.hostedDragIcon(bundleURL: bundleURL)
        hostingView.layoutSubtreeIfNeeded()
        guard let currentDragView = Self.firstSubview(of: AppFileDragView.self, in: hostingView) else {
            XCTFail("Expected hosted AppFileDragView after update")
            return
        }

        XCTAssertTrue(currentDragView === dragView)

        currentDragView.mouseDragged(with: Self.mouseEvent(
            .leftMouseDragged,
            location: currentDragView.convert(CGPoint(x: 34, y: 34), to: nil),
            windowNumber: panel.windowNumber,
            eventNumber: 31
        ))

        XCTAssertEqual(startedSessions.count, 1)
        XCTAssertTrue(startedSessions.first?.event === down)
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

private extension PermissionSetupCoordinatorTests {
    static func relayIdentity(for url: URL) -> PermissionCompanionAppBundleIdentity {
        PermissionCompanionAppBundleIdentity(
            bundleIdentifier: PermissionCompanionAppBundleIdentity.relayRunnerBundleIdentifier,
            executableName: PermissionCompanionAppBundleIdentity.relayRunnerExecutableName,
            executableURL: url.appendingPathComponent("Contents/MacOS/relay-runner")
        )
    }

    static func relayBundleFileExists(_ path: String) -> Bool {
        path.hasSuffix("Relay Runner.app") || path.hasSuffix("Relay Runner.app/Contents/MacOS/relay-runner")
    }

    static func relayBundleIsExecutable(_ path: String) -> Bool {
        path.hasSuffix("Relay Runner.app/Contents/MacOS/relay-runner")
    }

    static func appDragViewInPanel() -> (view: AppFileDragView, panel: NSPanel) {
        let view = AppFileDragView()
        view.frame = CGRect(x: 0, y: 0, width: 90, height: 90)
        view.bundleURL = URL(fileURLWithPath: "/Applications/Relay Runner.app", isDirectory: true)
        view.image = NSImage(size: CGSize(width: 90, height: 90))
        view.draggingEnabled = true
        view.preventWindowOrderingHandler = {}
        view.beginDraggingSessionHandler = { _, _ in }

        let panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        return (view, panel)
    }

    static func startDrag(from view: AppFileDragView, in panel: NSPanel, firstEventNumber: Int) {
        view.mouseEntered(with: mouseEvent(
            .mouseMoved,
            location: CGPoint(x: 12, y: 12),
            windowNumber: panel.windowNumber,
            eventNumber: firstEventNumber
        ))
        view.mouseDown(with: mouseEvent(
            .leftMouseDown,
            location: CGPoint(x: 12, y: 12),
            windowNumber: panel.windowNumber,
            eventNumber: firstEventNumber + 1
        ))
        view.mouseDragged(with: mouseEvent(
            .leftMouseDragged,
            location: CGPoint(x: 28, y: 27),
            windowNumber: panel.windowNumber,
            eventNumber: firstEventNumber + 2
        ))
    }

    static func hostedDragIcon(bundleURL: URL) -> AnyView {
        AnyView(
            DraggableAppIconView(
                bundleURL: bundleURL,
                size: 90,
                isEnabled: true
            )
            .frame(width: 90, height: 90)
        )
    }

    static func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let view = view as? T {
            return view
        }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    static func mouseEvent(_ type: NSEvent.EventType,
                           location: CGPoint,
                           windowNumber: Int,
                           eventNumber: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: TimeInterval(eventNumber),
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: type == .leftMouseDragged ? 0.5 : 1
        )!
    }
}

private final class PermissionCompanionInteractionHarness {
    private(set) var model = PermissionCompanionInteractionModel()
    private(set) var resumeTimers: [Int] = []

    func bind(to view: AppFileDragView) {
        view.onHoverChanged = { [self] hovering in
            if hovering {
                _ = model.beginHover()
            } else if let timerID = model.endHover() {
                resumeTimers.append(timerID)
            }
        }
        view.onDragStateChanged = { [self] active in
            if active {
                model.beginRealDrag()
            } else if let timerID = model.endRealDrag() {
                resumeTimers.append(timerID)
            }
        }
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
