import XCTest
@testable import relay_vision_mcp

final class VisionMCPClientInstructionsTests: XCTestCase {
    // Digests of the release before Claude-specific payloads (3be285a2),
    // taken from a non-Claude client. They must not change for Codex.
    private let releasedInitializeSHA256 = "867d1c37c293d8c6132beb8da575f3e9899444f68860c3c51db9599195134508"
    private let releasedToolsListSHA256 = "eb33067cf837a3c7e069c1e318308f3e5df908b643511f73074b47a47ed5b36e"

    private func initialize(_ server: MCPServer, client: String) async throws -> [String: Any] {
        let result = try await server.dispatch(
            method: "initialize",
            params: ["clientInfo": ["name": client, "version": "1"]]
        )
        return try XCTUnwrap(result as? [String: Any])
    }

    func testNonClaudeClientsKeepReleasedInitializeAndTools() async throws {
        for client in ["codex-mcp-client", "rr-326-probe"] {
            let server = MCPServer()
            let result = try await initialize(server, client: client)
            XCTAssertNil(result["instructions"])
            XCTAssertEqual(try mcpCanonicalJSONSHA256(result), releasedInitializeSHA256, client)
            let list = try await server.dispatch(method: "tools/list", params: [:])
            XCTAssertEqual(try mcpCanonicalJSONSHA256(list), releasedToolsListSHA256, client)
        }
    }

    func testClaudeCodeGetsLookAtScreenInstruction() async throws {
        let server = MCPServer()
        let result = try await initialize(server, client: "claude-code")
        let instructions = try XCTUnwrap(result["instructions"] as? String)
        XCTAssertEqual(instructions, Instructions.claudeCompact)
        XCTAssertLessThanOrEqual(instructions.utf16.count, 2048)
        XCTAssertTrue(instructions.contains("mcp__relay-vision__screenshot"))
        // Claude's screenshot description states the downscale and its scale.
        let list = try await server.dispatch(method: "tools/list", params: [:]) as? [String: Any]
        let tool = try XCTUnwrap((list?["tools"] as? [[String: Any]])?.first)
        let description = try XCTUnwrap(tool["description"] as? String)
        XCTAssertTrue(description.contains("2000 px"))
        XCTAssertTrue(description.contains("screenshot_scale"))
        XCTAssertNotEqual(try mcpCanonicalJSONSHA256(try XCTUnwrap(list)), releasedToolsListSHA256)
    }

    func testPingReturnsEmptyResult() async throws {
        let result = try await MCPServer().dispatch(method: "ping", params: [:]) as? [String: Any]
        XCTAssertEqual(result?.isEmpty, true)
    }
}
