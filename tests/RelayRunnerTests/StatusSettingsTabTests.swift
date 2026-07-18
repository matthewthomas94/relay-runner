import XCTest
@testable import relay_runner

final class StatusSettingsTabTests: XCTestCase {

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
            StatusSettingsTab.permissionActionIntent(kind: .accessibility, status: .denied),
            .requestSetup(.accessibility)
        )
        XCTAssertEqual(
            StatusSettingsTab.permissionActionIntent(kind: .inputMonitoring, status: .notDetermined),
            .requestSetup(.inputMonitoring)
        )
    }
}
