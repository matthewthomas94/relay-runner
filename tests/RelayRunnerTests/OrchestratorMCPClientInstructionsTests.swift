import XCTest
@testable import relay_orchestrator_mcp

final class OrchestratorMCPClientInstructionsTests: XCTestCase {
    // tools/list digest shipped in v0.4.66, including the dependency-queue
    // description (RR-410). Non-Claude clients must keep this same payload.
    private let releasedToolsListSHA256 = "b855e00b80b75b569411c399155eb54a7f2ef655a531003e8ba12518a9383e0a"

    private func initialize(_ server: MCPServer, client: String) async throws -> [String: Any] {
        let result = try await server.dispatch(
            method: "initialize",
            params: ["clientInfo": ["name": client, "version": "1"]]
        )
        return try XCTUnwrap(result as? [String: Any])
    }

    private func toolNames(_ server: MCPServer) async throws -> [String] {
        let result = try await server.dispatch(method: "tools/list", params: [:]) as? [String: Any]
        let tools = try XCTUnwrap(result?["tools"] as? [[String: Any]])
        return tools.compactMap { $0["name"] as? String }
    }

    func testNonClaudeClientsGetFullRulesAndReleasedTools() async throws {
        for client in ["codex-mcp-client", "rr-326-probe"] {
            let server = MCPServer()
            let result = try await initialize(server, client: client)
            // Codex gets the same full rules claude-code fetches on demand.
            XCTAssertEqual(result["instructions"] as? String, Instructions.payload, client)
            XCTAssertEqual(Instructions.payload, Instructions.claudeFull)
            let tools = try await server.dispatch(method: "tools/list", params: [:])
            XCTAssertEqual(try mcpCanonicalJSONSHA256(tools), releasedToolsListSHA256, client)
            let names = try await toolNames(server)
            XCTAssertFalse(names.contains("general_task"))
            assertGeneralRules(try XCTUnwrap(result["instructions"] as? String))
        }
    }

    func testNonClaudeClientCannotCallRelayInstructionsTool() async throws {
        let server = MCPServer()
        _ = try await initialize(server, client: "codex-mcp-client")
        do {
            _ = try await server.dispatch(method: "tools/call", params: ["name": "get_relay_instructions"])
            XCTFail("get_relay_instructions must be claude-code only")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32602)
        }
    }

    func testClaudeCodeGetsCompactInstructionsAndFullRulesTool() async throws {
        let server = MCPServer()
        let result = try await initialize(server, client: "claude-code")
        let instructions = try XCTUnwrap(result["instructions"] as? String)
        XCTAssertEqual(instructions, Instructions.claudeCompact)
        XCTAssertLessThanOrEqual(instructions.utf16.count, 2048)
        XCTAssertTrue(instructions.contains("mcp__relay-orchestrator__get_relay_instructions"))
        XCTAssertTrue(instructions.contains("claude auth login"))
        XCTAssertTrue(instructions.contains("Never suggest adding an API key"))

        let names = try await toolNames(server)
        XCTAssertTrue(names.contains("get_relay_instructions"))
        XCTAssertTrue(names.contains("dispatch_ticket"))
        XCTAssertFalse(names.contains("general_task"))

        let call = try await server.dispatch(
            method: "tools/call",
            params: ["name": "get_relay_instructions", "arguments": [String: Any]()]
        ) as? [String: Any]
        XCTAssertEqual(call?["isError"] as? Bool, false)
        let content = try XCTUnwrap(call?["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertEqual(text, Instructions.claudeFull)
        XCTAssertTrue(text.contains("## Subscription-only provider access"))
        XCTAssertTrue(text.contains("artifact-backed ticket writer"))
        XCTAssertTrue(text.contains("### Worker sizing"))
        assertGeneralRules(text)
    }

    private func assertGeneralRules(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for rule in ["general-tasks", "Application Support/relay-runner/general-tasks", "existing Projects list",
                     "Every project's tickets", "Task / Action / Discussion", "Small bounded actions",
                     "GitHub storage is optional", "confirmed source repository"] {
            XCTAssertTrue(text.contains(rule), "Missing General rule: \(rule)", file: file, line: line)
        }
    }

    func testPingReturnsEmptyResult() async throws {
        let result = try await MCPServer().dispatch(method: "ping", params: [:]) as? [String: Any]
        XCTAssertEqual(result?.isEmpty, true)
    }
}
