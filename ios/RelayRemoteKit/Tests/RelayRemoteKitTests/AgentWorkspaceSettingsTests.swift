import RelayRemoteProtocol
import XCTest
@testable import RelayRemoteKit

/// RR-532: the client API the iPhone tickets build on: sending to a named
/// agent, agent-tagged frames from the Mac, per-agent state, the Workspace
/// feed, and reading and changing the Mac's settings, against a scripted Mac.
@MainActor
final class AgentWorkspaceSettingsTests: XCTestCase {
    private func connected(_ mac: FakeMac, sessionRunning: Bool = true) async -> (RemoteSession, FakeTransport) {
        mac.sessionRunning = sessionRunning
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: TestClock())
        session.start()
        let expected: RemoteSession.State = sessionRunning ? .connected : .connectedToApp
        await eventually { session.state == expected }
        return (session, transport)
    }

    func testUtterancesAndControlsGoToTheNamedAgent() async throws {
        let mac = FakeMac()
        let (session, _) = await connected(mac)
        XCTAssertTrue(session.send(text: "what is George doing", agent: "george"))
        XCTAssertTrue(session.send(text: "and the focused one?"))
        await eventually { mac.commands.count == 2 }
        XCTAssertEqual(mac.commands.map(\.agent), ["george", nil])
        XCTAssertTrue(session.send(control: .stop, agent: "isabella"))
        XCTAssertTrue(session.send(control: .replay))
        await eventually { mac.controls.count == 2 }
        XCTAssertEqual(mac.controls.map(\.agent), ["isabella", nil])
        session.stop()
    }

    func testAPendingUtteranceKeepsItsAgentWhenResent() async throws {
        let mac = FakeMac()
        mac.acceptsUtterances = false
        let (session, _) = await connected(mac)
        XCTAssertTrue(session.send(text: "hold on", agent: "sky"))
        await eventually { mac.utteranceFrames.count == 1 }
        mac.acceptsUtterances = true
        mac.dropConnection()
        await eventually { mac.commands.count == 1 }
        XCTAssertEqual(mac.utteranceFrames.map(\.agent), ["sky", "sky"])
        XCTAssertEqual(mac.utteranceFrames[0].clientId, mac.utteranceFrames[1].clientId)
        session.stop()
    }

    func testReceivedFramesExposeTheirAgent() async throws {
        let mac = FakeMac()
        let (session, _) = await connected(mac)
        var heard: [(String, String?)] = []
        session.onInbound = { frame in
            if case .speech(let speech) = frame { heard.append((speech.text, frame.agent)) }
        }
        mac.speak("George here.", agent: "george")
        mac.speak("Focused agent here.")
        await eventually { heard.count == 2 }
        XCTAssertEqual(heard.map(\.0), ["George here.", "Focused agent here."])
        XCTAssertEqual(heard.map(\.1), ["george", nil])
        XCTAssertEqual(session.records.last { $0.direction == .received && $0.frame.agent != nil }?.frame.agent, "george")
        session.stop()
    }

    func testPerAgentStateIsPublishedAndUpdated() async throws {
        let mac = FakeMac()
        mac.agents = [AgentStatus(agent: "puck", running: true, state: .ready),
                      AgentStatus(agent: "isabella", running: false, state: .off)]
        let (session, _) = await connected(mac)
        // After welcome the phone asks for the state, which carries the agents.
        await eventually { session.agents.count == 2 }
        XCTAssertEqual(MacSessionStatus(session).agent("puck")?.state, .ready)
        XCTAssertEqual(MacSessionStatus(session).agent("isabella")?.running, false)

        mac.agents = [AgentStatus(agent: "puck", running: true, state: .working, workingOn: "RR-120 review"),
                      AgentStatus(agent: "isabella", running: true, state: .starting)]
        mac.pushSessionState()
        await eventually { session.agents.first?.state == .working }
        XCTAssertEqual(MacSessionStatus(session).agents.map(\.state), [.working, .starting])
        XCTAssertEqual(session.agents.first?.workingOn, "RR-120 review")
        session.stop()
        XCTAssertEqual(MacSessionStatus(session).agents, [], "nothing is reported while the Mac is not reached")
    }

    func testAnOlderMacReportsNoAgentState() async throws {
        let mac = FakeMac()
        let (session, _) = await connected(mac)
        await eventually { session.macSession != nil }
        XCTAssertEqual(session.agents, [])
        XCTAssertEqual(MacSessionStatus(session).agents, [])
        session.stop()
    }

    func testWorkspaceListRoundTrip() async throws {
        for sessionRunning in [true, false] {
            let mac = FakeMac()
            mac.workspace = WorkspaceState(
                projects: [WorkspaceProject(id: "p-relay", name: "relay-runner")],
                tickets: [WorkspaceTicket(id: "RR-120", title: "Board", status: .inProgress, projectId: "p-relay",
                                          agent: "puck"),
                          WorkspaceTicket(id: "RR-121", title: "Next", status: .backlog, projectId: "p-relay")])
            let (session, transport) = await connected(mac, sessionRunning: sessionRunning)
            XCTAssertNil(session.workspace)
            XCTAssertTrue(session.requestWorkspace())
            await eventually { session.workspace != nil }
            XCTAssertEqual(mac.workspaceCommands.map(\.action), [.list])
            XCTAssertEqual(session.workspace, mac.workspace)
            XCTAssertTrue(transport.lastConnection?.sentFrames.contains {
                if case .workspaceCommand = $0 { true } else { false }
            } == true)
            session.stop()
            XCTAssertFalse(session.requestWorkspace(), "nothing to send it to")
            XCTAssertEqual(session.workspace, mac.workspace, "the last list is kept")
        }
    }

    /// RR-551: `get` carries the ids, the reply is kept by ticket until it is
    /// forgotten, and a Mac that rejects the action is reported as one that
    /// predates ticket text.
    func testTicketTextRoundTripAndAnOlderMac() async throws {
        let mac = FakeMac()
        mac.ticketReply = { command in
            WorkspaceTicketDetail(projectId: command.projectId ?? "", ticketId: command.ticketId ?? "", title: "Board",
                                  status: .inProgress, agent: "puck", markdown: "## Hello\n")
        }
        let (session, _) = await connected(mac)
        XCTAssertTrue(session.requestWorkspaceTicket(projectID: "p-relay", ticketID: "RR-120"))
        await eventually { !session.workspaceTickets.isEmpty }
        XCTAssertEqual(mac.workspaceCommands.map(\.action), [.get])
        XCTAssertEqual(mac.workspaceCommands.first?.projectId, "p-relay")
        XCTAssertEqual(mac.workspaceCommands.first?.ticketId, "RR-120")
        let key = SessionCore.ticketKey(projectID: "p-relay", ticketID: "RR-120")
        XCTAssertEqual(session.workspaceTickets[key]?.markdown, "## Hello\n")
        XCTAssertFalse(session.ticketUnsupported)
        XCTAssertNil(session.workspace, "a ticket reply is not a list")
        session.forgetWorkspaceTicket(projectID: "p-relay", ticketID: "RR-120")
        XCTAssertTrue(session.workspaceTickets.isEmpty)

        mac.ticketReply = nil
        XCTAssertTrue(session.requestWorkspaceTicket(projectID: "p-relay", ticketID: "RR-120"))
        await eventually { session.ticketUnsupported }
        XCTAssertTrue(session.workspaceTickets.isEmpty)
        mac.ticketReply = { WorkspaceTicketDetail(projectId: $0.projectId ?? "", ticketId: $0.ticketId ?? "", markdown: "x") }
        XCTAssertTrue(session.requestWorkspaceTicket(projectID: "p-relay", ticketID: "RR-120"))
        await eventually { !session.workspaceTickets.isEmpty }
        XCTAssertFalse(session.ticketUnsupported, "a Mac that answers clears it")
        session.stop()
        XCTAssertFalse(session.requestWorkspaceTicket(projectID: "p-relay", ticketID: "RR-120"), "nothing to send it to")
    }

    func testSettingsGetSetAndARefusedSet() async throws {
        let mac = FakeMac()
        var current = SettingsState(
            speechSpeedPercent: 130, provider: "claude", model: "opus", effort: "medium",
            sizing: "orchestrator_decides",
            modelOptions: [SettingOption(value: "opus", label: "Opus"), SettingOption(value: "sonnet", label: "Sonnet")],
            effortOptions: [SettingOption(value: "medium", label: "Medium"), SettingOption(value: "high", label: "High")],
            sizingOptions: [SettingOption(value: "orchestrator_decides", label: "Orchestrator decides"),
                            SettingOption(value: "user_default", label: "Use my defaults")])
        mac.settingsReply = { command in
            guard command.action == .set else { return current }
            if let effort = command.effort, current.effortOptions?.contains(where: { $0.value == effort }) != true {
                var refused = current
                refused.error = "Effort '\(effort)' is not available for Opus."
                return refused
            }
            if let model = command.model { current.model = model }
            if let effort = command.effort { current.effort = effort }
            if let speed = command.speechSpeedPercent { current.speechSpeedPercent = speed }
            return current
        }
        let (session, _) = await connected(mac)

        XCTAssertTrue(session.requestSettings())
        await eventually { session.settings != nil }
        XCTAssertEqual(session.settings?.model, "opus")
        XCTAssertEqual(session.settings?.modelOptions?.map(\.value), ["opus", "sonnet"])
        XCTAssertNil(session.settingsError)

        XCTAssertTrue(session.updateSettings(speechSpeedPercent: 150, model: "sonnet"))
        await eventually { session.settings?.model == "sonnet" }
        XCTAssertEqual(session.settings?.speechSpeedPercent, 150)
        XCTAssertEqual(mac.settingsCommands.last,
                       SettingsCommand(clientId: mac.settingsCommands.last!.clientId, action: .set,
                                       speechSpeedPercent: 150, model: "sonnet"), "only the changed keys are sent")

        XCTAssertTrue(session.updateSettings(effort: "ultra"))
        await eventually { session.settingsError != nil }
        XCTAssertEqual(session.settingsError, "Effort 'ultra' is not available for Opus.")
        XCTAssertEqual(session.settings?.effort, "medium", "a refused set leaves the values unchanged")
        XCTAssertEqual(session.settings?.model, "sonnet")

        // The next command clears the reason; its answer replaces it.
        XCTAssertTrue(session.requestSettings())
        XCTAssertNil(session.settingsError)
        await eventually { mac.settingsCommands.count == 4 }
        session.stop()
        XCTAssertFalse(session.updateSettings(model: "opus"), "a change never lands later")
    }

    func testAMacThatCannotServeSettingsAnswersWithOnlyAnError() async throws {
        let mac = FakeMac()
        mac.settingsReply = { _ in SettingsState(error: "Settings cannot be changed from the phone on this Mac yet.") }
        let (session, _) = await connected(mac, sessionRunning: false)
        XCTAssertTrue(session.requestSettings())
        await eventually { session.settingsError != nil }
        XCTAssertNil(session.settings?.model)
        session.stop()
    }
}
