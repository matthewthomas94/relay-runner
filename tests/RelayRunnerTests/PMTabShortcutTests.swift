import XCTest
@testable import relay_runner

final class PMTabShortcutTests: XCTestCase {
    private func route(_ s: PMTabShortcut, terminal: Bool = true, running: Bool = true, live: Int = 2) -> PMTabShortcut.Action {
        PMTabShortcut.route(s, terminalTabShowing: terminal, sessionRunning: running, liveTabCount: live)
    }

    /// RR-523: Command-T opens the "+" agent menu and starts nothing itself.
    func testOpenOnTerminalTabWithSessionOpensTheAgentMenu() throws {
        XCTAssertEqual(route(.open), .openAgentMenu)
        XCTAssertEqual(route(.open, live: 4), .openAgentMenu) // the menu path shows the four-agent limit message
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shortcut = try String(contentsOf: root.appendingPathComponent("Sources/relay-runner/Board/PMTabShortcut.swift"), encoding: .utf8)
        XCTAssertTrue(shortcut.contains("case .openAgentMenu:\n            requestAgentAddMenu()"))
        let source = try String(contentsOf: root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "    func requestAgentAddMenu() {"))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let request = String(source[start.lowerBound..<end.upperBound])
        XCTAssertTrue(request.contains("agentAddMenuRequested = true"))
        for starter in ["newSession(", "openPMTab(", "selectPMTab("] {
            XCTAssertFalse(request.contains(starter), "Command-T starts nothing: \(starter)")
        }
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
