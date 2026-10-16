import XCTest
@testable import relay_actions_mcp

final class ActionsMCPClientInstructionsTests: XCTestCase {
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

    func testNonClaudeClientsReceiveCurrentInstructionsAndBothContextTools() async throws {
        for client in ["codex-mcp-client", "rr-326-probe"] {
            let server = MCPServer()
            let result = try await initialize(server, client: client)
            XCTAssertEqual(result["instructions"] as? String, Instructions.payload, client)
            let byName = try await tools(server)
            XCTAssertEqual(Set(byName.keys), Set(["click", "type", "key", "scroll", "activate_project", "activate_general", "toggle_board", "frontmost_app", "list_windows", "propose_action"]), client)
            XCTAssertEqual(byName["activate_general"]?["inputSchema"] as? NSDictionary, ActivateGeneralTool().inputSchema as NSDictionary)
            XCTAssertEqual(byName["activate_project"]?["description"] as? String, ActivateProjectTool().description)
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
        XCTAssertNotNil(byName["activate_general"])
        XCTAssertNotNil(byName["activate_project"])
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

    func testGeneralSelectionForwardsQueuedResultWithoutClaimingReady() async throws {
        var requested = false
        let message = "General switch queued. Finish the current reply."
        let tool = ActivateGeneralTool(notify: { true }, activate: { _ in requested = true; return .selected(message: message) })
        let content = try await tool.call(arguments: [:])
        XCTAssertTrue(requested)
        XCTAssertEqual(content.first?["text"] as? String, message)
    }

    func testGeneralSelectionRejectsArgumentsAndUnavailableAppWithoutDispatch() async throws {
        var requested = false
        let tool = ActivateGeneralTool(notify: { false }, activate: { _ in requested = true; return .selected(message: "unexpected") })
        let invalidRequests: [[String: Any]] = [[:], ["project": "/repo"]]
        for arguments in invalidRequests {
            do {
                _ = try await tool.call(arguments: arguments)
                XCTFail("Expected General selection to fail")
            } catch { XCTAssertFalse(requested) }
        }
    }

    func testProjectSelectionPassesExactPathAndProviderAndPreservesQueuedStatus() async throws {
        let tool = ActivateProjectTool(notify: { true }, activate: { project, provider, continuation in
            XCTAssertNil(continuation)
            XCTAssertEqual(project, "/registered/project")
            XCTAssertEqual(provider, "claude")
            return .queued(repoPath: project, message: "Project switch queued until this reply finishes.")
        })
        let content = try await tool.call(arguments: ["project": "/registered/project", "provider": "claude"])
        XCTAssertEqual(content.first?["text"] as? String, "Project switch queued until this reply finishes.")
    }
    func testFocusOrBrowseActivationReportsTheAppOutcome() async throws {
        let tool = ActivateProjectTool(notify: { true }, activate: { path, _, _ in
            .activated(repoPath: path, message: "Opened the project board without starting a session; other sessions keep running.")
        })
        let content = try await tool.call(arguments: ["project": "/registered/project"])
        XCTAssertEqual(content.first?["text"] as? String, "Opened the project board without starting a session; other sessions keep running.")
        XCTAssertTrue(ActivateProjectTool().description.contains("The current session is never stopped."))
    }
    func testExplicitContinuationValidatesPublicTextAndDoesNotManufactureNavigationWork() async throws {
        var forwarded: [String?] = []
        let general = ActivateGeneralTool(notify: { true }, activate: { forwarded.append($0); return .selected(message: "queued") })
        _ = try await general.call(arguments: [:])
        _ = try await general.call(arguments: ["continuation": "Finish Y in General"])
        XCTAssertNil(forwarded[0]); XCTAssertEqual(forwarded[1], "Finish Y in General")
        for invalid in ["", "bad\rsubmit", "\u{1b}[2J", "\u{9b}2J"] {
            do { _ = try await general.call(arguments: ["continuation": invalid]); XCTFail("Expected control rejection") }
            catch { XCTAssertTrue((error as? MCPToolError)?.message.contains("continuation") == true) }
        }
        XCTAssertEqual(forwarded.count, 2)
        let project = ActivateProjectTool(notify: { true }, activate: { path, _, text in
            XCTAssertEqual(path, "/confirmed"); XCTAssertEqual(text, "Finish Y in project"); return .queued(repoPath: path, message: "queued")
        })
        _ = try await project.call(arguments: ["project": "/confirmed", "continuation": "Finish Y in project"])
    }

    func testContinuationSourceComesOnlyFromExactInheritedNativeBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("binding.json")
        let environment = ["RELAY_SESSION_BINDING_PATH": path.path, "RELAY_RUNNER_PROVIDER": "claude", "RELAY_PROVIDER_SESSION_ID": "source", "RELAY_APP_SESSION_ID": "app", "RELAY_RECOVERY_GENERATION": "generation", "RELAY_FOREGROUND_GATE_HANDLE": "gate", "RELAY_CONTEXT_ID": "general"]
        try JSONSerialization.data(withJSONObject: ["native_session_id": "native", "provider_session_id": "source", "context_id": "general"]).write(to: path)
        let captured = ConfirmationClient.continuationSource(text: "Y", environment: environment)
        XCTAssertEqual(captured?["text"], "Y"); XCTAssertEqual(captured?["native_session_id"], "native")
        XCTAssertEqual(captured?["app_session_id"], "app")
        var stale = environment; stale["RELAY_PROVIDER_SESSION_ID"] = "foreign"
        XCTAssertNil(ConfirmationClient.continuationSource(text: "Y", environment: stale))
        stale = environment; stale.removeValue(forKey: "RELAY_FOREGROUND_GATE_HANDLE")
        XCTAssertNil(ConfirmationClient.continuationSource(text: "Y", environment: stale))
    }

}
