import XCTest
@testable import relay_runner

final class StatusSettingsTabTests: XCTestCase {

    func testOnboardingSectionCopyMatchesRedoFlow() {
        XCTAssertEqual(StatusSettingsTab.onboardingSectionTitle, "Onboarding")
        XCTAssertEqual(StatusSettingsTab.onboardingRowTitle, "Intro walkthrough")
        XCTAssertEqual(
            StatusSettingsTab.onboardingRowDescription,
            "Run the intro again to revisit permissions, coding agent setup, sign-in, and workspace selection."
        )
        XCTAssertEqual(StatusSettingsTab.onboardingActionTitle, "Redo Onboarding…")
    }

    func testStatusSourcePromotesSingleOnboardingSectionAheadOfPermissionsAndRuntime() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/StatusSettingsTab.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        let onboardingIndex = try XCTUnwrap(contents.range(of: "SettingsSection(Self.onboardingSectionTitle)")?.lowerBound)
        let privacyIndex = try XCTUnwrap(contents.range(of: "SettingsSection(\"Privacy Permissions\")")?.lowerBound)
        let runtimeIndex = try XCTUnwrap(contents.range(of: "SettingsSection(\"Runtime\")")?.lowerBound)

        XCTAssertLessThan(contents.distance(from: contents.startIndex, to: onboardingIndex),
                          contents.distance(from: contents.startIndex, to: privacyIndex))
        XCTAssertLessThan(contents.distance(from: contents.startIndex, to: onboardingIndex),
                          contents.distance(from: contents.startIndex, to: runtimeIndex))
        XCTAssertEqual(contents.components(separatedBy: "showManualRedo()").count - 1, 1)
        XCTAssertFalse(contents.contains("Re-run Setup Walkthrough"))
    }

    func testPrivacyPermissionsExposeCompleteOrderedList() {
        XCTAssertEqual(
            StatusSettingsTab.privacyPermissionOrder,
            [.microphone, .accessibility, .inputMonitoring, .screenRecording]
        )
        XCTAssertEqual(
            StatusSettingsTab.privacyPermissionOrder.map(\.displayName),
            ["Microphone", "Accessibility", "Input Monitoring", "Screen Recording"]
        )
    }

    func testInputMonitoringDeniedDetailNamesHotkeyRecovery() {
        let detail = StatusSettingsTab.permissionDetailText(
            kind: .inputMonitoring,
            status: .denied,
            restricted: false
        )

        XCTAssertTrue(detail.contains("global activation keys"))
        XCTAssertTrue(detail.contains("double-tap Shift Workspace hotkey"))
    }

    func testAccessibilityDetailNamesRelayActionsRatherThanHotkeys() {
        let detail = StatusSettingsTab.permissionDetailText(
            kind: .accessibility,
            status: .notDetermined,
            restricted: false
        )

        XCTAssertTrue(detail.contains("Relay Actions"))
        XCTAssertTrue(detail.contains("UI automation"))
        XCTAssertFalse(detail.contains("hotkey"))
    }

    func testScreenRecordingDetailAndActionIntentNameRelayVisionRecovery() {
        let denied = StatusSettingsTab.permissionDetailText(
            kind: .screenRecording,
            status: .denied,
            restricted: false
        )
        let notDetermined = StatusSettingsTab.permissionDetailText(
            kind: .screenRecording,
            status: .notDetermined,
            restricted: false
        )

        XCTAssertTrue(denied.contains("Relay Vision screenshots"))
        XCTAssertTrue(notDetermined.contains("Relay Vision screenshots"))
        XCTAssertEqual(
            StatusSettingsTab.permissionActionTitle(kind: .screenRecording, status: .denied),
            "Open Settings"
        )
        XCTAssertEqual(
            StatusSettingsTab.permissionActionIntent(kind: .screenRecording, status: .denied),
            .requestSetup(.screenRecording)
        )
        XCTAssertNil(StatusSettingsTab.permissionActionIntent(kind: .screenRecording, status: .granted))
    }

    func testListPermissionsUseSharedSetupIntent() {
        XCTAssertEqual(
            StatusSettingsTab.permissionActionIntent(kind: .microphone, status: .notDetermined),
            .requestSetup(.microphone)
        )
        XCTAssertEqual(
            StatusSettingsTab.permissionActionIntent(kind: .accessibility, status: .denied),
            .requestSetup(.accessibility)
        )
        XCTAssertEqual(
            StatusSettingsTab.permissionActionIntent(kind: .inputMonitoring, status: .notDetermined),
            .requestSetup(.inputMonitoring)
        )
    }
}
