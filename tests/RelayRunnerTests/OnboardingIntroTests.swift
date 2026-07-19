import SwiftUI
import XCTest
@testable import relay_runner

final class OnboardingIntroTests: XCTestCase {
    func testIntroEligibilityIsFreshAutomaticOnly() {
        XCTAssertTrue(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: false,
            wasInterrupted: false,
            reduceMotion: false
        ))
        XCTAssertFalse(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: true,
            wasInterrupted: false,
            reduceMotion: false
        ))
        XCTAssertFalse(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: false,
            wasInterrupted: true,
            reduceMotion: false
        ))
    }

    func testReduceMotionBypassesIntro() {
        XCTAssertFalse(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: false,
            wasInterrupted: false,
            reduceMotion: true
        ))
    }

    func testPristineAutomaticShowIfNeededPresentsIntroAndWritesStartedSentinel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var notchOverrideStates: [Bool] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setOnboardingNotchOverrideActive: { notchOverrideStates.append($0) },
            makeIntroController: { intro },
            reduceMotion: { false }
        )

        controller.showIfNeeded()

        XCTAssertEqual(intro.presentCallCount, 1)
        XCTAssertEqual(notchOverrideStates, [true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.started.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
    }

    func testReduceMotionFreshAutomaticUsesBorderlessNotchSurface() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let surface = CapturingOnboardingSurfaceController()
        var notchOverrideStates: [Bool] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setOnboardingNotchOverrideActive: { notchOverrideStates.append($0) },
            makeSurfaceController: { surface },
            reduceMotion: { true }
        )

        controller.showIfNeeded()

        XCTAssertEqual(surface.showCallCount, 1)
        XCTAssertEqual(surface.bringForwardCallCount, 1)
        XCTAssertEqual(surface.visibilityStates, [true])
        XCTAssertEqual(notchOverrideStates, [true])
        XCTAssertFalse(OnboardingNotchSurfaceMetrics.styleMask.contains(.titled))
        XCTAssertFalse(OnboardingNotchSurfaceMetrics.styleMask.contains(.closable))
        XCTAssertEqual(OnboardingNotchSurfaceMetrics.contentSize, CGSize(width: 520, height: 620))
    }

    func testOnboardingNotchSurfaceRetractsIntoTopEdge() {
        let placement = OnboardingNotchSurfacePlacementPlanner.placement(
            for: NotchStatusDisplayGeometry(
                frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                visibleFrame: CGRect(x: 0, y: 40, width: 1200, height: 860)
            )
        )

        XCTAssertEqual(placement.visibleFrame.maxY, 900)
        XCTAssertEqual(
            placement.retractedFrame.minY,
            900 - OnboardingNotchSurfaceMetrics.retractedVisibleSliver
        )
    }

    func testRevealCompletionStartsTimelineOnlyWhenSurfaceIsStillActive() {
        XCTAssertEqual(
            OnboardingIntroPolicy.completionPlan(
                revealCompleted: true,
                skipRequested: false,
                timelineComplete: false,
                isCompleting: false
            ),
            OnboardingIntroCompletionPlan(
                startsTimeline: true,
                cleansUpSurface: false,
                performsHandoff: false
            )
        )
        XCTAssertFalse(OnboardingIntroPolicy.completionPlan(
            revealCompleted: true,
            skipRequested: false,
            timelineComplete: false,
            isCompleting: true
        ).startsTimeline)
    }

    func testSkipAndTimelineCompletionUseSameCleanupAndHandoffPlan() {
        let skip = OnboardingIntroPolicy.completionPlan(
            revealCompleted: false,
            skipRequested: true,
            timelineComplete: false,
            isCompleting: false
        )
        let complete = OnboardingIntroPolicy.completionPlan(
            revealCompleted: true,
            skipRequested: false,
            timelineComplete: true,
            isCompleting: false
        )

        XCTAssertEqual(skip.cleansUpSurface, true)
        XCTAssertEqual(skip.performsHandoff, true)
        XCTAssertEqual(complete, skip)
    }

    func testTimelineTypesHoldsAndErasesFirstPhrase() {
        let first = OnboardingIntroTimeline.phrases[0]
        let firstCount = Double(Array(first).count)

        XCTAssertEqual(OnboardingIntroTimeline.frame(at: 0).text, "/")
        XCTAssertEqual(
            OnboardingIntroTimeline.frame(at: OnboardingIntroTimeline.typingInterval).text,
            "F /"
        )

        let full = OnboardingIntroTimeline.frame(at: firstCount * OnboardingIntroTimeline.typingInterval)
        XCTAssertEqual(full.activePhrase, first)
        XCTAssertEqual(full.text, "\(first) /")

        let holding = OnboardingIntroTimeline.frame(
            at: firstCount * OnboardingIntroTimeline.typingInterval
                + OnboardingIntroTimeline.phraseHold / 2
        )
        XCTAssertEqual(holding.text, "\(first) /")

        let erased = OnboardingIntroTimeline.frame(
            at: firstCount * OnboardingIntroTimeline.typingInterval
                + OnboardingIntroTimeline.phraseHold
                + firstCount * OnboardingIntroTimeline.eraseInterval
                - 0.001
        )
        XCTAssertEqual(erased.text, "/")
        XCTAssertFalse(erased.isComplete)
    }

    func testTimelineFinalEraseFramesMatchDesignWithoutSeparatorSpace() {
        let finalPhrase = try! XCTUnwrap(OnboardingIntroTimeline.phrases.last)
        let eraseStart = OnboardingIntroTimeline.phrases.dropLast().reduce(0) { total, phrase in
            let count = Double(Array(phrase).count)
            return total
                + count * OnboardingIntroTimeline.typingInterval
                + OnboardingIntroTimeline.phraseHold
                + count * OnboardingIntroTimeline.eraseInterval
        } + Double(Array(finalPhrase).count) * OnboardingIntroTimeline.typingInterval
            + OnboardingIntroTimeline.phraseHold
        let finalCount = Double(Array(finalPhrase).count)

        let rOnly = OnboardingIntroTimeline.frame(
            at: eraseStart + (finalCount - 2) * OnboardingIntroTimeline.eraseInterval + 0.001
        )
        let slashOnly = OnboardingIntroTimeline.frame(
            at: eraseStart + (finalCount - 1) * OnboardingIntroTimeline.eraseInterval + 0.001
        )

        XCTAssertEqual(rOnly.text, "R/")
        XCTAssertFalse(rOnly.isComplete)
        XCTAssertEqual(slashOnly.text, "/")
        XCTAssertFalse(slashOnly.isComplete)
    }

    func testTimelineCompletesBackAtCursor() {
        let complete = OnboardingIntroTimeline.frame(at: OnboardingIntroTimeline.duration)

        XCTAssertEqual(complete.activePhrase, "Relay Runner")
        XCTAssertEqual(complete.text, "/")
        XCTAssertTrue(complete.isComplete)
    }

    func testFreshInteractiveHandoffCanStartAtAgentChoice() {
        let step = OnboardingView.initialStep(
            simplified: false,
            resumeStep: nil,
            requiresAgentChoice: true,
            requiresParentPermissionGuidance: false,
            parentPermissionsReviewed: false,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true,
            fullFlowInitialStep: .agentChoice
        )

        XCTAssertEqual(step, .agentChoice)
    }

    func testPermissionSurfaceVisibilityHidesOnlyWhileMatchingSetupIsActive() {
        XCTAssertFalse(OnboardingView.initialSurfaceVisible(for: .microphone))
        XCTAssertFalse(OnboardingView.surfaceVisible(
            for: .microphone,
            activePermissionSetupKind: .microphone
        ))
        XCTAssertTrue(OnboardingView.surfaceVisible(
            for: .microphone,
            activePermissionSetupKind: nil
        ))
        XCTAssertFalse(OnboardingView.surfaceVisible(
            for: .inputMonitoring,
            activePermissionSetupKind: .inputMonitoring
        ))
        XCTAssertTrue(OnboardingView.surfaceVisible(
            for: .inputMonitoring,
            activePermissionSetupKind: nil
        ))
        XCTAssertTrue(OnboardingView.surfaceVisible(
            for: .agentChoice,
            activePermissionSetupKind: .microphone
        ))
    }

    func testHeroTextLayoutCentersWithinReferenceRevealSurface() {
        assertHeroTextLayoutCentersInRevealSurface(
            screen: CGRect(x: 0, y: 0, width: 1728, height: 1117)
        )
    }

    func testHeroTextLayoutCentersWithinTallerRevealSurface() {
        assertHeroTextLayoutCentersInRevealSurface(
            screen: CGRect(x: 0, y: 0, width: 1728, height: 1600)
        )
    }

    func testHeroTextLayoutCentersWithinShortClampedRevealSurface() {
        let screen = CGRect(x: 0, y: 0, width: 960, height: 420)

        assertHeroTextLayoutCentersInRevealSurface(screen: screen)
        XCTAssertEqual(
            BoardRevealTransitionPlanner.plan(for: screen).expandedFrame.height,
            screen.height - BoardRevealTransitionPlanner.bottomScreenMargin
        )
    }

    private func assertHeroTextLayoutCentersInRevealSurface(
        screen: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let plan = BoardRevealTransitionPlanner.plan(for: screen)
        let rect = OnboardingIntroTextLayout.drawRect(
            in: plan.expandedFrame,
            reserveWidth: 640,
            visibleWidth: 420
        )

        XCTAssertEqual(rect.midX, plan.expandedFrame.midX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.midY, plan.expandedFrame.midY, accuracy: 0.001, file: file, line: line)
        XCTAssertNotEqual(rect.midY, screen.midY, accuracy: 0.001, file: file, line: line)
    }
}

private final class CapturingIntroPresenter: OnboardingIntroPresenting {
    private(set) var presentCallCount = 0

    func present(completion: @escaping () -> Void) {
        presentCallCount += 1
    }
}

private final class CapturingOnboardingSurfaceController: OnboardingSurfaceControlling {
    private(set) var showCallCount = 0
    private(set) var bringForwardCallCount = 0
    private(set) var closeCallCount = 0
    private(set) var visibilityStates: [Bool] = []

    func show(rootView: AnyView, initiallyVisible: Bool, onClose: @escaping () -> Void) {
        showCallCount += 1
        visibilityStates.append(initiallyVisible)
    }

    func setContentVisible(_ visible: Bool) {
        visibilityStates.append(visible)
    }

    func bringForward() {
        bringForwardCallCount += 1
    }

    func close() {
        closeCallCount += 1
    }
}

private extension OnboardingFlagURLs {
    static func testURLs(in directory: URL) -> OnboardingFlagURLs {
        OnboardingFlagURLs(
            onboarded: directory.appendingPathComponent(".onboarded"),
            started: directory.appendingPathComponent(".onboarding-started"),
            sessionRun: directory.appendingPathComponent(".session-run"),
            agentChoice: directory.appendingPathComponent(".agent-choice-v1")
        )
    }
}
