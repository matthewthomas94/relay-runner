import XCTest
@testable import relay_orchestrator_mcp

final class OrchestratorMCPClientInstructionsTests: XCTestCase {
    // Digests of the release before Claude-specific payloads (3be285a2),
    // taken from a non-Claude client. They must not change for Codex.
    private let releasedInitializeSHA256 = "ae4e61611f610fc9ba4a21e290ab0d4559566778358f02046b1f55fd05508fb3"
    private let releasedInstructionsSHA256 = "0393d403a3bbeac161c49c05301bd4ed2705b416d327cb938bcb102ae3c6df8e"
    private let releasedToolsListSHA256 = "b48fb7b52913ace373633b1bf8710573c51b54c9cb90d875907b0ce72109595d"

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

    func testNonClaudeClientsKeepReleasedInstructionsAndTools() async throws {
        for client in ["codex-mcp-client", "rr-326-probe"] {
            let server = MCPServer()
            let result = try await initialize(server, client: client)
            XCTAssertEqual(try mcpCanonicalJSONSHA256(result), releasedInitializeSHA256, client)
            XCTAssertEqual(mcpSHA256(try XCTUnwrap(result["instructions"] as? String)), releasedInstructionsSHA256)
            let tools = try await server.dispatch(method: "tools/list", params: [:])
            XCTAssertEqual(try mcpCanonicalJSONSHA256(tools), releasedToolsListSHA256, client)
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
    }

    func testPingReturnsEmptyResult() async throws {
        let result = try await MCPServer().dispatch(method: "ping", params: [:]) as? [String: Any]
        XCTAssertEqual(result?.isEmpty, true)
    }
}
