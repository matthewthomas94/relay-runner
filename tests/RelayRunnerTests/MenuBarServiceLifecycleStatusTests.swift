import XCTest
@testable import relay_runner

final class MenuBarServiceLifecycleStatusTests: XCTestCase {
    func testRefreshFailureUsesCompactLabelAndKeepsDetail() {
        let message = "Bundled service refresh failed: relay-orchestrator --restart-if-idle failed with exit code 1."

        let status = MenuBarServiceLifecycleStatus(message)

        XCTAssertEqual(status?.label, "Bundled service refresh failed")
        XCTAssertEqual(status?.detail, message)
    }

    func testRefreshDeferralUsesCompactLabelAndKeepsDetail() {
        let message = (
            "Bundled service refresh deferred until active orchestrator workers finish. "
            + "Quit and reopen Relay Runner after they finish."
        )

        let status = MenuBarServiceLifecycleStatus(message)

        XCTAssertEqual(status?.label, "Bundled service refresh deferred")
        XCTAssertEqual(status?.detail, message)
    }

    func testOtherLongMessagesAreTruncatedWithoutLosingDetail() {
        let message = "Service lifecycle detail that is too long for a compact menu item label."

        let status = MenuBarServiceLifecycleStatus(message)

        XCTAssertEqual(status?.label, "Service lifecycle detail that is too long...")
        XCTAssertEqual(status?.detail, message)
    }
}
