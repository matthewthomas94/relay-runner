import XCTest
@testable import relay_runner

/// RR-519: the four fixed, named agents that replace numbered PM tabs.
final class SessionAgentTests: XCTestCase {
    private let general = AssistantSessionContext(kind: .project, projectID: "built-in", repositoryPath: "/general-tasks")

    func testTheFourAgentsAreDefinedOnceInTableOrder() {
        XCTAssertEqual(SessionAgent.allCases.map(\.name), ["Puck", "Isabella", "George", "Sky"])
        XCTAssertEqual(SessionAgent.allCases.map(\.slug), ["puck", "isabella", "george", "sky"])
        XCTAssertEqual(SessionAgent.allCases.map(\.voiceID), ["am_puck", "bf_isabella", "bm_george", "af_sky"])
        XCTAssertEqual(SessionAgent.allCases.map(\.order), [1, 2, 3, 4])
    }

    /// RR-520: relay-speech's agent-to-voice map is pinned to this table by
    /// the same fixture (`agents::tests::the_map_matches_the_swift_agent_table`).
    func testTheSharedFixturePinsEachAgentsVoice() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/session_agent_voices.json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let agents = try XCTUnwrap(fixture["agents"] as? [[String: String]])
        XCTAssertEqual(agents.map { $0["slug"] }, SessionAgent.allCases.map(\.slug))
        XCTAssertEqual(agents.map { $0["voice"] }, SessionAgent.allCases.map(\.voiceID))
    }

    func testEachAgentHasAStableTabAndPuckOwnsTheFirstTab() {
        XCTAssertEqual(SessionAgent.allCases.map(\.tab), [nil, "isabella", "george", "sky"])
        XCTAssertEqual(general.inTab(SessionAgent.puck.tab).id, "project:built-in", "Today's first-tab conversation is Puck's")
        XCTAssertEqual(general.inTab(SessionAgent.sky.tab).id, "project:built-in#tab-sky")
        for agent in SessionAgent.allCases {
            let context = general.inTab(agent.tab)
            XCTAssertEqual(SessionAgent(tab: agent.tab), agent)
            XCTAssertEqual(SessionAgent(contextID: context.id), agent)
            XCTAssertEqual(SessionAgent(context: context), agent)
        }
        XCTAssertNil(SessionAgent(tab: "a1b2c3d4"), "A pre-agent random tab belongs to no agent")
        XCTAssertNil(SessionAgent(tab: "puck"), "Puck's tab is nil, never its slug")
        XCTAssertNil(SessionAgent(contextID: "project:built-in#tab-a1b2c3d4"))
        XCTAssertEqual(SessionAgent(context: general.inTab("a1b2c3d4")), .puck)
    }

    /// Item 6's interim rules until the wheel and start-menu tickets land.
    func testAddStartsTheFirstAgentNotRunningAndOtherStartsTheMostRecentlyActive() {
        XCTAssertEqual(SessionAgent.toAdd(running: []), .puck)
        XCTAssertEqual(SessionAgent.toAdd(running: [.puck]), .isabella)
        XCTAssertEqual(SessionAgent.toAdd(running: [.puck, .george]), .isabella)
        XCTAssertEqual(SessionAgent.toAdd(running: [.isabella]), .puck)
        XCTAssertEqual(SessionAgent.toAdd(running: [.puck, .isabella, .george]), .sky)
        XCTAssertNil(SessionAgent.toAdd(running: Set(SessionAgent.allCases)), "All four run: Add is refused")

        XCTAssertEqual(SessionAgent.toStart(activeContext: .general), .puck, "None has run: Puck")
        XCTAssertEqual(SessionAgent.toStart(activeContext: general), .puck)
        XCTAssertEqual(SessionAgent.toStart(activeContext: general.inTab("george")), .george)
        let project = AssistantSessionContext(kind: .project, projectID: "relay", repositoryPath: "/repos/relay")
        XCTAssertEqual(SessionAgent.toStart(activeContext: project.inTab("isabella")), .isabella)
    }

    func testStartPathsFollowTheInterimRules() throws {
        let source = try appStateSource()
        // Add controls ("+", Command-T) use the Add rule.
        let open = try body(source, "    func openPMTab(agent: SessionAgent? = nil, showsTerminal: Bool = true) -> Bool {")
        XCTAssertTrue(open.contains("guard let agent = agent ?? agentToAdd else {"))
        XCTAssertTrue(source.contains("SessionAgent.toAdd(running: runningAgents)"))
        let shortcut = try String(contentsOf: root.appendingPathComponent("Sources/relay-runner/Board/PMTabShortcut.swift"), encoding: .utf8)
        XCTAssertTrue(shortcut.contains("case .openTab:\n            openPMTab()"))
        // Every other start names no agent, so it starts the most recently active one.
        XCTAssertTrue(source.contains("programBoardOverlay.setStartSessionHandler { [weak self] in self?.newSession() }"))
        // RR-521: the wheel starts the agent the user picked, never the top segment.
        let wheel = try body(source, "    private func performAgentWheelAction(_ action: SessionWheelAgentAction) -> Bool {")
        XCTAssertTrue(wheel.contains("? openPMTab(agent: agent, showsTerminal: false)"))
        XCTAssertTrue(wheel.contains(": newSession(showsWorkspaceOnLaunch: false, agent: agent)"))
        XCTAssertFalse(source.contains("sessionWheel.startSession"))
        XCTAssertTrue(source.contains("self?.newSession(workingDirectory: path, showsWorkspaceOnLaunch: false) ?? false"),
                      "Relay Remote and start_session")
        let note = try body(source, "    private func transitionFromNoteToSession(")
        XCTAssertTrue(note.contains("agent: agent"), "The Notetaker hand-off keeps the start's agent")
    }

    func testNothingDeletesAnAgentsConversation() throws {
        let source = try appStateSource()
        let store = try String(contentsOf: root.appendingPathComponent("Sources/relay-runner/Process/AssistantSessionStore.swift"), encoding: .utf8)
        XCTAssertFalse(store.contains("func removeTab("))
        XCTAssertFalse(source.contains("removeTab("))
        let stop = try body(source, "    func stopPMTab(_ contextID: String) {")
        XCTAssertTrue(stop.contains("endSession(context: context)"))
        XCTAssertFalse(stop.contains("try assistantSessionStore."), "Stop keeps the binding")
        XCTAssertFalse(stop.contains("try? assistantSessionStore."), "Stop keeps the binding")
        let clear = try body(source, "    private func clearPMTabs() {")
        XCTAssertFalse(clear.contains("assistantSessionStore."), "End Session keeps every binding and the active agent")
        let reset = try body(source, "    private func resetActiveSessionState() {")
        XCTAssertTrue(reset.contains("clearPMTabs()"))
        XCTAssertFalse(reset.contains("assistantSessionStore."))
    }

    func testStatusListsEveryAgentWithRunningAndActiveState() {
        let statuses = SessionAgent.statuses(
            liveContextIDs: ["project:built-in", "project:built-in#tab-george", "project:relay#tab-sky"],
            activeContextID: "project:built-in#tab-george")
        XCTAssertEqual(statuses.map(\.agent), SessionAgent.allCases)
        XCTAssertEqual(statuses.map(\.isRunning), [true, false, true, true])
        XCTAssertEqual(statuses.map(\.isActive), [false, false, true, false])
        let json = statuses[2].json
        XCTAssertEqual(json["name"] as? String, "George")
        XCTAssertEqual(json["slug"] as? String, "george")
        XCTAssertEqual(json["running"] as? Bool, true)
        XCTAssertEqual(json["active"] as? Bool, true)
        XCTAssertEqual(SessionAgent.statuses(liveContextIDs: [], activeContextID: "project:built-in").map(\.isActive),
                       [false, false, false, false], "A stopped active context is not an active agent")
    }

    func testALaunchedSessionPublishesItsAgentInTheEnvironmentAndSpool() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rr-agent-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for agent in SessionAgent.allCases {
            let spool = VoiceSessionSpool(key: "transport-\(agent.slug)", rootDirectory: root.path)
            try spool.prepare()
            try spool.writeSessionAgent(agent)
            XCTAssertEqual(spool.sessionAgent, spool.directory + "/session_agent")
            XCTAssertEqual(try String(contentsOfFile: spool.sessionAgent, encoding: .utf8), agent.slug + "\n")

            let context = general.inTab(agent.tab)
            for target in [ProcessManager.AgentTarget.codex, .claude] {
                var config = AppConfig()
                config.general.provider = target == .codex ? .codex : .claude
                let script = ProcessManager.launchScript(
                    relayBridge: "/App/scripts/relay-bridge", target: target, agentBinary: "/agent", config: config,
                    voiceDelivery: .appOwned, resolvedCodexModel: "gpt-6.1-sol", sessionContext: context, spool: spool)
                XCTAssertTrue(script.contains("export RELAY_SESSION_AGENT='\(agent.slug)'"), "\(target) \(agent.name)")
                let key = try XCTUnwrap(script.range(of: "export RELAY_SESSION_KEY="))
                let exported = try XCTUnwrap(script.range(of: "export RELAY_SESSION_AGENT="))
                let exec = try XCTUnwrap(script.range(of: "\nexec "))
                XCTAssertTrue(key.lowerBound < exported.lowerBound && exported.lowerBound < exec.lowerBound)
                // The environment line, run as the launcher runs it, sets the slug.
                XCTAssertEqual(try shell(ProcessManager.sessionAgentEnvironment(context) + "; printf %s \"$RELAY_SESSION_AGENT\""), agent.slug)
            }
        }
        XCTAssertEqual(ProcessManager.sessionAgentEnvironment(nil), "unset RELAY_SESSION_AGENT")
        let legacyFile = VoiceSessionSpool.legacy.sessionAgent
        let legacyExisted = FileManager.default.fileExists(atPath: legacyFile)
        try VoiceSessionSpool.legacy.writeSessionAgent(.puck)
        if !legacyExisted { XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile), "A shared legacy spool gets no file") }
        // The spool file is written before the launcher, so before the provider starts.
        let manager = try String(contentsOf: self.root.appendingPathComponent("Sources/relay-runner/Process/ProcessManager.swift"), encoding: .utf8)
        let prepare = try XCTUnwrap(manager.range(of: "        try spool.prepare()\n        if let sessionContext { try spool.writeSessionAgent(SessionAgent(context: sessionContext)) }"))
        let write = try XCTUnwrap(manager.range(of: "try script.write(toFile: launcher"))
        XCTAssertLessThan(prepare.lowerBound, write.lowerBound)
        // Codex filters MCP child environments; its servers get the agent too.
        XCTAssertTrue(ProcessManager.appOwnedMCPEnvironmentFlag(target: .codex, voiceDelivery: .appOwned).contains("RELAY_SESSION_AGENT"))
    }

    func testStartupInstructionsNameTheAgentForBothProviders() {
        for agent in SessionAgent.allCases {
            for target in [ProcessManager.AgentTarget.codex, .claude] {
                var config = AppConfig()
                config.general.provider = target == .codex ? .codex : .claude
                let script = ProcessManager.launchScript(
                    relayBridge: "/App/scripts/relay-bridge", target: target, agentBinary: "/agent", config: config,
                    voiceDelivery: .appOwned, resolvedCodexModel: "gpt-6.1-sol", sessionContext: general.inTab(agent.tab),
                    spool: VoiceSessionSpool(key: "transport"))
                let launch = script.components(separatedBy: "\nexec ").last ?? ""
                XCTAssertTrue(launch.contains("You are \(agent.name) in this session; the user may address you by that name."),
                              "\(target) \(agent.name)")
                XCTAssertTrue(launch.contains(target == .codex ? "developer_instructions=" : "--append-system-prompt"))
            }
        }
    }

    func testNoTabIsNumbered() throws {
        for path in ["Sources/relay-runner/App/AppState.swift", "Sources/relay-runner/Board/SessionWheelModel.swift",
                     "Sources/relay-runner/Terminal/WorkspaceTerminalSurface.swift",
                     "Sources/relay-runner/Terminal/EmbeddedSessionRegistry.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("\"Session \\("), path)
            XCTAssertFalse(source.contains("\"S\\("), path)
            XCTAssertNil(source.range(of: "nine", options: .caseInsensitive), path)
        }
    }

    // MARK: Helpers

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func appStateSource() throws -> String {
        try String(contentsOf: root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"), encoding: .utf8)
    }

    private func body(_ source: String, _ signature: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), signature)
        return String(source[start.lowerBound...]).components(separatedBy: "\n    }\n")[0]
    }

    private func shell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.environment = [:]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
