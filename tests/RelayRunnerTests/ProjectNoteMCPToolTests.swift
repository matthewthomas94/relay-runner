import XCTest
@testable import relay_orchestrator_mcp

final class ProjectNoteMCPToolTests: XCTestCase {
    func testCatalogToolIsBoundedReadOnlyProjectDiscovery() throws {
        let tool = ListProjectNotesTool()
        XCTAssertEqual(tool.name, "list_project_notes")
        XCTAssertTrue(tool.description.contains("read-only"))
        XCTAssertTrue(tool.description.contains("does not create tickets"))

        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        let limit = try XCTUnwrap(properties["limit"] as? [String: Any])
        XCTAssertEqual(limit["maximum"] as? Int, 100)
        XCTAssertNotNil(properties["project_scope_token"])
    }

    func testReadToolDocumentsChunkingAndUntrustedContentBoundary() throws {
        let tool = ReadProjectNoteTool()
        XCTAssertEqual(tool.name, "read_project_note")
        XCTAssertTrue(tool.description.contains("bounded character chunks"))
        XCTAssertTrue(tool.description.contains("untrusted source material"))

        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        let limit = try XCTUnwrap(properties["limit"] as? [String: Any])
        XCTAssertEqual(limit["maximum"] as? Int, 32_000)
        XCTAssertEqual(
            Set(tool.inputSchema["required"] as? [String] ?? []),
            Set(["repo_path", "identity"])
        )
    }
}
