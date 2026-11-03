import XCTest
@testable import relay_desktop_mcp

final class DesktopMCPTests: XCTestCase {
    private func initialize(_ server: MCPServer, client: String) async throws -> [String: Any] {
        let result = try await server.dispatch(
            method: "initialize",
            params: ["clientInfo": ["name": client, "version": "1"]]
        )
        return try XCTUnwrap(result as? [String: Any])
    }

    private func argv(_ tool: DesktopTool, _ arguments: [String: Any]) throws -> [String] {
        try tool.build(arguments)
    }

    // MARK: - Protocol surface

    func testClaudeCodeGetsCompactInstructionsAndOthersGetFullRules() async throws {
        let claude = MCPServer()
        let claudeResult = try await initialize(claude, client: "claude-code")
        let compact = try XCTUnwrap(claudeResult["instructions"] as? String)
        XCTAssertEqual(compact, Instructions.claudeCompact)
        XCTAssertLessThanOrEqual(compact.utf16.count, 2048)
        XCTAssertTrue(compact.contains("mcp__relay-desktop__get_relay_instructions"))
        XCTAssertTrue(compact.contains("`snapshot`"))
        XCTAssertTrue(compact.contains("mcp__relay-vision__screenshot"))

        let codex = MCPServer()
        let codexResult = try await initialize(codex, client: "codex-mcp-client")
        let full = try XCTUnwrap(codexResult["instructions"] as? String)
        XCTAssertEqual(full, Instructions.payload)
        XCTAssertTrue(full.contains("## Relay Desktop"))
        XCTAssertTrue(full.contains("mcp__computer-use__*"))
        XCTAssertEqual((codexResult["serverInfo"] as? [String: Any])?["name"] as? String, "relay-desktop")
    }

    func testToolsListCoversTheObserveActVerifyLoop() async throws {
        let server = MCPServer()
        let list = try await server.dispatch(method: "tools/list", params: [:]) as? [String: Any]
        let tools = try XCTUnwrap(list?["tools"] as? [[String: Any]])
        XCTAssertEqual(
            tools.compactMap { $0["name"] as? String },
            ["act", "find", "focus_window", "get", "get_relay_instructions", "launch", "list_apps", "list_windows", "press", "snapshot", "status", "wait"]
        )
        for tool in tools {
            XCTAssertNotNil(tool["description"] as? String)
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        }
    }

    func testGetRelayInstructionsReturnsFullRulesWithoutTouchingTheApp() async throws {
        let result = try await MCPServer().dispatch(
            method: "tools/call",
            params: ["name": "get_relay_instructions", "arguments": [:]]
        ) as? [String: Any]
        let content = try XCTUnwrap(result?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, Instructions.payload)
        XCTAssertEqual(result?["isError"] as? Bool, false)
    }

    func testPingReturnsEmptyResult() async throws {
        let result = try await MCPServer().dispatch(method: "ping", params: [:]) as? [String: Any]
        XCTAssertEqual(result?.isEmpty, true)
    }

    // MARK: - argv building

    func testSnapshotDefaultsToInteractiveCompactTree() throws {
        XCTAssertEqual(try argv(DesktopTools.snapshot, [:]), ["snapshot", "-i", "--compact"])
        XCTAssertEqual(
            try argv(DesktopTools.snapshot, [
                "app": "Finder", "window_id": "w-12", "root": "@s1:e3", "surface": "menu",
                "skeleton": true, "interactive_only": false, "compact": false,
                "max_depth": 4, "include_bounds": true, "timeout_ms": 9000,
            ]),
            ["snapshot", "--app", "Finder", "--window-id", "w-12", "--root", "@s1:e3", "--surface", "menu",
             "--skeleton", "--max-depth", "4", "--include-bounds", "--timeout-ms", "9000"]
        )
    }

    func testFindMapsSelectorsAndLimits() throws {
        XCTAssertEqual(
            try argv(DesktopTools.find, ["app": "Notes", "role": "button", "name": "Save", "exact": true, "first": true, "limit": 0]),
            ["find", "--app", "Notes", "--role", "button", "--name", "Save", "--exact", "--first", "--limit", "0"]
        )
        XCTAssertEqual(try argv(DesktopTools.find, ["text": "", "root": "@s1:e2"]), ["find", "--root", "@s1:e2"])
    }

    func testActBuildsRefActions() throws {
        XCTAssertEqual(try argv(DesktopTools.act, ["action": "click", "ref": "@s1:e8"]), ["click", "@s1:e8"])
        XCTAssertEqual(try argv(DesktopTools.act, ["action": "type", "ref": "@s1:e8", "text": "hello"]), ["type", "@s1:e8", "hello"])
        XCTAssertEqual(try argv(DesktopTools.act, ["action": "select", "ref": "@s1:e8", "text": "Large"]), ["select", "@s1:e8", "Large"])
        XCTAssertEqual(
            try argv(DesktopTools.act, ["action": "scroll", "ref": "@s1:e8", "direction": "up", "amount": 5]),
            ["scroll", "@s1:e8", "--direction", "up", "--amount", "5"]
        )
        XCTAssertEqual(
            try argv(DesktopTools.act, ["action": "click", "ref": "@s1:e8", "wait_for": "button:Done", "wait_timeout_ms": 4000, "timeout_ms": 2000]),
            ["click", "@s1:e8", "--timeout-ms", "2000", "--wait-for", "button:Done", "--wait-timeout", "4000"]
        )
        // Scroll flags never leak onto other actions.
        XCTAssertEqual(try argv(DesktopTools.act, ["action": "toggle", "ref": "@s1:e8", "direction": "up"]), ["toggle", "@s1:e8"])
    }

    func testActRejectsMissingTextUnknownActionsAndBareRefs() {
        XCTAssertThrowsError(try argv(DesktopTools.act, ["action": "type", "ref": "@s1:e8"]))
        XCTAssertThrowsError(try argv(DesktopTools.act, ["action": "double-click", "ref": "@s1:e8"]))
        XCTAssertThrowsError(try argv(DesktopTools.act, ["action": "click", "ref": "e8"]))
        XCTAssertThrowsError(try argv(DesktopTools.act, ["ref": "@s1:e8"]))
    }

    func testPressGetWaitLaunchAndWindowTools() throws {
        XCTAssertEqual(try argv(DesktopTools.press, ["combo": "cmd+s", "app": "Notes"]), ["press", "cmd+s", "--app", "Notes"])
        XCTAssertThrowsError(try argv(DesktopTools.press, [:]))

        XCTAssertEqual(try argv(DesktopTools.get, ["ref": "@s1:e2"]), ["get", "@s1:e2", "--property", "text"])
        XCTAssertEqual(try argv(DesktopTools.get, ["ref": "@s1:e2", "property": "checked"]), ["is", "@s1:e2", "--property", "checked"])
        XCTAssertThrowsError(try argv(DesktopTools.get, ["ref": "@s1:e2", "property": "colour"]))

        XCTAssertEqual(try argv(DesktopTools.wait, ["ms": 500]), ["wait", "500"])
        XCTAssertEqual(
            try argv(DesktopTools.wait, ["app": "Notes", "text": "Saved", "timeout_ms": 5000, "menu_closed": true]),
            ["wait", "--app", "Notes", "--text", "Saved", "--menu-closed", "--timeout", "5000"]
        )

        XCTAssertEqual(try argv(DesktopTools.launch, ["app": "Notes", "activate": true]), ["launch", "Notes", "--activate"])
        XCTAssertThrowsError(try argv(DesktopTools.launch, [:]))

        XCTAssertEqual(try argv(DesktopTools.focusWindow, ["title": "Downloads"]), ["focus-window", "--title", "Downloads"])
        XCTAssertThrowsError(try argv(DesktopTools.focusWindow, [:]))

        XCTAssertEqual(try argv(DesktopTools.listApps, [:]), ["list-apps"])
        XCTAssertEqual(try argv(DesktopTools.listWindows, ["app": "Safari"]), ["list-windows", "--app", "Safari"])
        XCTAssertEqual(try argv(DesktopTools.status, [:]), ["status"])
    }

    func testHostTimeoutGrowsWithRequestedWaits() {
        XCTAssertEqual(DesktopTools.act.timeoutSeconds(["action": "click", "ref": "@s1:e1"]), 60)
        XCTAssertEqual(DesktopTools.act.timeoutSeconds(["action": "click", "ref": "@s1:e1", "wait_for": "button:Done", "wait_timeout_ms": 90_000]), 105)
        XCTAssertEqual(DesktopTools.wait.timeoutSeconds(["ms": 1000]), 60)
        XCTAssertEqual(DesktopTools.wait.timeoutSeconds(["text": "Done", "timeout_ms": 120_000]), 135)
        XCTAssertEqual(DesktopTools.launch.timeoutSeconds(["app": "Notes", "timeout_ms": 60_000]), 75)
    }

    func testOversizedRequestsAreRefusedBeforeReachingTheApp() {
        let text = String(repeating: "x", count: DesktopTool.maxArgvBytes + 1)
        XCTAssertThrowsError(try DesktopTool.forward(tool: "act", argv: ["type", "@s1:e1", text], timeoutSeconds: 60)) { error in
            XCTAssertTrue((error as? MCPToolError)?.message.contains("KB") == true)
        }
    }
}
