import XCTest
@testable import relay_runner

final class StatusSettingsTabTests: XCTestCase {

    func testInputMonitoringDeniedDetailNamesHotkeyRecovery() {
        let detail = StatusSettingsTab.permissionDetailText(
            kind: .inputMonitoring,
            status: .denied,
            restricted: false
        )

        XCTAssertTrue(detail.contains("global activation keys"))
        XCTAssertTrue(detail.contains("double-tap Shift Workspace hotkey"))
    }
}
