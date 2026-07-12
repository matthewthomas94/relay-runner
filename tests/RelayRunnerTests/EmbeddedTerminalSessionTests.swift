import AppKit
import XCTest
@testable import relay_runner

final class EmbeddedTerminalSessionTests: XCTestCase {
    func testStartRejectsDuplicateActiveSession() throws {
        let process = FakeEmbeddedTerminalProcess()
        let session = EmbeddedTerminalSession(processFactory: { process })

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())

        XCTAssertEqual(session.phase, .running)
        XCTAssertThrowsError(
            try session.beginPreparing(providerName: "Claude", workingDirectory: "/other")
        ) { error in
            XCTAssertEqual(error as? EmbeddedTerminalProcessError, .alreadyRunning)
        }
        XCTAssertEqual(process.startCount, 1)
    }

    func testNaturalExitSurfacesDecodedStatusAndAllowsRestart() throws {
        let first = FakeEmbeddedTerminalProcess()
        let second = FakeEmbeddedTerminalProcess()
        var processes = [first, second]
        let session = EmbeddedTerminalSession(processFactory: { processes.removeFirst() })
        let exited = expectation(description: "exit handled")
        session.setExitHandler { code in
            XCTAssertEqual(code, 1)
            exited.fulfill()
        }

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())
        first.emitExit(rawStatus: 256)
        wait(for: [exited], timeout: 1)

        XCTAssertEqual(session.phase, .exited(1))

        try session.beginPreparing(providerName: "Claude", workingDirectory: "/other")
        try session.start(launch())

        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(second.startCount, 1)
    }

    func testExplicitEndTerminatesOnceAndIgnoresLateExit() throws {
        let process = FakeEmbeddedTerminalProcess()
        let session = EmbeddedTerminalSession(processFactory: { process })

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())
        let lateExit = process.onExit

        session.end()
        lateExit?(0)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(session.phase, .ended)
        XCTAssertNotNil(session.hostedView)
    }

    func testStaleExitFromReplacedProcessCannotEndNewSession() throws {
        let first = FakeEmbeddedTerminalProcess()
        let second = FakeEmbeddedTerminalProcess()
        var processes = [first, second]
        let session = EmbeddedTerminalSession(processFactory: { processes.removeFirst() })

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())
        let staleExit = first.onExit
        first.emitExit(rawStatus: 0)
        let firstExit = expectation(description: "first exit")
        DispatchQueue.main.async { firstExit.fulfill() }
        wait(for: [firstExit], timeout: 1)

        try session.beginPreparing(providerName: "Claude", workingDirectory: "/other")
        try session.start(launch())
        staleExit?(256)
        let drained = expectation(description: "stale exit drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)

        XCTAssertEqual(session.phase, .running)
        XCTAssertTrue(session.hostedView === second.view)
    }

    func testFailedProcessStartIsVisibleAndCanRetry() throws {
        let failing = FakeEmbeddedTerminalProcess()
        failing.startError = EmbeddedTerminalProcessError.couldNotStart
        let succeeding = FakeEmbeddedTerminalProcess()
        var processes = [failing, succeeding]
        let session = EmbeddedTerminalSession(processFactory: { processes.removeFirst() })

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        XCTAssertThrowsError(try session.start(launch()))
        XCTAssertEqual(
            session.phase,
            .failed(EmbeddedTerminalProcessError.couldNotStart.localizedDescription)
        )

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())

        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(failing.terminateCount, 1)
        XCTAssertEqual(succeeding.startCount, 1)
    }

    func testPresentationDetachLeavesEmbeddedProcessRunning() throws {
        let process = FakeEmbeddedTerminalProcess()
        let session = EmbeddedTerminalSession(processFactory: { process })
        let host = EmbeddedTerminalHostNSView()

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())
        host.install(session.hostedView)
        host.detach()

        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(process.terminateCount, 0)
        XCTAssertEqual(session.phase, .running)
        XCTAssertNil(process.view.superview)
    }

    func testPreviousHostDetachDoesNotRemoveReparentedTerminalView() {
        let terminalView = NSView()
        let firstHost = EmbeddedTerminalHostNSView()
        let secondHost = EmbeddedTerminalHostNSView()

        firstHost.install(terminalView)
        secondHost.install(terminalView)
        firstHost.detach()

        XCTAssertTrue(terminalView.superview === secondHost)
    }

    private func launch() -> ProcessManager.PreparedSessionLaunch {
        ProcessManager.PreparedSessionLaunch(
            executable: "/bin/bash",
            arguments: ["/tmp/voice_bridge_launch.command"],
            launcherPath: "/tmp/voice_bridge_launch.command",
            workingDirectory: "/repo"
        )
    }
}

private final class FakeEmbeddedTerminalProcess: EmbeddedTerminalProcess {
    let view = NSView()
    var isRunning = false
    var hasFocus = false
    var onExit: ((Int32?) -> Void)?
    var onTitle: ((String) -> Void)?
    var startError: Error?
    var startCount = 0
    var terminateCount = 0

    func start(_ launch: ProcessManager.PreparedSessionLaunch) throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
    }

    func focus() {
        hasFocus = true
    }

    func terminate() {
        terminateCount += 1
        isRunning = false
    }

    func emitExit(rawStatus: Int32?) {
        isRunning = false
        onExit?(rawStatus)
    }
}
