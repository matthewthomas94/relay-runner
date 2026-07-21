import AppKit
import XCTest
@testable import relay_runner

final class OnboardingProgressTests: XCTestCase {

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

    func testFullFlowDoesNotIncludeInputMonitoringProgress() {
        let label = OnboardingView.progressLabel(
            for: .inputMonitoring,
            simplified: false,
            requiresAgentChoice: false,
            permissionStatus: { _ in .denied },
            venvInstalled: true,
            agentSignedIn: true
        )

        XCTAssertNil(label)
    }

    func testSimplifiedInputMonitoringMissingDoesNotCreateSettingsRecoveryStep() {
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

        XCTAssertNil(label)
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

    func testPermissionResumeMarkerSkipsToReadyWhenNonPermissionSetupIsComplete() {
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

    func testPermissionTreatmentUsesFigmaPromptCopyAndButtonConstants() {
        XCTAssertEqual(
            OnboardingPermissionTreatment.prompt(for: .microphone),
            "Let’s start with your mic /"
        )
        XCTAssertEqual(
            OnboardingPermissionTreatment.prompt(for: .inputMonitoring),
            "Next let’s set up your hotkeys with input monitoring /"
        )
        XCTAssertEqual(
            OnboardingPermissionTreatment.prompt(for: .screenRecording),
            "Lastly we’re going to need screen recording /"
        )
        XCTAssertEqual(OnboardingPermissionTreatment.buttonTitle, "Grant permission")
        XCTAssertEqual(OnboardingPermissionTreatment.buttonSize, CGSize(width: 195, height: 50))
        XCTAssertEqual(OnboardingPermissionTreatment.buttonCornerRadius, 12)
        XCTAssertEqual(OnboardingPermissionTreatment.buttonHorizontalPadding, 32)
        XCTAssertEqual(OnboardingPermissionTreatment.buttonVerticalPadding, 16)
        XCTAssertEqual(OnboardingPermissionTreatment.buttonLineHeight, 18)
        let border = OnboardingPermissionTreatment.buttonBorderColor.usingColorSpace(.sRGB)
        XCTAssertEqual(border?.redComponent ?? 0, 17 / 255, accuracy: 0.001)
        XCTAssertEqual(border?.greenComponent ?? 0, 22 / 255, accuracy: 0.001)
        XCTAssertEqual(border?.blueComponent ?? 0, 29 / 255, accuracy: 0.001)
    }

    func testAccessibilityPermissionTreatmentRetainsProductExplanation() {
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
        XCTAssertTrue(presentation.supportingCopy?.contains("Relay Actions") ?? false)
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
