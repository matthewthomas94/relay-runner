import XCTest
@testable import relay_runner

final class SessionPromptGateTests: XCTestCase {
    func testSuppressesPromptsWithinCooldown() {
        var gate = SessionPromptGate()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(gate.shouldShow(now: start, cooldown: 20))
        XCTAssertFalse(gate.shouldShow(now: start.addingTimeInterval(5), cooldown: 20))
        XCTAssertTrue(gate.shouldShow(now: start.addingTimeInterval(20), cooldown: 20))
    }

    func testResetAllowsImmediatePrompt() {
        var gate = SessionPromptGate()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(gate.shouldShow(now: start, cooldown: 20))
        gate.reset()
        XCTAssertTrue(gate.shouldShow(now: start.addingTimeInterval(1), cooldown: 20))
    }
}
