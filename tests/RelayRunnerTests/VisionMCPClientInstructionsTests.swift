import XCTest
@testable import relay_vision_mcp

final class VisionMCPClientInstructionsTests: XCTestCase {
    // Digests of the release before Claude-specific payloads (3be285a2),
    // taken from a non-Claude client. They must not change for Codex.
    private let releasedInitializeSHA256 = "867d1c37c293d8c6132beb8da575f3e9899444f68860c3c51db9599195134508"
    private let releasedToolsListSHA256 = "eb33067cf837a3c7e069c1e318308f3e5df908b643511f73074b47a47ed5b36e"

    /// The tools list as it was released with `screenshot` alone, so the digest above still
    /// guards that tool's descriptor now that `record` sits beside it.
    private func screenshotOnly(_ list: Any) throws -> [String: Any] {
        let tools = try XCTUnwrap((list as? [String: Any])?["tools"] as? [[String: Any]])
        return ["tools": tools.filter { $0["name"] as? String == "screenshot" }]
    }

    private func tool(named name: String, in list: Any) throws -> [String: Any] {
        let tools = try XCTUnwrap((list as? [String: Any])?["tools"] as? [[String: Any]])
        return try XCTUnwrap(tools.first { $0["name"] as? String == name })
    }

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
            XCTAssertEqual(try mcpCanonicalJSONSHA256(try screenshotOnly(list)), releasedToolsListSHA256, client)
            let record = try tool(named: "record", in: list)
            XCTAssertNil(record["claudeDescription"])
            XCTAssertEqual(
                ((record["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?.keys.sorted(),
                ["display_index", "duration_seconds", "fps", "output_path"]
            )
        }
    }

    func testClaudeCodeGetsLookAtScreenInstruction() async throws {
        let server = MCPServer()
        let result = try await initialize(server, client: "claude-code")
        let instructions = try XCTUnwrap(result["instructions"] as? String)
        XCTAssertEqual(instructions, Instructions.claudeCompact)
        XCTAssertLessThanOrEqual(instructions.utf16.count, 2048)
        XCTAssertTrue(instructions.contains("mcp__relay-vision__screenshot"))
        XCTAssertTrue(instructions.contains("mcp__relay-vision__record"))
        // Claude's screenshot description states the downscale and its scale.
        let list = try await server.dispatch(method: "tools/list", params: [:])
        let screenshot = try tool(named: "screenshot", in: list)
        let description = try XCTUnwrap(screenshot["description"] as? String)
        XCTAssertTrue(description.contains("2000 px"))
        XCTAssertTrue(description.contains("screenshot_scale"))
        XCTAssertNotEqual(try mcpCanonicalJSONSHA256(try screenshotOnly(list)), releasedToolsListSHA256)
        // The record tool describes its ceilings and that it returns a path, not the video.
        let record = try XCTUnwrap(try tool(named: "record", in: list)["description"] as? String)
        XCTAssertTrue(record.contains("mp4"))
        XCTAssertTrue(record.contains("capped at 30"))
        XCTAssertTrue(record.contains("not returned inline"))
    }

    func testPingReturnsEmptyResult() async throws {
        let result = try await MCPServer().dispatch(method: "ping", params: [:]) as? [String: Any]
        XCTAssertEqual(result?.isEmpty, true)
    }
}
