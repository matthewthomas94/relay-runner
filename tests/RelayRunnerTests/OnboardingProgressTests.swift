import AppKit
import SwiftUI
import XCTest
@testable import relay_runner

final class OnboardingProgressTests: XCTestCase {

    func testRuntimeProgressParsesChunkedAndMultilineOutput() {
        var state = VenvInstallProgressState()

        XCTAssertTrue(state.consume(Data("RELAY_PRO".utf8)).isEmpty)
        XCTAssertNil(state.progress)

        let lines = state.consume(Data("GRESS:65:Installing dependencies...\nCollecting numpy\r\n".utf8))

        XCTAssertEqual(lines, [
            "RELAY_PROGRESS:65:Installing dependencies...",
            "Collecting numpy",
        ])
        XCTAssertEqual(state.progress ?? -1, 0.67, accuracy: 0.001)
        XCTAssertEqual(state.message, "Collecting numpy")
    }

    func testNestedCompletionReservesOuterCapacityAndProgressStaysMonotonic() {
        var state = VenvInstallProgressState()

        state.consume(Data("RELAY_PROGRESS:80:Runtime ready.\n".utf8))
        state.consume(Data("RELAY_PROGRESS:100:Nested setup complete.\n".utf8))
        XCTAssertEqual(
            state.progress ?? -1,
            VenvInstallProgressState.maximumRunningProgress,
            accuracy: 0.001
        )
        XCTAssertLessThan(state.progress ?? 1, 1)

        state.consume(Data("RELAY_PROGRESS:70:Out-of-order phase.\nStill checking readiness\n".utf8))
        XCTAssertEqual(
            state.progress ?? -1,
            VenvInstallProgressState.maximumRunningProgress,
            accuracy: 0.001
        )
        XCTAssertEqual(state.message, "Still checking readiness")
    }

    func testRuntimeProgressStartsIndeterminateAndRetryResetsPriorCompletion() {
        var state = VenvInstallProgressState()
        XCTAssertNil(state.progress)

        state.consume(Data("RELAY_PROGRESS:100:Nested setup complete.\n".utf8))
        XCTAssertNotNil(state.progress)

        state.reset()
        XCTAssertNil(state.progress)
        XCTAssertEqual(state.message, "Starting setup…")

        state.consume(Data("RELAY_PROGRESS:0:Locating Python...\n".utf8))
        XCTAssertEqual(state.progress, 0)
    }

    func testOuterProcessOwnsSuccessFailureAndProviderReadiness() {
        for provider in [GeneralConfig.AgentProvider.codex, .claude] {
            XCTAssertEqual(
                VenvInstaller.terminalStatus(
                    terminationStatus: 0,
                    provider: provider,
                    providerReady: true,
                    diagnostic: "RELAY_PROGRESS:100:Nested complete.",
                    incidentID: "incident"
                ),
                .succeeded
            )

            guard case .failed(let missingProvider) = VenvInstaller.terminalStatus(
                terminationStatus: 0,
                provider: provider,
                providerReady: false,
                diagnostic: nil,
                incidentID: "incident"
            ) else {
                return XCTFail("Missing provider readiness must fail")
            }
            XCTAssertTrue(missingProvider.contains(provider.displayName))

            guard case .failed(let processFailure) = VenvInstaller.terminalStatus(
                terminationStatus: 9,
                provider: provider,
                providerReady: true,
                diagnostic: "Health check failed",
                incidentID: "incident"
            ) else {
                return XCTFail("Outer process failure must fail")
            }
            XCTAssertTrue(processFailure.contains("Health check failed"))
        }
    }

    func testRuntimeAccessibilityReportsEquivalentProviderProgressSemantics() {
        for provider in [GeneralConfig.AgentProvider.codex, .claude] {
            let running = OnboardingRuntimePromptPresentation(
                provider: provider,
                status: .running(message: "Finalizing setup...", progress: 0.98)
            )
            XCTAssertEqual(
                OnboardingRuntimeAccessibility.label(for: running),
                "\(provider.displayName) setup in progress"
            )
            XCTAssertEqual(
                OnboardingRuntimeAccessibility.value(for: running.status),
                "98 percent, in progress"
            )

            let succeeded = OnboardingRuntimePromptPresentation(
                provider: provider,
                status: .succeeded
            )
            XCTAssertEqual(
                OnboardingRuntimeAccessibility.label(for: succeeded),
                "\(provider.displayName) setup complete"
            )
            XCTAssertEqual(
                OnboardingRuntimeAccessibility.value(for: succeeded.status),
                "Complete"
            )
        }
    }

    @MainActor
    func testMountedRuntimeProgressShowsReservedBarWithOngoingActivity() {
        let host = NSHostingView(rootView:
            OnboardingRuntimeProgressView(progress: nil, reduceMotion: false)
        )
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 120)
        host.layoutSubtreeIfNeeded()

        let initialIndicators = descendants(of: NSProgressIndicator.self, in: host)
        XCTAssertEqual(initialIndicators.filter(\.isIndeterminate).count, 1)
        XCTAssertFalse(initialIndicators.contains { !$0.isIndeterminate })

        host.rootView = OnboardingRuntimeProgressView(progress: 0.98, reduceMotion: false)
        host.layoutSubtreeIfNeeded()

        let indicators = descendants(of: NSProgressIndicator.self, in: host)
        XCTAssertTrue(indicators.contains { !$0.isIndeterminate })
        XCTAssertTrue(indicators.contains { $0.isIndeterminate })
        XCTAssertFalse(indicators.contains { !$0.isIndeterminate && $0.doubleValue >= $0.maxValue })
    }

    @MainActor
    func testTutorialIntroLoaderMatchesRuntimeSetupLoaderSize() throws {
        let runtimeHost = NSHostingView(rootView:
            OnboardingRuntimeProgressView(progress: nil, reduceMotion: false)
        )
        runtimeHost.frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        runtimeHost.layoutSubtreeIfNeeded()

        let tutorialHost = NSHostingView(rootView:
            OnboardingTutorialView(
                presentation: OnboardingTutorialPresentation(
                    screen: .intro,
                    reduceMotion: false,
                    message: nil
                ),
                retryAction: {}
            )
        )
        tutorialHost.frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        tutorialHost.layoutSubtreeIfNeeded()

        let runtimeLoader = try XCTUnwrap(
            descendants(of: NSProgressIndicator.self, in: runtimeHost).first(where: \.isIndeterminate)
        )
        let tutorialLoader = try XCTUnwrap(
            descendants(of: NSProgressIndicator.self, in: tutorialHost).first(where: \.isIndeterminate)
        )

        XCTAssertEqual(
            tutorialLoader.intrinsicContentSize.width,
            runtimeLoader.intrinsicContentSize.width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            tutorialLoader.intrinsicContentSize.height,
            runtimeLoader.intrinsicContentSize.height,
            accuracy: 0.001
        )
    }

    @MainActor
    func testMountedReduceMotionProgressUsesStaticOngoingStatus() {
        let host = NSHostingView(rootView:
            OnboardingRuntimeProgressView(progress: 0.98, reduceMotion: true)
        )
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 120)
        host.layoutSubtreeIfNeeded()

        let indicators = descendants(of: NSProgressIndicator.self, in: host)
        XCTAssertTrue(indicators.contains { !$0.isIndeterminate })
        XCTAssertFalse(indicators.contains { $0.isIndeterminate })
    }

    func testTutorialRecordingGateRequiresStartSpeechSendAndResponseInOrder() {
        var gate = OnboardingSessionControlsTutorial.RecordingGate.waitingForStart

        gate = OnboardingSessionControlsTutorial.nextRecordingGate(gate, event: .speechDetected)
        gate = OnboardingSessionControlsTutorial.nextRecordingGate(gate, event: .recordingSent)
        gate = OnboardingSessionControlsTutorial.nextRecordingGate(gate, event: .responseReady)
        XCTAssertEqual(gate, .waitingForStart)

        gate = OnboardingSessionControlsTutorial.nextRecordingGate(gate, event: .recordingStarted)
        XCTAssertEqual(gate, .waitingForSpeech)

        gate = OnboardingSessionControlsTutorial.nextRecordingGate(gate, event: .recordingSent)
        XCTAssertEqual(gate, .waitingForSpeech)

        gate = OnboardingSessionControlsTutorial.nextRecordingGate(gate, event: .speechDetected)
        XCTAssertEqual(gate, .waitingForSend)

        gate = OnboardingSessionControlsTutorial.nextRecordingGate(gate, event: .playbackRequested)
        XCTAssertEqual(gate, .waitingForSend)

        gate = OnboardingSessionControlsTutorial.nextRecordingGate(gate, event: .recordingSent)
        XCTAssertEqual(gate, .waitingForResponse)

        gate = OnboardingSessionControlsTutorial.nextRecordingGate(gate, event: .playbackRequested)
        XCTAssertEqual(gate, .waitingForResponse)

        gate = OnboardingSessionControlsTutorial.nextRecordingGate(gate, event: .responseReady)
        XCTAssertEqual(gate, .complete)
    }

    @MainActor
    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { view -> [T] in
            let current = (view as? T).map { [$0] } ?? []
            return current + descendants(of: type, in: view)
        }
    }

    func testTutorialPlaybackGateAcceptsCancelWhileReplayIsWaitingOrPlaying() {
        var gate = OnboardingSessionControlsTutorial.PlaybackGate.waitingForPlayback

        gate = OnboardingSessionControlsTutorial.nextPlaybackGate(gate, event: .cancelRequested)
        XCTAssertEqual(gate, .waitingForPlayback)

        gate = OnboardingSessionControlsTutorial.nextPlaybackGate(gate, event: .playbackRequested)
        XCTAssertEqual(gate, .waitingForInitialPlaybackStart)

        gate = OnboardingSessionControlsTutorial.nextPlaybackGate(gate, event: .playbackFinished)
        XCTAssertEqual(gate, .waitingForInitialPlaybackStart)

        gate = OnboardingSessionControlsTutorial.nextPlaybackGate(gate, event: .cancelRequested)
        XCTAssertEqual(gate, .waitingForInitialPlaybackStart)

        gate = OnboardingSessionControlsTutorial.nextPlaybackGate(gate, event: .playbackStarted)
        XCTAssertEqual(gate, .waitingForInitialPlaybackEnd)

        gate = OnboardingSessionControlsTutorial.nextPlaybackGate(gate, event: .cancelRequested)
        XCTAssertEqual(gate, .waitingForInitialPlaybackEnd)

        gate = OnboardingSessionControlsTutorial.nextPlaybackGate(gate, event: .playbackFinished)
        XCTAssertEqual(gate, .waitingForReplayStart)

        let waitingCancel = OnboardingSessionControlsTutorial.nextPlaybackGate(
            gate,
            event: .cancelRequested
        )
        XCTAssertEqual(waitingCancel, .complete)

        var playingCancel = OnboardingSessionControlsTutorial.nextPlaybackGate(
            gate,
            event: .playbackRequested
        )
        XCTAssertEqual(playingCancel, .waitingForCancel)

        playingCancel = OnboardingSessionControlsTutorial.nextPlaybackGate(
            playingCancel,
            event: .playbackStarted
        )
        XCTAssertEqual(playingCancel, .waitingForCancel)

        playingCancel = OnboardingSessionControlsTutorial.nextPlaybackGate(
            playingCancel,
            event: .playbackFinished
        )
        XCTAssertEqual(playingCancel, .waitingForCancel)

        playingCancel = OnboardingSessionControlsTutorial.nextPlaybackGate(
            playingCancel,
            event: .cancelRequested
        )
        XCTAssertEqual(playingCancel, .complete)
    }

    func testSimplifiedMicrophoneOnlyProgressIsNotSettingsHosted() {
        let label = OnboardingView.progressLabel(
            for: .microphone,
            simplified: true,
            requiresAgentChoice: false,
            permissionStatus: { kind in
                kind == .microphone ? .denied : .granted
            },
            venvInstalled: true,
            agentSignedIn: true
        )

        XCTAssertNil(label)
    }

    func testFullFlowUsesNonPermissionSetupProgress() {
        let agentChoice = OnboardingView.progressLabel(
            for: .agentChoice,
            simplified: false,
            requiresAgentChoice: false,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true
        )
        let python = OnboardingView.progressLabel(
            for: .pythonSetup,
            simplified: false,
            requiresAgentChoice: false,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true
        )
        let login = OnboardingView.progressLabel(
            for: .agentLogin,
            simplified: false,
            requiresAgentChoice: false,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true
        )

        XCTAssertEqual(agentChoice, "1 of 3")
        XCTAssertEqual(python, "2 of 3")
        XCTAssertEqual(login, "3 of 3")
    }

    func testSimplifiedProviderChoiceDoesNotIncludeParentPermissionGuidance() {
        let choice = OnboardingView.progressLabel(
            for: .agentChoice,
            simplified: true,
            requiresAgentChoice: true,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true,
            parentPermissionsReviewed: false
        )
        let python = OnboardingView.progressLabel(
            for: .parentAccessibility,
            simplified: true,
            requiresAgentChoice: true,
            permissionStatus: { _ in .granted },
            venvInstalled: false,
            agentSignedIn: true,
            parentPermissionsReviewed: false
        )
        let login = OnboardingView.progressLabel(
            for: .parentScreenRecording,
            simplified: true,
            requiresAgentChoice: true,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: false,
            parentPermissionsReviewed: false
        )

        XCTAssertEqual(choice, "1 of 1")
        XCTAssertNil(python)
        XCTAssertNil(login)
    }

    func testInterruptedSetupSkipsParentPermissionGuidanceAfterProviderChoice() {
        let accessibility = OnboardingView.progressLabel(
            for: .parentAccessibility,
            simplified: true,
            requiresAgentChoice: false,
            requiresParentPermissionGuidance: true,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true,
            parentPermissionsReviewed: false
        )

        XCTAssertNil(accessibility)
    }

    func testLegacyInputMonitoringResumeMarkerIsIgnored() {
        XCTAssertNil(OnboardingView.Step(resumeID: .inputMonitoring))

        let step = OnboardingView.initialStep(
            simplified: true,
            resumeStep: .inputMonitoring,
            requiresAgentChoice: false,
            requiresParentPermissionGuidance: true,
            parentPermissionsReviewed: false,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true
        )

        XCTAssertEqual(step, .ready)
    }

    func testLegacyParentPermissionsResumeReturnsToAccessibilityRecovery() {
        XCTAssertEqual(OnboardingView.Step(resumeID: .parentPermissions), .parentAccessibility)
        XCTAssertEqual(OnboardingView.Step(resumeID: .parentAccessibility), .parentAccessibility)
        XCTAssertEqual(OnboardingView.Step(resumeID: .parentScreenRecording), .parentScreenRecording)
    }

    func testParentAccessibilityContinuesToRuntimeSetup() {
        let next = OnboardingView.nextStepAfter(
            .parentAccessibility,
            requiresAgentChoice: false,
            requiresParentPermissionGuidance: true,
            parentPermissionsReviewed: false,
            permissionStatus: { _ in .granted },
            venvInstalled: false,
            agentSignedIn: true
        )

        XCTAssertEqual(next, .pythonSetup)
    }

    func testSimplifiedAccessibilityAndScreenRecordingDoNotParticipateInSettingsProgress() {
        let accessibility = OnboardingView.progressLabel(
            for: .parentAccessibility,
            simplified: true,
            requiresAgentChoice: false,
            permissionStatus: { kind in
                kind == .accessibility || kind == .screenRecording ? .denied : .granted
            },
            venvInstalled: true,
            agentSignedIn: true
        )
        let screenRecording = OnboardingView.progressLabel(
            for: .parentScreenRecording,
            simplified: true,
            requiresAgentChoice: false,
            permissionStatus: { kind in
                kind == .accessibility || kind == .screenRecording ? .denied : .granted
            },
            venvInstalled: true,
            agentSignedIn: true
        )

        XCTAssertNil(accessibility)
        XCTAssertNil(screenRecording)
    }

    func testPermissionTreatmentUsesFigmaPromptCopyAndButtonConstants() {
        XCTAssertEqual(
            OnboardingPermissionTreatment.prompt(for: .microphone),
            "Let’s start with your mic /"
        )
        XCTAssertEqual(
            OnboardingPermissionTreatment.prompt(for: .screenRecording),
            "Lastly we’re going to need screen recording /"
        )
        XCTAssertEqual(OnboardingPermissionTreatment.buttonTitle, "Grant permission")
        XCTAssertEqual(OnboardingPermissionTreatment.actionScale, 0.75)
        XCTAssertEqual(OnboardingPermissionTreatment.buttonSize, CGSize(width: 146.25, height: 37.5))
        XCTAssertEqual(OnboardingPermissionTreatment.buttonCornerRadius, 9)
        XCTAssertEqual(OnboardingPermissionTreatment.buttonHorizontalPadding, 24)
        XCTAssertEqual(OnboardingPermissionTreatment.buttonVerticalPadding, 12)
        XCTAssertEqual(OnboardingPermissionTreatment.buttonLineHeight, 13.5)
        XCTAssertEqual(OnboardingPermissionTreatment.buttonLabelSize, 12)
        let border = OnboardingPermissionTreatment.buttonBorderColor.usingColorSpace(.sRGB)
        XCTAssertEqual(border?.redComponent ?? 0, 17 / 255, accuracy: 0.001)
        XCTAssertEqual(border?.greenComponent ?? 0, 22 / 255, accuracy: 0.001)
        XCTAssertEqual(border?.blueComponent ?? 0, 29 / 255, accuracy: 0.001)
    }

    func testAccessibilityPermissionTreatmentOmitsSupportingCopyInStandardFlow() {
        let presentation = OnboardingPermissionTreatment.presentation(
            permission: .accessibility,
            status: .denied,
            explanation: "Accessibility lets Relay Runner host Relay Actions for clicking and typing.",
            likelyRestricted: false
        )

        XCTAssertEqual(
            presentation.prompt,
            "Next let’s set up Relay Actions with accessibility /"
        )
        XCTAssertEqual(presentation.buttonTitle, "Grant permission")
        XCTAssertNil(presentation.supportingCopy)
    }

    func testRestrictedPermissionTreatmentRetainsRecoveryExplanation() {
        let presentation = OnboardingPermissionTreatment.presentation(
            permission: .accessibility,
            status: .denied,
            explanation: "Accessibility lets Relay Runner host Relay Actions for clicking and typing.",
            likelyRestricted: true
        )

        XCTAssertTrue(presentation.supportingCopy?.contains("Relay Actions") ?? false)
    }

    func testStandardOnboardingSourceOmitsRemovedIntroductorySubcopy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Onboarding/OnboardingView.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(contents.contains(
            "First choose the coding agent, model, and workspace folder Relay Runner should use. Then we'll handle the small amount of setup needed for voice."
        ))
        XCTAssertFalse(contents.contains(
            "Start Session will open this agent and model by default. You can switch later in Settings."
        ))
        XCTAssertFalse(contents.contains(
            "Relay Runner uses a small Python helper for text-to-speech and the voice bridge. Setting up the environment takes about 30 seconds and only happens once per install."
        ))
        XCTAssertFalse(contents.contains(
            "Relay Runner will start \\(selectedAgentProvider.displayName) for voice sessions. Sign in once so sessions can connect without an authentication stop."
        ))
    }

    func testPermissionStepsWaitForGrantButtonBeforeStartingOSSetup() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Onboarding/OnboardingView.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(contents.contains("openPermissionPaneAutomaticallyIfNeeded"))
        XCTAssertTrue(contents.contains("permissionPromptAction"))
        XCTAssertTrue(contents.contains("startPermissionSetup(kind, purpose: permissionExplanation(for: kind))"))
    }

    func testReadyFooterWaitsWithoutDoneWhileSetupIsPreparing() {
        XCTAssertEqual(
            OnboardingView.readyPrimaryActionKind(
                setupStatus: .preparing("Compiling parakeet-tdt-v2..."),
                voiceReady: true,
                hasConfirmedWorkingDirectory: true
            ),
            .waiting
        )
        XCTAssertFalse(OnboardingView.showsReadyDismissAction(
            setupStatus: .preparing("Compiling parakeet-tdt-v2..."),
            voiceReady: true
        ))
    }

    func testReadyFooterOffersRetryOnSetupFailure() {
        XCTAssertEqual(
            OnboardingView.readyPrimaryActionKind(
                setupStatus: .failed("Speech-to-Text setup timed out."),
                voiceReady: true,
                hasConfirmedWorkingDirectory: true
            ),
            .retrySetup
        )
        XCTAssertFalse(OnboardingView.showsReadyDismissAction(
            setupStatus: .failed("Speech-to-Text setup timed out."),
            voiceReady: true
        ))
    }

    func testReadyFooterConvergesToStartSessionWhenSetupIsReady() {
        XCTAssertEqual(
            OnboardingView.readyPrimaryActionKind(
                setupStatus: .ready,
                voiceReady: true,
                hasConfirmedWorkingDirectory: false
            ),
            .startSession(isEnabled: false)
        )
        XCTAssertTrue(OnboardingView.showsReadyDismissAction(
            setupStatus: .ready,
            voiceReady: true
        ))
    }
}
