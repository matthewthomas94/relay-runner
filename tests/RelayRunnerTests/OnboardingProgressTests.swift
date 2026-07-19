import XCTest
@testable import relay_runner

final class OnboardingProgressTests: XCTestCase {

    func testSimplifiedMicrophoneOnlyProgressStartsAtOneOfOne() {
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

        XCTAssertEqual(label, "1 of 1")
    }

    func testFullFlowMicrophoneKeepsFullSequenceCount() {
        let label = OnboardingView.progressLabel(
            for: .microphone,
            simplified: false,
            requiresAgentChoice: false,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true
        )

        XCTAssertEqual(label, "2 of 7")
    }

    func testFullFlowIncludesInputMonitoringBeforeRuntimeSetup() {
        let label = OnboardingView.progressLabel(
            for: .inputMonitoring,
            simplified: false,
            requiresAgentChoice: false,
            permissionStatus: { _ in .denied },
            venvInstalled: true,
            agentSignedIn: true
        )

        XCTAssertEqual(label, "4 of 7")
    }

    func testSimplifiedInputMonitoringMissingShowsSingleRecoveryStep() {
        let label = OnboardingView.progressLabel(
            for: .inputMonitoring,
            simplified: true,
            requiresAgentChoice: false,
            permissionStatus: { kind in
                kind == .inputMonitoring ? .denied : .granted
            },
            venvInstalled: true,
            agentSignedIn: true
        )

        XCTAssertEqual(label, "1 of 1")
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

    func testResumeRestoresInterruptedInputMonitoringStep() {
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

        XCTAssertEqual(step, .inputMonitoring)
    }

    func testGrantedInputMonitoringResumeContinuesToRuntimeSetup() {
        let next = OnboardingView.nextStepAfter(
            .inputMonitoring,
            requiresAgentChoice: false,
            requiresParentPermissionGuidance: true,
            parentPermissionsReviewed: false,
            permissionStatus: { _ in .granted },
            venvInstalled: false,
            agentSignedIn: true
        )

        XCTAssertEqual(next, .pythonSetup)
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

    func testSimplifiedAccessibilityAndScreenRecordingParticipateInProgress() {
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

        XCTAssertEqual(accessibility, "1 of 2")
        XCTAssertEqual(screenRecording, "2 of 2")
    }

    func testReadySummaryNamesDeferredInputMonitoringFeatures() {
        let summary = OnboardingView.inputMonitoringSummary(status: .denied)

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("microphone permission alone") ?? false)
        XCTAssertTrue(summary?.contains("non-Caps-Lock activation keys") ?? false)
        XCTAssertTrue(summary?.contains("double-tap Shift Workspace hotkey") ?? false)
    }

    func testReadySummaryClearsWhenInputMonitoringGranted() {
        XCTAssertNil(OnboardingView.inputMonitoringSummary(status: .granted))
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
