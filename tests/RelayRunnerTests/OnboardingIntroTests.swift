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
            permissionStatus: { _ in .denied },
            makeIntroController: { intro },
            reduceMotion: { false }
        )

        controller.showIfNeeded()

        XCTAssertEqual(intro.presentCallCount, 1)
        XCTAssertEqual(notchOverrideStates, [true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.started.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
    }

    func testCinematicCompletionShowsFirstPermissionBeforeSettingsHandoff() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var notchOverrideStates: [Bool] = []
        var settingsOpenCount = 0
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setOnboardingNotchOverrideActive: { notchOverrideStates.append($0) },
            permissionStatus: { _ in .denied },
            makeIntroController: { intro },
            openSettingsHost: { settingsOpenCount += 1 },
            reduceMotion: { false }
        )

        controller.showIfNeeded()
        intro.completeCinematic()

        XCTAssertEqual(intro.presentCallCount, 1)
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.microphone])
        XCTAssertEqual(settingsOpenCount, 0)
        XCTAssertEqual(notchOverrideStates, [true])
    }

    func testReduceMotionFreshAutomaticUsesStaticIntroPermissionPresentation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let presentation = OnboardingPresentationState()
        var settingsOpenCount = 0
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            presentation: presentation,
            permissionStatus: { _ in .denied },
            makeIntroController: { intro },
            openSettingsHost: { settingsOpenCount += 1 },
            reduceMotion: { true }
        )

        controller.showIfNeeded()

        XCTAssertEqual(intro.presentCallCount, 0)
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.microphone])
        XCTAssertFalse(presentation.isPresented)
        XCTAssertEqual(settingsOpenCount, 0)
    }

    func testFreshPermissionSequenceRequestsThroughCoordinatorAndHandsOffAfterAllGrants() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let presentation = OnboardingPresentationState()
        var statuses = Dictionary(
            uniqueKeysWithValues: PermissionKind.guidedSetupOrder.map { ($0, PermissionStatus.denied) }
        )
        var events: [String] = []
        intro.onDismiss = { events.append("dismiss") }
        var settingsOpenCount = 0
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            presentation: presentation,
            requestPermissionSetup: { kind, source, _ in
                events.append("request:\(kind.rawValue):\(source)")
            },
            permissionStatus: { statuses[$0] ?? .denied },
            makeIntroController: { intro },
            openSettingsHost: { settingsOpenCount += 1 },
            reduceMotion: { false }
        )

        controller.showIfNeeded()
        intro.completeCinematic()

        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.microphone])
        intro.performPermissionAction()
        XCTAssertEqual(events, ["request:microphone:onboarding"])

        statuses[.microphone] = .granted
        postGrant(.microphone)
        drainMainQueue()
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.microphone, .accessibility])

        intro.performPermissionAction()
        XCTAssertEqual(Array(events.suffix(2)), ["dismiss", "request:accessibility:onboarding"])
        statuses[.accessibility] = .granted
        postGrant(.accessibility)
        drainMainQueue()
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.microphone, .accessibility, .inputMonitoring])

        intro.performPermissionAction()
        statuses[.inputMonitoring] = .granted
        postGrant(.inputMonitoring)
        drainMainQueue()
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [
            .microphone,
            .accessibility,
            .inputMonitoring,
            .screenRecording,
        ])

        intro.performPermissionAction()
        statuses[.screenRecording] = .granted
        postGrant(.screenRecording)
        drainMainQueue()

        XCTAssertTrue(presentation.isPresented)
        XCTAssertEqual(presentation.detail.title, "Coding Agent")
        XCTAssertEqual(settingsOpenCount, 1)
    }

    func testFreshPermissionDenialReturnsToSameIntroPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var statuses = Dictionary(
            uniqueKeysWithValues: PermissionKind.guidedSetupOrder.map { ($0, PermissionStatus.granted) }
        )
        statuses[.accessibility] = .denied
        var settingsOpenCount = 0
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            requestPermissionSetup: { _, _, _ in },
            permissionStatus: { statuses[$0] ?? .granted },
            makeIntroController: { intro },
            openSettingsHost: { settingsOpenCount += 1 },
            reduceMotion: { true }
        )

        controller.showIfNeeded()
        intro.performPermissionAction()
        NotificationCenter.default.post(
            name: .relayPermissionSetupEndedWithoutGrant,
            object: PermissionSetupLifecycleEvent(permission: .accessibility, source: .onboarding)
        )
        drainMainQueue()

        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.accessibility, .accessibility])
        XCTAssertEqual(settingsOpenCount, 0)
    }

    func testPostOnboardingPermissionLossDoesNotOpenOnboarding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        try Data().write(to: flagURLs.onboarded)
        try Data().write(to: flagURLs.agentChoice)
        try Data().write(to: flagURLs.sessionRun)
        let intro = CapturingIntroPresenter()
        let presentation = OnboardingPresentationState()
        var settingsOpenCount = 0
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            presentation: presentation,
            permissionStatus: { _ in .denied },
            makeIntroController: { intro },
            openSettingsHost: { settingsOpenCount += 1 },
            reduceMotion: { true }
        )

        controller.showIfNeeded()

        XCTAssertEqual(intro.presentCallCount, 0)
        XCTAssertTrue(intro.permissionPrompts.isEmpty)
        XCTAssertFalse(presentation.isPresented)
        XCTAssertEqual(settingsOpenCount, 0)
    }

    func testRepeatedManualShowReopensSettingsWithoutReplacingActivePresentation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let presentation = OnboardingPresentationState()
        var settingsOpenCount = 0
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            presentation: presentation,
            openSettingsHost: { settingsOpenCount += 1 },
            reduceMotion: { true }
        )

        controller.showAlways()
        let firstSerial = presentation.presentationSerial
        controller.showAlways()

        XCTAssertEqual(firstSerial, 1)
        XCTAssertEqual(presentation.presentationSerial, firstSerial)
        XCTAssertTrue(presentation.isPresented)
        XCTAssertEqual(settingsOpenCount, 2)
    }

    func testOnboardingControllerDoesNotDefineDedicatedWindowSurface() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Onboarding/OnboardingController.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(contents.contains("OnboardingSurfaceControlling"))
        XCTAssertFalse(contents.contains("OnboardingNotchSurfaceController"))
        XCTAssertFalse(contents.contains("OnboardingNotchPanel"))
        XCTAssertFalse(contents.contains("NSPanel"))
        XCTAssertFalse(contents.contains("setActivationPolicy"))
    }

    func testOnboardingViewUsesSettingsHostChromeInsteadOfFixedPanelChrome() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Onboarding/OnboardingView.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("SettingsStack"))
        XCTAssertTrue(contents.contains("SettingsActionButton"))
        XCTAssertFalse(contents.contains("OnboardingNotchSurfaceMetrics"))
        XCTAssertFalse(contents.contains(".frame(\n            width:"))
        XCTAssertFalse(contents.contains("Color(nsColor: .windowBackgroundColor)"))
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

    func testSkipAndTimelineCompletionUseSameHandoffPlanWithoutCleanup() {
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

        XCTAssertEqual(skip.cleansUpSurface, false)
        XCTAssertEqual(skip.performsHandoff, true)
        XCTAssertEqual(complete, skip)
    }

    func testTimelineTypesHoldsAndErasesFirstPhrase() {
        let first = OnboardingIntroTimeline.phrases[0]
        let firstCount = Double(Array(first).count)
        let brandTypeDuration = (firstCount - 1) * OnboardingIntroTimeline.typingInterval

        XCTAssertEqual(OnboardingIntroTimeline.frame(at: 0).text, "R/")
        XCTAssertTrue(OnboardingIntroTimeline.frame(at: 0).cursorVisible)
        XCTAssertEqual(
            OnboardingIntroTimeline.frame(
                at: OnboardingIntroTimeline.initialBrandHold
                    + OnboardingIntroTimeline.typingInterval
                    + 0.001
            ).text,
            "Re /"
        )

        let full = OnboardingIntroTimeline.frame(
            at: OnboardingIntroTimeline.initialBrandHold + brandTypeDuration
        )
        XCTAssertEqual(full.activePhrase, first)
        XCTAssertEqual(full.text, "\(first) /")
        XCTAssertEqual(full.dotFieldProgress, 0, accuracy: 0.001)
        XCTAssertEqual(full.dotFieldOpacity, 1, accuracy: 0.001)

        let holding = OnboardingIntroTimeline.frame(
            at: OnboardingIntroTimeline.initialBrandHold
                + brandTypeDuration
                + OnboardingIntroTimeline.dotFieldTravel / 2
        )
        XCTAssertEqual(holding.text, "\(first) /")
        XCTAssertEqual(holding.dotFieldProgress, 0.5, accuracy: 0.01)

        let erased = OnboardingIntroTimeline.frame(
            at: OnboardingIntroTimeline.initialBrandHold
                + brandTypeDuration
                + OnboardingIntroTimeline.dotFieldTravel
                + firstCount * OnboardingIntroTimeline.eraseInterval
                - 0.001
        )
        XCTAssertEqual(erased.text, "/")
        XCTAssertFalse(erased.isComplete)
    }

    func testBrandEraseFramesMatchDesignWithoutSeparatorSpace() {
        let brandPhrase = OnboardingIntroTimeline.phrases[0]
        let brandCount = Double(Array(brandPhrase).count)
        let eraseStart = OnboardingIntroTimeline.initialBrandHold
            + (brandCount - 1) * OnboardingIntroTimeline.typingInterval
            + OnboardingIntroTimeline.dotFieldTravel

        let rOnly = OnboardingIntroTimeline.frame(
            at: eraseStart + (brandCount - 2) * OnboardingIntroTimeline.eraseInterval + 0.001
        )
        let slashOnly = OnboardingIntroTimeline.frame(
            at: eraseStart + (brandCount - 1) * OnboardingIntroTimeline.eraseInterval + 0.001
        )

        XCTAssertEqual(rOnly.text, "R/")
        XCTAssertFalse(rOnly.isComplete)
        XCTAssertEqual(slashOnly.text, "/")
        XCTAssertFalse(slashOnly.isComplete)
    }

    func testCursorBlinksWhileHoldingCopy() {
        let brandCount = Double(Array(OnboardingIntroTimeline.phrases[0]).count)
        let holdStart = OnboardingIntroTimeline.initialBrandHold
            + (brandCount - 1) * OnboardingIntroTimeline.typingInterval

        let visible = OnboardingIntroTimeline.frame(at: holdStart + 0.10)
        let hidden = OnboardingIntroTimeline.frame(at: holdStart + 0.45)

        XCTAssertTrue(visible.cursorVisible)
        XCTAssertEqual(visible.renderedText, "Relay Runner /")
        XCTAssertFalse(hidden.cursorVisible)
        XCTAssertEqual(hidden.renderedText, "Relay Runner ")
    }

    func testTimelineCompletesOnFinalPermissionPhrase() {
        let complete = OnboardingIntroTimeline.frame(at: OnboardingIntroTimeline.duration)

        XCTAssertEqual(complete.activePhrase, "I need a few permissions")
        XCTAssertEqual(complete.text, "I need a few permissions /")
        XCTAssertTrue(complete.isComplete)
    }

    func testTimelineUsesReadablePacingTargets() {
        XCTAssertEqual(OnboardingIntroTimeline.typingInterval, 0.065, accuracy: 0.001)
        XCTAssertEqual(OnboardingIntroTimeline.eraseInterval, 0.045, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.initialBrandHold, 0.65)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.phraseHold, 1.0)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.finalPhraseHold, 1.4)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.dotFieldTravel, 1.8)
        XCTAssertLessThanOrEqual(OnboardingIntroTimeline.dotFieldTravel, 2.2)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.duration, 9.5)
        XCTAssertLessThanOrEqual(OnboardingIntroTimeline.duration, 11.5)
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
        XCTAssertTrue(OnboardingView.initialSurfaceVisible(for: .microphone))
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

    func testHeroTextLayoutMatchesReferenceTopWithinRevealSurface() {
        assertHeroTextLayoutMatchesReferenceFrame(
            screen: CGRect(x: 0, y: 0, width: 1728, height: 1117)
        )
    }

    func testHeroTextLayoutKeepsReferenceTopWithinTallerRevealSurface() {
        assertHeroTextLayoutMatchesReferenceFrame(
            screen: CGRect(x: 0, y: 0, width: 1728, height: 1600)
        )
    }

    func testHeroTextLayoutCentersWithinShortClampedRevealSurface() {
        let screen = CGRect(x: 0, y: 0, width: 960, height: 420)

        assertHeroTextLayoutMatchesReferenceFrame(screen: screen)
        XCTAssertEqual(
            BoardRevealTransitionPlanner.plan(for: screen).expandedFrame.height,
            screen.height - BoardRevealTransitionPlanner.bottomScreenMargin
        )
    }

    func testIntroUsesSharedParticleRendererInsteadOfOnboardingHalftone() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Onboarding/OnboardingIntroController.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("ParticleFieldRenderer()"))
        XCTAssertTrue(contents.contains("renderer.transition(to: .tts)"))
        XCTAssertFalse(contents.contains("OnboardingHalftone"))
        XCTAssertFalse(contents.contains("drawHalftone"))
    }

    private func assertHeroTextLayoutMatchesReferenceFrame(
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
        XCTAssertEqual(
            rect.minY,
            plan.expandedFrame.minY
                + OnboardingIntroTextLayout.referenceTextTop
                * (plan.expandedFrame.height / OnboardingIntroTextLayout.referenceWorkspaceHeight),
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertNotEqual(rect.midY, screen.midY, accuracy: 0.001, file: file, line: line)
    }
}

private final class CapturingIntroPresenter: OnboardingIntroPresenting {
    private(set) var presentCallCount = 0
    private(set) var permissionPrompts: [OnboardingPermissionPromptPresentation] = []
    private var cinematicCompletion: (() -> Void)?
    private var permissionAction: (() -> Void)?
    var onDismiss: (() -> Void)?

    func present(completion: @escaping () -> Void) {
        presentCallCount += 1
        cinematicCompletion = completion
    }

    func presentPermissionPrompt(_ presentation: OnboardingPermissionPromptPresentation,
                                 action: @escaping () -> Void) {
        permissionPrompts.append(presentation)
        permissionAction = action
    }

    func dismiss(completion: @escaping () -> Void) {
        onDismiss?()
        completion()
    }

    func completeCinematic() {
        cinematicCompletion?()
        cinematicCompletion = nil
    }

    func performPermissionAction() {
        permissionAction?()
    }
}

private func postGrant(_ permission: PermissionKind) {
    NotificationCenter.default.post(
        name: .relayPermissionSetupGrantReady,
        object: permission.rawValue
    )
}

private func drainMainQueue(file: StaticString = #filePath, line: UInt = #line) {
    let expectation = XCTestExpectation(description: "Drain main queue")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 1)
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
