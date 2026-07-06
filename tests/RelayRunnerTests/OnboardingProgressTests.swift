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

        XCTAssertEqual(label, "2 of 5")
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

        XCTAssertEqual(label, "3 of 5")
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

    func testLegacyParentPermissionsResumeSkipsToRuntimeSetup() {
        XCTAssertEqual(OnboardingView.Step(resumeID: .parentPermissions), .pythonSetup)
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
}
