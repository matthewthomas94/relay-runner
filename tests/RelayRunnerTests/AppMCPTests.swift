import Foundation
import XCTest
@testable import relay_app_mcp

/// RR-459: the relay-app-mcp server against a fake app command socket.
final class AppMCPTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = "/tmp/ram-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
        let reply = try await server.dispatch(method: "tools/call", params: ["name": name, "arguments": arguments]) as? [String: Any]
        let text = ((reply?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, try XCTUnwrap(reply?["isError"] as? Bool))
    }

    // MARK: - Protocol surface

    func testClaudeCodeGetsCompactInstructionsAndOthersGetFullRules() async throws {
        let claude = MCPServer()
        let claudeResult = try await claude.dispatch(method: "initialize", params: ["clientInfo": ["name": "claude-code"]]) as? [String: Any]
        let compact = try XCTUnwrap(claudeResult?["instructions"] as? String)
        XCTAssertEqual(compact, Instructions.claudeCompact)
        XCTAssertLessThanOrEqual(compact.utf16.count, 2048)
        XCTAssertTrue(compact.contains("mcp__relay-app__get_relay_instructions"))
        XCTAssertTrue(compact.contains("before Relay Desktop, Relay Vision or Relay Actions"))

        let codex = MCPServer()
        let codexResult = try await codex.dispatch(method: "initialize", params: ["clientInfo": ["name": "codex-mcp-client"]]) as? [String: Any]
        let full = try XCTUnwrap(codexResult?["instructions"] as? String)
        XCTAssertEqual(full, Instructions.payload)
        XCTAssertTrue(full.contains("## Relay App"))
        XCTAssertTrue(full.contains("mcp__computer-use__*"))
        XCTAssertEqual((codexResult?["serverInfo"] as? [String: Any])?["name"] as? String, "relay-app")
    }

    func testToolsListAdvertisesEveryRelayAppTool() async throws {
        let list = try await MCPServer().dispatch(method: "tools/list", params: [:]) as? [String: Any]
        let tools = try XCTUnwrap(list?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, [
            "app_status", "end_session", "get_relay_instructions", "get_settings", "keep_awake", "list_projects",
            "navigate", "relay_remote_approve", "relay_remote_begin_pairing", "relay_remote_deny",
            "relay_remote_devices", "relay_remote_pending_approval", "relay_remote_unpair", "select_project",
            "set_settings", "start_session",
        ])
        for tool in tools {
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        }
        let schemas = Dictionary(uniqueKeysWithValues: tools.map { ($0["name"] as! String, $0["inputSchema"] as! [String: Any]) })
        XCTAssertEqual(schemas["end_session"]?["required"] as? [String], ["confirm"])
        XCTAssertEqual(schemas["relay_remote_unpair"]?["required"] as? [String], ["device_id", "confirm"])
        XCTAssertEqual(schemas["relay_remote_approve"]?["required"] as? [String], ["restrict_to_network"])
        let pages = ((schemas["navigate"]?["properties"] as? [String: Any])?["settings_page"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(pages, ["permissions", "speech_to_text", "text_to_speech", "general", "awareness", "relay_remote"])
    }

    func testGetRelayInstructionsReturnsFullRulesWithoutGlowing() async throws {
        var fired: [String] = []
        let server = MCPServer(notify: { fired.append($0) })
        let result = try await call(server, "get_relay_instructions")
        XCTAssertEqual(result.text, Instructions.payload)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(fired, [])
    }

    // MARK: - Refusals

    func testWhenTheAppIsNotRunningTheErrorSaysSo() async throws {
        var fired: [String] = []
        let path = directory + "/none.sock"
        let server = MCPServer(client: AppControlClient(path: path), notify: { fired.append($0) })
        let result = try await call(server, "app_status")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "Relay Runner is not running: nothing is listening on \(path). Open Relay Runner, then retry.")
        XCTAssertEqual(fired, [], "a failed call does not pulse ActionGlow")
    }

    func testDestructiveToolsRefuseWithoutConfirmBeforeReachingTheApp() async throws {
        let app = try FakeAppSocket(path: directory + "/app.sock")
        defer { app.close() }
        let server = MCPServer(client: AppControlClient(path: app.path), notify: { _ in })
        for (name, arguments) in [("end_session", [String: Any]()), ("end_session", ["confirm": false]), ("end_session", ["confirm": "true"]),
                                  ("relay_remote_unpair", ["device_id": "phone-1"]), ("relay_remote_unpair", ["device_id": "phone-1", "confirm": 1])] {
            let result = try await call(server, name, arguments)
            XCTAssertTrue(result.isError, "\(name) \(arguments)")
            XCTAssertTrue(result.text.hasPrefix("Refused: \(name) is destructive"), result.text)
        }
        XCTAssertEqual(app.requests.count, 0)

        let confirmed = try await call(server, "relay_remote_unpair", ["device_id": "phone-1", "confirm": true])
        XCTAssertFalse(confirmed.isError, confirmed.text)
        XCTAssertEqual(app.requests.last?["arguments"] as? NSDictionary, ["device_id": "phone-1", "confirm": true])
    }

    func testAnAppRefusalIsReturnedAsAToolError() async throws {
        let app = try FakeAppSocket(path: directory + "/app.sock", refuse: "Unknown setting 'tts.loudness'.")
        defer { app.close() }
        var fired: [String] = []
        let server = MCPServer(client: AppControlClient(path: app.path), notify: { fired.append($0) })
        let result = try await call(server, "set_settings", ["settings": ["tts": ["loudness": 11]]])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "Unknown setting 'tts.loudness'.")
        XCTAssertEqual(fired, [])
    }

    // MARK: - Loopback

    func testEveryToolForwardsItsCommandReturnsJSONAndEmitsToolFired() async throws {
        let app = try FakeAppSocket(path: directory + "/app.sock")
        defer { app.close() }
        var fired: [String] = []
        let server = MCPServer(client: AppControlClient(path: app.path), notify: { fired.append($0) })
        let calls: [(String, [String: Any])] = [
            ("app_status", [:]),
            ("navigate", ["destination": "settings", "settings_page": "relay_remote"]),
            ("get_settings", [:]),
            ("set_settings", ["settings": ["tts": ["rate": 1.2]]]),
            ("list_projects", [:]),
            ("select_project", ["project_id": "p-relay"]),
            ("start_session", ["project_id": "p-relay"]),
            ("end_session", ["confirm": true]),
            ("relay_remote_devices", [:]),
            ("relay_remote_unpair", ["device_id": "phone-1", "confirm": true]),
            ("relay_remote_begin_pairing", [:]),
            ("relay_remote_pending_approval", [:]),
            ("relay_remote_approve", ["restrict_to_network": true]),
            ("relay_remote_deny", [:]),
            ("keep_awake", ["on": true]),
        ]
        for (name, arguments) in calls {
            let result = try await call(server, name, arguments)
            XCTAssertFalse(result.isError, "\(name): \(result.text)")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any], name)
            XCTAssertEqual(json["echo"] as? String, name)
        }
        XCTAssertEqual(app.requests.compactMap { $0["command"] as? String }, calls.map(\.0))
        XCTAssertEqual(fired, calls.map(\.0))
        for (request, (_, arguments)) in zip(app.requests, calls) {
            XCTAssertEqual(request["type"] as? String, "app_command")
            XCTAssertEqual(request["arguments"] as? NSDictionary, arguments as NSDictionary)
        }
        // Pushed session_state lines meant for the phone are skipped.
        XCTAssertGreaterThan(app.pushes, 0)
    }
}

/// Answers each `app_command` with `{"echo": <command>}` after first pushing a
/// `session_state` line, as the real socket may.
private final class FakeAppSocket: @unchecked Sendable {
    let path: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var received: [[String: Any]] = []
    private var pushed = 0

    var requests: [[String: Any]] { lock.withLock { received } }
    var pushes: Int { lock.withLock { pushed } }

    init(path: String, refuse: String? = nil) throws {
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
                let request = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any] ?? [:]
                self?.lock.withLock {
                    self?.received.append(request)
                    self?.pushed += 1
                }
                var reply: [String: Any] = ["type": "app_result", "id": request["id"] ?? ""]
                if let refuse {
                    reply["ok"] = false
                    reply["error"] = refuse
                } else {
                    reply["ok"] = true
                    reply["result"] = ["echo": request["command"] ?? ""]
                }
                var out = Data(#"{"app_running":true,"session":"none","type":"session_state"}"#.utf8 + [0x0A])
                out.append(try! JSONSerialization.data(withJSONObject: reply))
                out.append(0x0A)
                _ = out.withUnsafeBytes { write(conn, $0.baseAddress, out.count) }
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
