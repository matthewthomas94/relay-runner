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
}
