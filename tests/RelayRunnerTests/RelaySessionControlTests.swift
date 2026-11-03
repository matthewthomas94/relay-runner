import Foundation
import RelayRemoteProtocol
import XCTest
@testable import relay_runner

/// RR-456: the app's session-control handler through injected AppState
/// closures, and the socket it listens on.
@MainActor
final class RelaySessionControlTests: XCTestCase {
    private final class FakeHost {
        var projects = [
            RelaySessionControlHost.Project(id: "p-relay", name: "relay-runner", path: "/repos/relay-runner", availability: "available"),
            RelaySessionControlHost.Project(id: "p-notes", name: "notes", path: "/repos/notes", availability: "available"),
            RelaySessionControlHost.Project(id: "p-gone", name: "old", path: "/repos/old", availability: "missing"),
        ]
        var snapshot = RelaySessionControlHost.Snapshot()
        var started: [String] = []
        var stops = 0
        var startResult = true
        var message: String?
        /// What `newSession` does to app state when it accepts a launch.
        var onStart: ((FakeHost, String) -> Void)? = { host, _ in host.snapshot.launching = true }

        var host: RelaySessionControlHost {
            RelaySessionControlHost(
                projects: { self.projects },
                snapshot: { self.snapshot },
                start: { path in
                    self.started.append(path)
                    if self.startResult { self.onStart?(self, path) }
                    return self.startResult
                },
                stop: {
                    self.stops += 1
                    self.snapshot = .init()
                },
                message: { self.message }
            )
        }
    }

    private var fake: FakeHost!
    private var control: RelaySessionControl!

    override func setUp() async throws {
        fake = FakeHost()
        control = RelaySessionControl(host: fake.host)
    }

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func command(_ action: SessionAction, project: String? = nil, clientID: String = UUID().uuidString) -> Data {
        Data(try! FrameCodec.encode(.sessionCommand(SessionCommand(clientId: clientID, action: action, projectId: project))).dropLast())
    }

    private func state(_ frames: [Frame], file: StaticString = #filePath, line: UInt = #line) -> SessionState? {
        guard frames.count == 1, case .sessionState(let state) = frames[0] else {
            XCTFail("expected one session_state, got \(frames)", file: file, line: line)
            return nil
        }
        return state
    }

    // MARK: Handler

    func testIdentifyReportsNoSessionWithTheRegisteredProjects() throws {
        let reply = try XCTUnwrap(state(control.handle(line: line(["type": "identify", "device_id": "phone-1"]))))
        XCTAssertTrue(reply.appRunning)
        XCTAssertEqual(reply.session, .noSession)
        XCTAssertNil(reply.projectId)
        XCTAssertEqual(reply.projects, [
            ProjectSummary(projectId: "p-relay", displayName: "relay-runner", availability: "available"),
            ProjectSummary(projectId: "p-notes", displayName: "notes", availability: "available"),
            ProjectSummary(projectId: "p-gone", displayName: "old", availability: "missing"),
        ])
    }

    func testHelloIsIgnoredAndPingIsAnswered() {
        let hello = line(["type": "hello", "protocol": 1, "device_id": "phone-1", "device_name": "iPhone", "app_version": "0.1"])
        XCTAssertEqual(control.handle(line: hello), [])
        XCTAssertEqual(control.handle(line: line(["type": "ping", "t": 7])), [.pong(Pong(t: 7))])
        XCTAssertEqual(control.handle(line: Data("not json".utf8)), [])
    }

    func testInvalidCommandIsRejectedWithTheSharedErrorCode() {
        let reply = control.handle(line: line(["type": "session_command", "client_id": "abc", "action": "stop"]))
        XCTAssertEqual(reply, [.error(ErrorFrame(code: "invalid_field", message: "Frame rejected"))])
        XCTAssertEqual(fake.stops, 0)
    }

    func testListProjectsAndStateCommands() throws {
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.listProjects)))).projects?.count, 3)
        let current = try XCTUnwrap(state(control.handle(line: command(.state))))
        XCTAssertEqual(current.session, .noSession)
        XCTAssertNil(current.projects)
    }

    func testStartUsesTheProjectPathAndReportsStartingThenReady() throws {
        let starting = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay"))))
        XCTAssertEqual(fake.started, ["/repos/relay-runner"])
        XCTAssertEqual(starting.session, .starting)
        XCTAssertEqual(starting.projectId, "p-relay")
        XCTAssertEqual(starting.projectName, "relay-runner")

        // The provider is up but the bridge is not consuming yet.
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner")])
        XCTAssertEqual(control.pushIfChanged()?.session, .starting)
        XCTAssertNil(control.pushIfChanged(), "an unchanged state is not pushed again")

        control.bridgeAccepting = true
        let ready = try XCTUnwrap(control.pushIfChanged())
        XCTAssertEqual(ready.session, .ready)
        XCTAssertEqual(ready.projectId, "p-relay")
        XCTAssertNil(ready.error)
    }

    func testRefusedStartReportsFailedWithTheAppsNewMessage() throws {
        fake.message = "Conversation restored."
        fake.startResult = false
        let generic = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay"))))
        XCTAssertEqual(fake.started, ["/repos/relay-runner"])
        XCTAssertEqual(generic.session, .failed)
        XCTAssertEqual(generic.error, "Relay Runner could not start relay-runner on this Mac.",
                       "a message that was already showing is not the reason")

        var host = fake.host
        host.start = { _ in
            self.fake.message = "Session limit reached"
            return false
        }
        let refusing = RelaySessionControl(host: host)
        let reasoned = try XCTUnwrap(state(refusing.handle(line: command(.start, project: "p-notes"))))
        XCTAssertEqual(reasoned.session, .failed)
        XCTAssertEqual(reasoned.projectName, "notes")
        XCTAssertEqual(reasoned.error, "Session limit reached")
    }

    func testALaunchThatEndsBeforeReadyIsReportedFailed() throws {
        _ = control.handle(line: command(.start, project: "p-relay"))
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner")])
        XCTAssertEqual(control.pushIfChanged()?.session, .starting)
        fake.snapshot = .init()
        let failed = try XCTUnwrap(control.pushIfChanged())
        XCTAssertEqual(failed.session, .failed)
        XCTAssertEqual(failed.projectId, "p-relay")
        XCTAssertEqual(failed.error, "The session for relay-runner ended before it was ready.")
        // A reconnecting phone still learns why.
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: line(["type": "identify", "device_id": "p"])))).session, .failed)
    }

    func testStartWhileAnotherProjectRunsIsRefusedWithItsName() throws {
        fake.snapshot = .init(live: [.init(projectID: "p-notes", name: "notes")])
        control.bridgeAccepting = true
        let refused = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay"))))
        XCTAssertEqual(fake.started, [])
        XCTAssertEqual(refused.session, .ready)
        XCTAssertEqual(refused.projectName, "notes")
        XCTAssertEqual(refused.error, "notes is already running on this Mac. Stop it before starting relay-runner.")
    }

    func testStartingTheRunningProjectAgainOnlyReportsIt() throws {
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner")])
        control.bridgeAccepting = true
        let reply = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay"))))
        XCTAssertEqual(fake.started, [])
        XCTAssertEqual(reply.session, .ready)
        XCTAssertNil(reply.error)
    }

    func testStartIsRefusedForUnknownUnavailableOrMissingProjectsAndWhileBusy() throws {
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.start)))).error, "Choose a project to start.")
        let unknown = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-nope"))))
        XCTAssertEqual(unknown.error, "That project is no longer registered on this Mac.")
        XCTAssertEqual(unknown.projects?.count, 3, "the phone gets a fresh list to choose from")
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.start, project: "p-gone")))).error,
                       "old is not available on this Mac.")
        fake.snapshot = .init(launching: true)
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay")))).error,
                       "A session is already starting on this Mac.")
        fake.snapshot = .init(startBlockedReason: "Relay Runner is taking notes on this Mac. Finish the note first.")
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay")))).error,
                       "Relay Runner is taking notes on this Mac. Finish the note first.")
        XCTAssertEqual(fake.started, [])
    }

    func testStopEndsTheSessionAndReportsNoneAtOnce() throws {
        // endSession() returns before the provider releases its PTY.
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner")])
        var host = fake.host
        host.stop = { self.fake.stops += 1 }
        let control = RelaySessionControl(host: host)
        control.bridgeAccepting = true

        let reply = try XCTUnwrap(state(control.handle(line: command(.stop))))
        XCTAssertEqual(fake.stops, 1)
        XCTAssertEqual(reply.session, .noSession)
        XCTAssertEqual(control.pushIfChanged()?.session, .noSession, "still ending")

        fake.snapshot = .init()
        XCTAssertNil(control.pushIfChanged())
        // A session started later on the Mac is reported again.
        fake.snapshot = .init(live: [.init(projectID: "p-notes", name: "notes")])
        XCTAssertEqual(control.pushIfChanged()?.session, .ready)
    }

    func testStopWithNothingRunningDoesNotCallEndSession() throws {
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.stop)))).session, .noSession)
        XCTAssertEqual(fake.stops, 0)
    }

    func testARetriedCommandIsNotPerformedTwice() throws {
        let id = UUID().uuidString
        _ = control.handle(line: command(.start, project: "p-relay", clientID: id))
        let retry = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay", clientID: id))))
        XCTAssertEqual(fake.started.count, 1)
        XCTAssertEqual(retry.session, .starting)
        XCTAssertNil(retry.error, "the retry is not refused as a second start")
    }

    // MARK: Socket

    func testSocketIsOwnerOnlyAnswersIdentifyAndPushesReadyFromTheBridgeProbe() async throws {
        let directory = "/tmp/rsc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/c.sock"
        let bridgePath = directory + "/b.sock"
        let server = RelaySessionControlServer(control: control, path: path, bridgePath: bridgePath, tickInterval: 0.05)
        try server.start()
        defer { server.stop() }
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)

        let client = try SocketClient(path: path)
        client.send(#"{"device_id":"phone-1","type":"identify"}"#)
        let first = try await client.frame()
        guard case .sessionState(let none) = first else { return XCTFail("expected session_state, got \(first)") }
        XCTAssertEqual(none.session, .noSession)
        XCTAssertEqual(none.projects?.map(\.projectId), ["p-relay", "p-notes", "p-gone"])

        // Pushes of the unchanged `none` state may arrive before the reply.
        client.send(String(decoding: command(.start, project: "p-relay"), as: UTF8.self))
        while try await client.sessionPhase() != .starting {}
        XCTAssertEqual(fake.started, ["/repos/relay-runner"])

        // The provider comes up, then the bridge starts consuming.
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner")])
        let bridge = try FakeBridge(path: bridgePath)
        defer { bridge.close() }
        while try await client.sessionPhase() != .ready {}
        XCTAssertGreaterThanOrEqual(bridge.probes, 1)
    }

    func testBridgeProbeNeedsARunningBridge() throws {
        let directory = "/tmp/rsb-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        XCTAssertFalse(RelaySessionControlServer.bridgeAccepting(at: directory + "/none.sock"))
        let idle = try FakeBridge(path: directory + "/idle.sock", text: "idle")
        defer { idle.close() }
        XCTAssertFalse(RelaySessionControlServer.bridgeAccepting(at: directory + "/idle.sock"))
        let running = try FakeBridge(path: directory + "/run.sock")
        defer { running.close() }
        XCTAssertTrue(RelaySessionControlServer.bridgeAccepting(at: directory + "/run.sock"))
        XCTAssertEqual(running.identifies.first, #"{"command":"status","device_id":"relay-runner-app","type":"identify"}"#)
    }
}

/// A connected Unix stream socket with a line reader.
private final class SocketClient {
    private let fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    deinit { close(fd) }

    func send(_ line: String) {
        let data = Data((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    @MainActor
    func sessionPhase() async throws -> SessionPhase? {
        guard case .sessionState(let state) = try await frame() else { return nil }
        return state.session
    }

    /// The next frame, polling so the main actor keeps serving the server's hops.
    @MainActor
    func frame(timeout: Double = 5) async throws -> Frame {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                return try FrameCodec.decode(line)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 { throw POSIXError(.ECONNRESET) }
            guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Answers the helper's `status` identify like services/relay_remote.py.
private final class FakeBridge: @unchecked Sendable {
    private let listenFD: Int32
    private let path: String
    private let lock = NSLock()
    private var lines: [String] = []

    var probes: Int { lock.withLock { lines.count } }
    var identifies: [String] { lock.withLock { lines } }

    init(path: String, text: String = "running") throws {
        self.path = path
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(listenFD, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let conn = accept(fd, nil, nil)
                guard conn >= 0 else { return }
                var bytes: [UInt8] = []
                var b: UInt8 = 0
                while read(conn, &b, 1) == 1, b != 0x0A { bytes.append(b) }
                self?.lock.withLock { self?.lines.append(String(decoding: bytes, as: UTF8.self)) }
                let reply = Data(#"{"seq":0,"text":"\#(text)","type":"status"}"#.utf8 + [0x0A])
                _ = reply.withUnsafeBytes { write(conn, $0.baseAddress, reply.count) }
                Darwin.close(conn)
            }
        }
    }

    func close() {
        shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        unlink(path)
    }
}
