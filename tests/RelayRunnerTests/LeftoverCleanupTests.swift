import XCTest
@testable import relay_runner

/// RR-508: Start Session asks the daemon to stop leftovers in the background,
/// and app launch removes session folders no live session owns.
final class LeftoverCleanupTests: XCTestCase {
    func testCleanRequestPostsToTheMaintenanceRoute() throws {
        let request = try XCTUnwrap(OrchestratorClient.cleanLeftoversRequest(port: 8123))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8123/v1/maintenance/leftovers/clean")
    }

    func testOnlyTerminatedOrKilledEntriesCountAsStopped() {
        let body = #"""
        {"mode":"stop","leftovers":[],"stopped":[
          {"pid":1,"outcome":"terminated"},{"pid":2,"outcome":"killed"},
          {"pid":3,"outcome":"gone"},{"pid":4,"outcome":"survived"}]}
        """#
        XCTAssertEqual(OrchestratorClient.stoppedLeftoverCount(from: Data(body.utf8)), 2)
        // Report mode, nothing stopped, off mode, and an unreadable body.
        XCTAssertEqual(OrchestratorClient.stoppedLeftoverCount(
            from: Data(#"{"mode":"report","leftovers":[{"tier":1}],"stopped":[]}"#.utf8)), 0)
        XCTAssertEqual(OrchestratorClient.stoppedLeftoverCount(from: Data(#"{"mode":"off"}"#.utf8)), 0)
        XCTAssertEqual(OrchestratorClient.stoppedLeftoverCount(from: Data("nope".utf8)), 0)
    }

    func testNoticeAppearsOnlyWhenSomethingWasStopped() {
        XCTAssertNil(SessionSwitchNotice(leftoversStopped: 0))
        XCTAssertEqual(SessionSwitchNotice(leftoversStopped: 1)?.label, "Stopped 1 leftover process")
        XCTAssertEqual(SessionSwitchNotice(leftoversStopped: 3)?.label, "Stopped 3 leftover processes")
        XCTAssertEqual(SessionSwitchNotice(leftoversStopped: 1)?.duration, SessionSwitchNotice.leftoversDisplayDuration)
        let shown = NotchVisualLabelAllowlist.presentation(
            for: .idle, switchNotice: SessionSwitchNotice(leftoversStopped: 2)
        )
        XCTAssertEqual(shown.labels, ["Stopped 2 leftover processes"])
    }

    @MainActor
    func testStartingTheCleanupReturnsBeforeTheDaemonAnswers() async {
        let release = AsyncStream<Void>.makeStream()
        let delivered = expectation(description: "delivered")
        var stopped: Int?
        let started = Date()
        let task = AppState.startLeftoverCleanup(
            clean: {
                for await _ in release.stream { break }
                return 2
            },
            deliver: { count in
                stopped = count
                delivered.fulfill()
            }
        )
        // The launch path continues while the daemon is still working.
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertNil(stopped)
        release.continuation.yield()
        await fulfillment(of: [delivered], timeout: 5)
        await task.value
        XCTAssertEqual(stopped, 2)
    }

    @MainActor
    func testAnUnreachableDaemonDeliversZero() async {
        let delivered = expectation(description: "delivered")
        var stopped: Int?
        AppState.startLeftoverCleanup(clean: { nil }, deliver: { count in
            stopped = count
            delivered.fulfill()
        })
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(stopped, 0)
    }

    func testLaunchCleanupRemovesOnlyUnkeptDirectoriesOfThisUser() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("rr-spools-\(UUID().uuidString)")
        addTeardownBlock { try? fileManager.removeItem(at: base) }
        let root = base.appendingPathComponent("relay-sessions")
        let outside = base.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let live = VoiceSessionSpool(key: "live", rootDirectory: root.path)
        let stale = VoiceSessionSpool(key: "stale", rootDirectory: root.path)
        try live.prepare(); try stale.prepare()
        try Data("x".utf8).write(to: URL(fileURLWithPath: stale.command))
        try Data().write(to: root.appendingPathComponent("not-a-folder"))
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        XCTAssertEqual(VoiceSessionSpool.removeStale(keeping: ["live"], rootDirectory: root.path), ["stale"])
        XCTAssertTrue(fileManager.fileExists(atPath: live.directory))
        XCTAssertFalse(fileManager.fileExists(atPath: stale.directory))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("not-a-folder").path))
        XCTAssertTrue(fileManager.fileExists(atPath: outside.path))

        // A missing root, or a root that is a symlink, is left alone.
        XCTAssertEqual(VoiceSessionSpool.removeStale(keeping: [], rootDirectory: base.appendingPathComponent("none").path), [])
        let linkedRoot = base.appendingPathComponent("linked-root")
        try fileManager.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        XCTAssertEqual(VoiceSessionSpool.removeStale(keeping: [], rootDirectory: linkedRoot.path), [])
        XCTAssertTrue(fileManager.fileExists(atPath: live.directory))
    }
}
