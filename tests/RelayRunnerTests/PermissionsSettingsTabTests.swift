import XCTest
@testable import relay_runner

final class PermissionsSettingsTabTests: XCTestCase {

    func testOnboardingSectionCopyMatchesRedoFlow() {
        XCTAssertEqual(PermissionsSettingsTab.onboardingSectionTitle, "Onboarding")
        XCTAssertEqual(PermissionsSettingsTab.onboardingRowTitle, "Intro walkthrough")
        XCTAssertEqual(
            PermissionsSettingsTab.onboardingRowDescription,
            "Run the intro again to revisit permissions, coding agent setup, sign-in, and workspace selection."
        )
        XCTAssertEqual(PermissionsSettingsTab.onboardingActionTitle, "Redo Onboarding…")
    }

    func testPermissionsSourcePromotesSingleOnboardingSectionAheadOfPermissionsAndRuntime() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/PermissionsSettingsTab.swift")
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

    func testPrivacyPermissionsExcludeInputMonitoring() {
        XCTAssertEqual(
            PermissionsSettingsTab.privacyPermissionOrder,
            [.microphone, .accessibility, .screenRecording]
        )
        XCTAssertEqual(
            PermissionsSettingsTab.privacyPermissionOrder.map(\.displayName),
            ["Microphone", "Accessibility", "Screen Recording"]
        )
    }

    func testHiddenInputMonitoringResetDoesNotSurfaceInSettings() {
        XCTAssertEqual(
            PermissionsSettingsTab.visibleResetPermissions([.inputMonitoring]),
            []
        )
        XCTAssertEqual(
            PermissionsSettingsTab.visibleResetPermissions([.inputMonitoring, .accessibility]),
            [.accessibility]
        )
    }

    func testAccessibilityDetailNamesRelayActionsRatherThanHotkeys() {
        let detail = PermissionsSettingsTab.permissionDetailText(
            kind: .accessibility,
            status: .notDetermined,
            restricted: false
        )

        XCTAssertTrue(detail.contains("Relay Actions"))
        XCTAssertTrue(detail.contains("UI automation"))
        XCTAssertFalse(detail.contains("hotkey"))
    }

    func testScreenRecordingDetailAndActionIntentNameRelayVisionRecovery() {
        let denied = PermissionsSettingsTab.permissionDetailText(
            kind: .screenRecording,
            status: .denied,
            restricted: false
        )
        let notDetermined = PermissionsSettingsTab.permissionDetailText(
            kind: .screenRecording,
            status: .notDetermined,
            restricted: false
        )

        XCTAssertTrue(denied.contains("Relay Vision screenshots"))
        XCTAssertTrue(notDetermined.contains("Relay Vision screenshots"))
        XCTAssertEqual(
            PermissionsSettingsTab.permissionActionTitle(kind: .screenRecording, status: .denied),
            "Open Settings"
        )
        XCTAssertEqual(
            PermissionsSettingsTab.permissionActionIntent(kind: .screenRecording, status: .denied),
            .requestSetup(.screenRecording)
        )
        XCTAssertNil(PermissionsSettingsTab.permissionActionIntent(kind: .screenRecording, status: .granted))
    }

    func testListPermissionsUseSharedSetupIntent() {
        XCTAssertEqual(
            PermissionsSettingsTab.permissionActionIntent(kind: .microphone, status: .notDetermined),
            .requestSetup(.microphone)
        )
        XCTAssertEqual(
            PermissionsSettingsTab.permissionActionIntent(kind: .accessibility, status: .denied),
            .requestSetup(.accessibility)
        )
        XCTAssertEqual(
            PermissionsSettingsTab.permissionActionIntent(kind: .screenRecording, status: .notDetermined),
            .requestSetup(.screenRecording)
        )
    }
}
