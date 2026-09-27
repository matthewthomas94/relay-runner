import XCTest
@testable import relay_actions_mcp

final class ActionsMCPClientInstructionsTests: XCTestCase {
    // Digests of the release before Claude-specific payloads (3be285a2),
    // taken from a non-Claude client. They must not change for Codex.
    private let releasedInitializeSHA256 = "ca4a74a31f6dd7e7a063d25c3e92d3504a92ac7a9cb993bda9809413b7f41590"
    private let releasedInstructionsSHA256 = "b7ca634499dee2dd65691c83fce4bd7fb5afd41c3438167f5f17703ab242f3f0"
    private let releasedToolsListSHA256 = "a56d224b66dd107c4eeac4dc40d09adac3908a2564083dc96cc5553540e23c21"

    private func initialize(_ server: MCPServer, client: String) async throws -> [String: Any] {
        let result = try await server.dispatch(
            method: "initialize",
            params: ["clientInfo": ["name": client, "version": "1"]]
        )
        return try XCTUnwrap(result as? [String: Any])
    }

    private func tools(_ server: MCPServer) async throws -> [String: [String: Any]] {
        let result = try await server.dispatch(method: "tools/list", params: [:]) as? [String: Any]
        let tools = try XCTUnwrap(result?["tools"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: tools.map { ($0["name"] as? String ?? "", $0) })
    }

    func testNonClaudeClientsKeepReleasedInstructionsAndTools() async throws {
        for client in ["codex-mcp-client", "rr-326-probe"] {
            let server = MCPServer()
            let result = try await initialize(server, client: client)
            XCTAssertEqual(try mcpCanonicalJSONSHA256(result), releasedInitializeSHA256, client)
            XCTAssertEqual(mcpSHA256(try XCTUnwrap(result["instructions"] as? String)), releasedInstructionsSHA256)
            let list = try await server.dispatch(method: "tools/list", params: [:])
            XCTAssertEqual(try mcpCanonicalJSONSHA256(list), releasedToolsListSHA256, client)
        }
    }

    func testClaudeCodeGetsCompactInstructionsAndFullRulesTool() async throws {
        let server = MCPServer()
        let result = try await initialize(server, client: "claude-code")
        let instructions = try XCTUnwrap(result["instructions"] as? String)
        XCTAssertEqual(instructions, Instructions.claudeCompact)
        XCTAssertLessThanOrEqual(instructions.utf16.count, 2048)
        XCTAssertTrue(instructions.contains("mcp__relay-actions__get_relay_instructions"))

        let byName = try await tools(server)
        XCTAssertNotNil(byName["get_relay_instructions"])
        let call = try await server.dispatch(
            method: "tools/call",
            params: ["name": "get_relay_instructions", "arguments": [String: Any]()]
        ) as? [String: Any]
        let content = try XCTUnwrap(call?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, Instructions.payload)
    }

    func testClaudeClickDescriptionDropsProposeAction() async throws {
        let claude = MCPServer()
        _ = try await initialize(claude, client: "claude-code")
        let claudeClick = try await tools(claude)["click"]?["description"] as? String
        XCTAssertEqual(claudeClick?.contains("propose_action"), false)
        XCTAssertEqual(claudeClick?.contains("screenshot_scale"), true)

        let codex = MCPServer()
        _ = try await initialize(codex, client: "codex-mcp-client")
        let codexClick = try await tools(codex)["click"]?["description"] as? String
        XCTAssertEqual(codexClick?.hasSuffix("Call `propose_action` first for any state-changing click so the user can confirm the action accurately."), true)
    }

    func testPingReturnsEmptyResult() async throws {
        let result = try await MCPServer().dispatch(method: "ping", params: [:]) as? [String: Any]
        XCTAssertEqual(result?.isEmpty, true)
    }
}
