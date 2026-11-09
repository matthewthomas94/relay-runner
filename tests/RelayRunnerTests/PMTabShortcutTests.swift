import XCTest
@testable import relay_runner

final class PMTabShortcutTests: XCTestCase {
    private func route(_ s: PMTabShortcut, terminal: Bool = true, running: Bool = true, live: Int = 2) -> PMTabShortcut.Action {
        PMTabShortcut.route(s, terminalTabShowing: terminal, sessionRunning: running, liveTabCount: live)
    }

    func testOpenOnTerminalTabWithSession() {
        XCTAssertEqual(route(.open), .openTab)
        XCTAssertEqual(route(.open, live: 9), .openTab) // "+" path shows the limit message
    }

    func testCloseWithSeveralTabsClosesWithoutAsking() {
        XCTAssertEqual(route(.close, live: 2), .closeTab)
    }

    func testCloseLastTabConfirms() {
        XCTAssertEqual(route(.close, live: 1), .confirmEndSession)
    }

    func testElsewhereOrNoSessionPassesThrough() {
        for s in [PMTabShortcut.open, .close] {
            XCTAssertEqual(route(s, terminal: false), .passThrough)
            XCTAssertEqual(route(s, running: false), .passThrough)
            XCTAssertEqual(route(s, terminal: false, running: false, live: 1), .passThrough)
        }
    }
}
