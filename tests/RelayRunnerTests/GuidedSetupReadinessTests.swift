import XCTest
@testable import relay_runner

final class GuidedSetupReadinessTests: XCTestCase {

    func testProviderSetupPlanUsesEquivalentProviderSpecificRails() {
        let codex = GuidedSetupPlan.items(for: .codex)
        let claude = GuidedSetupPlan.items(for: .claude)

        XCTAssertEqual(codex.count, claude.count)
        XCTAssertTrue(codex.contains { $0.id == "workspace-folder" })
        XCTAssertTrue(claude.contains { $0.id == "workspace-folder" })
        XCTAssertTrue(codex.contains { $0.detail.contains("Codex relay-bridge") })
        XCTAssertTrue(codex.contains { $0.detail.contains("MCP tool registration") })
        XCTAssertTrue(codex.contains { $0.detail.contains("Program Manager discover") })
        XCTAssertTrue(claude.contains { $0.detail.contains("Claude /relay-bridge") })
        XCTAssertTrue(claude.contains { $0.detail.contains("MCP tool registration") })
        XCTAssertTrue(claude.contains { $0.detail.contains("Program Manager discover") })
        XCTAssertEqual(GuidedSetupPlan(provider: .codex).primaryActionTitle, "Set Up Codex")
        XCTAssertEqual(GuidedSetupPlan(provider: .claude).primaryActionTitle, "Set Up Claude")
    }

    func testBlockedReadinessNamesRequiredSetup() {
        let readiness = GuidedSetupReadiness(
            provider: .codex,
            microphone: .denied,
            inputMonitoring: .granted,
            pythonInstalled: false,
            agentSignedIn: false,
            parentPermissionsReviewed: true
        )

        XCTAssertEqual(readiness.mode, .blocked)
        XCTAssertFalse(readiness.voiceReady)
        XCTAssertTrue(readiness.detail.contains("Microphone access is required"))
        XCTAssertTrue(readiness.detail.contains("Python voice environment"))
        XCTAssertTrue(readiness.detail.contains("Codex sign-in"))
    }

    func testVoiceOnlyReadinessNamesDeferredPermissions() {
        let readiness = GuidedSetupReadiness(
            provider: .claude,
            microphone: .granted,
            inputMonitoring: .denied,
            pythonInstalled: true,
            agentSignedIn: true,
            parentPermissionsReviewed: false
        )

        XCTAssertEqual(readiness.mode, .voiceOnly)
        XCTAssertTrue(readiness.voiceReady)
        XCTAssertFalse(readiness.screenControlAndBoardReady)
        XCTAssertTrue(readiness.detail.contains("Start Session can launch Claude"))
        XCTAssertTrue(readiness.detail.contains("double-tap Shift board hotkey"))
        XCTAssertTrue(readiness.detail.contains("Relay Actions and Relay Vision"))
    }

    func testRecoveryAfterDeferredPermissionsAreGrantedLater() {
        let before = GuidedSetupReadiness(
            provider: .codex,
            microphone: .granted,
            inputMonitoring: .denied,
            pythonInstalled: true,
            agentSignedIn: true,
            parentPermissionsReviewed: true
        )
        let after = GuidedSetupReadiness(
            provider: .codex,
            microphone: .granted,
            inputMonitoring: .granted,
            pythonInstalled: true,
            agentSignedIn: true,
            parentPermissionsReviewed: true
        )

        XCTAssertEqual(before.mode, .voiceOnly)
        XCTAssertEqual(after.mode, .fullyArmed)
        XCTAssertTrue(after.screenControlAndBoardReady)
        XCTAssertTrue(after.detail.contains("voice bridge, board, MCP tools, and TTS ready"))
    }
}
