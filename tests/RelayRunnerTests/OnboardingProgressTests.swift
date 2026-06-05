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

        XCTAssertEqual(label, "2 of 6")
    }

    func testFullFlowIncludesInputMonitoringBeforeParentPermissions() {
        let label = OnboardingView.progressLabel(
            for: .inputMonitoring,
            simplified: false,
            requiresAgentChoice: false,
            permissionStatus: { _ in .denied },
            venvInstalled: true,
            agentSignedIn: true
        )

        XCTAssertEqual(label, "3 of 6")
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

    func testSimplifiedProviderChoiceIncludesParentPermissionGuidance() {
        let choice = OnboardingView.progressLabel(
            for: .agentChoice,
            simplified: true,
            requiresAgentChoice: true,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true,
            parentPermissionsReviewed: false
        )
        let parent = OnboardingView.progressLabel(
            for: .parentPermissions,
            simplified: true,
            requiresAgentChoice: true,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true,
            parentPermissionsReviewed: false
        )

        XCTAssertEqual(choice, "1 of 2")
        XCTAssertEqual(parent, "2 of 2")
    }

    func testInterruptedSetupStillIncludesParentPermissionGuidanceAfterProviderChoice() {
        let parent = OnboardingView.progressLabel(
            for: .parentPermissions,
            simplified: true,
            requiresAgentChoice: false,
            requiresParentPermissionGuidance: true,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true,
            parentPermissionsReviewed: false
        )

        XCTAssertEqual(parent, "1 of 1")
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

    func testGrantedInputMonitoringResumeContinuesToParentPermissions() {
        let next = OnboardingView.nextStepAfter(
            .inputMonitoring,
            requiresAgentChoice: false,
            requiresParentPermissionGuidance: true,
            parentPermissionsReviewed: false,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true
        )

        XCTAssertEqual(next, .parentPermissions)
    }

    func testReadySummaryNamesDeferredInputMonitoringFeatures() {
        let summary = OnboardingView.inputMonitoringSummary(status: .denied)

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("microphone permission alone") ?? false)
        XCTAssertTrue(summary?.contains("non-Caps-Lock activation keys") ?? false)
        XCTAssertTrue(summary?.contains("Control+Option board hotkey") ?? false)
    }

    func testReadySummaryClearsWhenInputMonitoringGranted() {
        XCTAssertNil(OnboardingView.inputMonitoringSummary(status: .granted))
    }
}
