import Foundation
import XCTest

/// Runs the built `relay-remote-shell` binary against a fake Unix socket server.
final class RelayRemoteShellTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "rrs\(getpid())\(UInt32.random(in: 0...9999))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("relay-remote-shell")
    }

    final class FakeServer {
        let path: String
        let listenFD: Int32
        var clientFD: Int32 = -1

        init(path: String) throws {
            self.path = path
            listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (i, b) in path.utf8.enumerated() { raw[i] = b }
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0, Darwin.listen(listenFD, 1) == 0 else { throw NSError(domain: "bind", code: Int(errno)) }
        }

        func accept() { clientFD = Darwin.accept(listenFD, nil, nil) }

        func readLine() -> String? {
            var bytes: [UInt8] = []
            var b: UInt8 = 0
            while Darwin.read(clientFD, &b, 1) == 1 {
                if b == 0x0A { return String(decoding: bytes, as: UTF8.self) }
                bytes.append(b)
            }
            return nil
        }

        func send(_ data: Data) { _ = data.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress, data.count) } }
        func send(_ s: String) { send(Data(s.utf8)) }
        func closeClient() { close(clientFD) }
        func shutdown() { close(listenFD); unlink(path) }
    }

    private func spawn(_ args: [String], env: [String: String] = [:]) throws -> (Process, FileHandle, FileHandle) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var environment = [
            "RELAY_REMOTE_SOCKET_PATH": dir + "/d.sock",
            "RELAY_REMOTE_PAIR_SOCKET_PATH": dir + "/p.sock",
        ]
        environment.merge(env) { $1 }
        p.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        try p.run()
        return (p, stdin.fileHandleForWriting, stdout.fileHandleForReading)
    }

    private func waitExit(_ p: Process, timeout: TimeInterval = 5) -> Int32? {
        let end = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < end { usleep(10_000) }
        return p.isRunning ? nil : p.terminationStatus
    }

    private func readLine(_ h: FileHandle) -> String? {
        var bytes: [UInt8] = []
        while let b = try? h.read(upToCount: 1), b.count == 1 {
            if b[0] == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(b[0])
        }
        return nil
    }

    func testDeviceModePassesLinesBothWays() throws {
        let server = try FakeServer(path: dir + "/d.sock")
        defer { server.shutdown() }
        let (p, stdin, stdout) = try spawn(["--device", "dev-1"])
        server.accept()
        XCTAssertEqual(server.readLine(), #"{"device_id":"dev-1","type":"identify"}"#)
        try stdin.write(contentsOf: Data(#"{"type":"ping","t":1}"#.utf8 + [0x0A]))
        XCTAssertEqual(server.readLine(), #"{"type":"ping","t":1}"#)
        server.send(#"{"type":"pong","t":1}"# + "\n")
        XCTAssertEqual(readLine(stdout), #"{"type":"pong","t":1}"#)
        try stdin.close()
        XCTAssertEqual(waitExit(p), 0)
    }

    func testPairModeUsesPairSocket() throws {
        let server = try FakeServer(path: dir + "/p.sock")
        defer { server.shutdown() }
        let (p, stdin, stdout) = try spawn(["--pair", "pair-9"])
        server.accept()
        XCTAssertEqual(server.readLine(), #"{"pairing_id":"pair-9","type":"identify"}"#)
        server.send(#"{"type":"status","seq":1,"text":"ok"}"# + "\n")
        XCTAssertEqual(readLine(stdout), #"{"type":"status","seq":1,"text":"ok"}"#)
        try stdin.close()
        XCTAssertEqual(waitExit(p), 0)
    }

    func testOversizeClientLineIsRejected() throws {
        let server = try FakeServer(path: dir + "/d.sock")
        defer { server.shutdown() }
        let (p, stdin, stdout) = try spawn(["--device", "dev-1"])
        server.accept()
        _ = server.readLine()
        let big = #"{"type":"utterance","text":""# + String(repeating: "a", count: 70_000) + #""}"#
        try? stdin.write(contentsOf: Data((big + "\n").utf8))
        let reply = readLine(stdout) ?? ""
        XCTAssertTrue(reply.contains(#""code":"line_too_long""#), reply)
        XCTAssertEqual(waitExit(p), 1)
        XCTAssertNil(server.readLine(), "oversize line must not reach the socket")
    }

    func testOversizeBridgeLineIsRejected() throws {
        let server = try FakeServer(path: dir + "/d.sock")
        defer { server.shutdown() }
        let (p, _, stdout) = try spawn(["--device", "dev-1"])
        server.accept()
        _ = server.readLine()
        server.send(Data(repeating: 0x61, count: 70_000))
        let reply = readLine(stdout) ?? ""
        XCTAssertTrue(reply.contains(#""code":"line_too_long""#), reply)
        XCTAssertEqual(waitExit(p), 1)
    }

    func testUnparsableLineIsRejected() throws {
        let server = try FakeServer(path: dir + "/d.sock")
        defer { server.shutdown() }
        let (p, stdin, stdout) = try spawn(["--device", "dev-1"])
        server.accept()
        _ = server.readLine()
        try stdin.write(contentsOf: Data("not json\n".utf8))
        XCTAssertTrue((readLine(stdout) ?? "").contains(#""code":"invalid_json""#))
        XCTAssertEqual(waitExit(p), 1)
    }

    func testBridgeClosingEndsProcess() throws {
        let server = try FakeServer(path: dir + "/d.sock")
        defer { server.shutdown() }
        let (p, _, _) = try spawn(["--device", "dev-1"])
        server.accept()
        _ = server.readLine()
        server.closeClient()
        XCTAssertEqual(waitExit(p), 0)
    }

    func testClientClosingEndsProcessAndSocket() throws {
        let server = try FakeServer(path: dir + "/d.sock")
        defer { server.shutdown() }
        let (p, stdin, _) = try spawn(["--device", "dev-1"])
        server.accept()
        _ = server.readLine()
        try stdin.close()
        XCTAssertEqual(waitExit(p), 0)
        XCTAssertNil(server.readLine())
    }

    func testStatusSubcommandReturnsOneFrame() throws {
        let server = try FakeServer(path: dir + "/d.sock")
        defer { server.shutdown() }
        let (p, _, stdout) = try spawn(["--device", "dev-1"], env: ["SSH_ORIGINAL_COMMAND": "status"])
        server.accept()
        XCTAssertEqual(server.readLine(), #"{"command":"status","device_id":"dev-1","type":"identify"}"#)
        server.send(#"{"type":"status","seq":0,"text":"running"}"# + "\n")
        XCTAssertEqual(readLine(stdout), #"{"type":"status","seq":0,"text":"running"}"#)
        XCTAssertEqual(waitExit(p), 0)
    }

    func testDisallowedCommandExitsTwoWithoutConnecting() throws {
        let server = try FakeServer(path: dir + "/d.sock")
        defer { server.shutdown() }
        var flags = fcntl(server.listenFD, F_GETFL)
        flags |= O_NONBLOCK
        _ = fcntl(server.listenFD, F_SETFL, flags)
        let (p, _, stdout) = try spawn(["--device", "dev-1"], env: ["SSH_ORIGINAL_COMMAND": "cat /etc/passwd"])
        XCTAssertEqual(waitExit(p), 2)
        XCTAssertTrue((readLine(stdout) ?? "").contains(#""type":"error""#))
        XCTAssertLessThan(Darwin.accept(server.listenFD, nil, nil), 0, "no connection must have been attempted")
    }

    func testMissingSocketReportsBridgeUnavailable() throws {
        let (p, _, stdout) = try spawn(["--device", "dev-1"])
        XCTAssertTrue((readLine(stdout) ?? "").contains(#""code":"bridge_unavailable""#))
        XCTAssertEqual(waitExit(p), 1)
    }
}
