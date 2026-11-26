import Foundation
import RelayRemoteProtocol
import XCTest
@testable import relay_runner

/// RR-456: the app's session-control handler through injected AppState
/// closures, and the socket it listens on.
@MainActor
final class RelaySessionControlTests: XCTestCase {
    private final class FakeHost {
        var projects = [
            RelaySessionControlHost.Project(id: "p-relay", name: "relay-runner", path: "/repos/relay-runner", availability: "available"),
            RelaySessionControlHost.Project(id: "p-notes", name: "notes", path: "/repos/notes", availability: "available"),
            RelaySessionControlHost.Project(id: "p-gone", name: "old", path: "/repos/old", availability: "missing"),
        ]
        var snapshot = RelaySessionControlHost.Snapshot()
        var started: [String] = []
        var startedAgents: [SessionAgent?] = []
        var stops = 0
        var startResult = true
        var message: String?
        /// What `newSession` does to app state when it accepts a launch.
        var onStart: ((FakeHost, String) -> Void)? = { host, _ in host.snapshot.launching = true }

        var host: RelaySessionControlHost {
            RelaySessionControlHost(
                projects: { self.projects },
                snapshot: { self.snapshot },
                start: { path, agent in
                    self.started.append(path)
                    self.startedAgents.append(agent)
                    if self.startResult { self.onStart?(self, path) }
                    return self.startResult
                },
                stop: {
                    self.stops += 1
                    self.snapshot = .init()
                },
                message: { self.message }
            )
        }
    }

    private var fake: FakeHost!
    private var control: RelaySessionControl!

    override func setUp() async throws {
        fake = FakeHost()
        control = RelaySessionControl(host: fake.host)
    }

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func command(_ action: SessionAction, project: String? = nil, agent: String? = nil,
                         clientID: String = UUID().uuidString) -> Data {
        Data(try! FrameCodec.encode(.sessionCommand(SessionCommand(clientId: clientID, action: action, projectId: project,
                                                                   agent: agent))).dropLast())
    }

    private func state(_ frames: [Frame], file: StaticString = #filePath, line: UInt = #line) -> SessionState? {
        guard frames.count == 1, case .sessionState(let state) = frames[0] else {
            XCTFail("expected one session_state, got \(frames)", file: file, line: line)
            return nil
        }
        return state
    }

    // MARK: Handler

    func testIdentifyReportsNoSessionWithTheRegisteredProjects() throws {
        let reply = try XCTUnwrap(state(control.handle(line: line(["type": "identify", "device_id": "phone-1"]))))
        XCTAssertTrue(reply.appRunning)
        XCTAssertEqual(reply.session, .noSession)
        XCTAssertNil(reply.projectId)
        XCTAssertEqual(reply.projects, [
            ProjectSummary(projectId: "p-relay", displayName: "relay-runner", availability: "available"),
            ProjectSummary(projectId: "p-notes", displayName: "notes", availability: "available"),
            ProjectSummary(projectId: "p-gone", displayName: "old", availability: "missing"),
        ])
    }

    func testHelloIsIgnoredAndPingIsAnswered() {
        let hello = line(["type": "hello", "protocol": 1, "device_id": "phone-1", "device_name": "iPhone", "app_version": "0.1"])
        XCTAssertEqual(control.handle(line: hello), [])
        XCTAssertEqual(control.handle(line: line(["type": "ping", "t": 7])), [.pong(Pong(t: 7))])
        XCTAssertEqual(control.handle(line: Data("not json".utf8)), [])
    }

    func testInvalidCommandIsRejectedWithTheSharedErrorCode() {
        let reply = control.handle(line: line(["type": "session_command", "client_id": "abc", "action": "stop"]))
        XCTAssertEqual(reply, [.error(ErrorFrame(code: "invalid_field", message: "Frame rejected"))])
        XCTAssertEqual(fake.stops, 0)
    }

    func testListProjectsAndStateCommands() throws {
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.listProjects)))).projects?.count, 3)
        let current = try XCTUnwrap(state(control.handle(line: command(.state))))
        XCTAssertEqual(current.session, .noSession)
        XCTAssertNil(current.projects)
    }

    func testStartUsesTheProjectPathAndReportsStartingThenReady() throws {
        let starting = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay"))))
        XCTAssertEqual(fake.started, ["/repos/relay-runner"])
        XCTAssertEqual(starting.session, .starting)
        XCTAssertEqual(starting.projectId, "p-relay")
        XCTAssertEqual(starting.projectName, "relay-runner")

        // The provider is up but the bridge is not consuming yet.
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner")])
        XCTAssertEqual(control.pushIfChanged()?.session, .starting)
        XCTAssertNil(control.pushIfChanged(), "an unchanged state is not pushed again")

        control.bridgeAccepting = true
        let ready = try XCTUnwrap(control.pushIfChanged())
        XCTAssertEqual(ready.session, .ready)
        XCTAssertEqual(ready.projectId, "p-relay")
        XCTAssertNil(ready.error)
    }

    /// RR-523: an older phone build names no agent, so the app picks the
    /// most recently active one; a newer one names it.
    func testAStartWithoutAgentLeavesTheChoiceToTheAppAndANamedOneIsPassedOn() throws {
        _ = control.handle(line: command(.start, project: "p-relay"))
        XCTAssertEqual(fake.startedAgents, [nil])
        fake.snapshot = .init()
        let named = RelaySessionControl(host: fake.host)
        _ = named.handle(line: command(.start, project: "p-relay", agent: "george"))
        XCTAssertEqual(fake.startedAgents, [nil, .george])
        let unknown = try XCTUnwrap(state(RelaySessionControl(host: fake.host)
            .handle(line: command(.start, project: "p-relay", agent: "bob"))))
        XCTAssertEqual(unknown.error, "Unknown agent 'bob'. Choose Puck, Isabella, George or Sky.")
        XCTAssertEqual(fake.startedAgents, [nil, .george], "an unknown agent starts nothing")
    }

    func testANamedAgentStartsBesideTheRunningOnesInItsProject() throws {
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner", agent: .puck)], activeAgent: .puck)
        control.bridgeAccepting = true
        let attach = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay"))))
        XCTAssertNil(attach.error)
        let again = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay", agent: "puck"))))
        XCTAssertNil(again.error)
        XCTAssertEqual(fake.started, [], "an older phone or a running agent only attaches")
        _ = control.handle(line: command(.start, project: "p-relay", agent: "george"))
        XCTAssertEqual(fake.startedAgents, [.george])
        let elsewhere = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-notes", agent: "sky"))))
        XCTAssertEqual(elsewhere.error, "relay-runner is already running on this Mac. Stop it before starting notes.")
        XCTAssertEqual(fake.startedAgents, [.george])
    }

    func testStateReportsTheActiveAndRunningAgents() throws {
        let none = try XCTUnwrap(state(control.handle(line: command(.state))))
        XCTAssertNil(none.activeAgent)
        XCTAssertNil(none.runningAgents)
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner", agent: .sky),
                                     .init(projectID: "p-relay", name: "relay-runner", agent: .puck)],
                              activeAgent: .sky)
        let running = try XCTUnwrap(state(control.handle(line: command(.state))))
        XCTAssertEqual(running.activeAgent, "sky")
        XCTAssertEqual(running.runningAgents, ["puck", "sky"], "table order")
    }

    func testRefusedStartReportsFailedWithTheAppsNewMessage() throws {
        fake.message = "Conversation restored."
        fake.startResult = false
        let generic = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay"))))
        XCTAssertEqual(fake.started, ["/repos/relay-runner"])
        XCTAssertEqual(generic.session, .failed)
        XCTAssertEqual(generic.error, "Relay Runner could not start relay-runner on this Mac.",
                       "a message that was already showing is not the reason")

        var host = fake.host
        host.start = { _, _ in
            self.fake.message = "Session limit reached"
            return false
        }
        let refusing = RelaySessionControl(host: host)
        let reasoned = try XCTUnwrap(state(refusing.handle(line: command(.start, project: "p-notes"))))
        XCTAssertEqual(reasoned.session, .failed)
        XCTAssertEqual(reasoned.projectName, "notes")
        XCTAssertEqual(reasoned.error, "Session limit reached")
    }

    func testALaunchThatEndsBeforeReadyIsReportedFailed() throws {
        _ = control.handle(line: command(.start, project: "p-relay"))
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner")])
        XCTAssertEqual(control.pushIfChanged()?.session, .starting)
        fake.snapshot = .init()
        let failed = try XCTUnwrap(control.pushIfChanged())
        XCTAssertEqual(failed.session, .failed)
        XCTAssertEqual(failed.projectId, "p-relay")
        XCTAssertEqual(failed.error, "The session for relay-runner ended before it was ready.")
        // A reconnecting phone still learns why.
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: line(["type": "identify", "device_id": "p"])))).session, .failed)
    }

    func testStartWhileAnotherProjectRunsIsRefusedWithItsName() throws {
        fake.snapshot = .init(live: [.init(projectID: "p-notes", name: "notes")])
        control.bridgeAccepting = true
        let refused = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay"))))
        XCTAssertEqual(fake.started, [])
        XCTAssertEqual(refused.session, .ready)
        XCTAssertEqual(refused.projectName, "notes")
        XCTAssertEqual(refused.error, "notes is already running on this Mac. Stop it before starting relay-runner.")
    }

    func testStartingTheRunningProjectAgainOnlyReportsIt() throws {
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner")])
        control.bridgeAccepting = true
        let reply = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay"))))
        XCTAssertEqual(fake.started, [])
        XCTAssertEqual(reply.session, .ready)
        XCTAssertNil(reply.error)
    }

    func testStartIsRefusedForUnknownUnavailableOrMissingProjectsAndWhileBusy() throws {
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.start)))).error, "Choose a project to start.")
        let unknown = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-nope"))))
        XCTAssertEqual(unknown.error, "That project is no longer registered on this Mac.")
        XCTAssertEqual(unknown.projects?.count, 3, "the phone gets a fresh list to choose from")
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.start, project: "p-gone")))).error,
                       "old is not available on this Mac.")
        fake.snapshot = .init(launching: true)
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay")))).error,
                       "A session is already starting on this Mac.")
        fake.snapshot = .init(startBlockedReason: "Relay Runner is taking notes on this Mac. Finish the note first.")
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay")))).error,
                       "Relay Runner is taking notes on this Mac. Finish the note first.")
        XCTAssertEqual(fake.started, [])
    }

    /// RR-532: a start without a project uses the built-in general-tasks
    /// project, as the Mac's own Start Session does.
    func testStartWithoutAProjectStartsGeneralTasks() throws {
        fake.projects.append(.init(id: "p-general", name: "general-tasks", path: "/support/general-tasks",
                                   availability: "available"))
        var host = fake.host
        host.generalTasksProjectID = { "p-general" }
        control = RelaySessionControl(host: host)
        let reply = try XCTUnwrap(state(control.handle(line: command(.start, agent: "sky"))))
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.session, .starting)
        XCTAssertEqual(reply.projectName, "general-tasks")
        XCTAssertEqual(fake.started, ["/support/general-tasks"])
        XCTAssertEqual(fake.startedAgents, [.sky])
    }

    private var savedConfigs: [AppConfig] = []
    private var liveConfig = AppConfig()

    private func settingsControl(_ config: AppConfig) -> RelaySessionControl {
        liveConfig = config
        savedConfigs = []
        var host = fake.host
        host.config = { self.liveConfig }
        host.saveConfig = { self.savedConfigs.append($0); self.liveConfig = $0 }
        return RelaySessionControl(host: host)
    }

    private func settingsReply(_ control: RelaySessionControl, _ command: SettingsCommand) throws -> SettingsState {
        let line = Data(try FrameCodec.encode(.settingsCommand(command)).dropLast())
        guard case .settingsState(let state)? = control.handle(line: line).first else {
            XCTFail("expected settings_state"); return SettingsState()
        }
        return state
    }

    /// RR-536: `get` reports the five values and the options the desktop offers, per provider.
    func testSettingsGetMatchesDesktopForClaudeAndCodex() throws {
        for provider in GeneralConfig.AgentProvider.allCases {
            var config = AppConfig()
            config.general.selectProvider(provider)
            let state = try settingsReply(settingsControl(config), SettingsCommand(clientId: UUID().uuidString, action: .get))
            XCTAssertNil(state.error)
            XCTAssertEqual(state.provider, provider.rawValue)
            XCTAssertEqual(state.model, config.general.model)
            XCTAssertEqual(state.effort, config.general.orchestrator_effort)
            XCTAssertEqual(state.speechSpeedPercent, Int((config.tts.rate * 100).rounded()))
            XCTAssertEqual(state.modelOptions?.map(\.value), GeneralConfig.modelOptions(for: provider).map(\.value))
            XCTAssertEqual(state.effortOptions?.map(\.value),
                           GeneralConfig.reasoningEffortOptions(for: provider, model: config.general.model).map(\.value))
            XCTAssertEqual(state.sizingOptions?.map(\.label), GeneralConfig.SubagentSizingPolicy.allCases.map(\.displayName))
        }
    }

    func testSettingsSetSavesSpeedModelEffortAndSizing() throws {
        var config = AppConfig()
        config.general.selectProvider(.claude)
        let control = settingsControl(config)
        var state = try settingsReply(control, SettingsCommand(clientId: UUID().uuidString, action: .set, speechSpeedPercent: 130))
        XCTAssertNil(state.error)
        XCTAssertEqual(liveConfig.tts.rate, 1.3, accuracy: 0.0001)
        XCTAssertEqual(state.speechSpeedPercent, 130)
        let other = try XCTUnwrap(GeneralConfig.modelOptions(for: .claude).map(\.value).first { $0 != liveConfig.general.model })
        state = try settingsReply(control, SettingsCommand(clientId: UUID().uuidString, action: .set, model: other))
        XCTAssertNil(state.error)
        XCTAssertEqual(liveConfig.general.model, other)
        XCTAssertTrue(state.effortOptions?.map(\.value).contains(liveConfig.general.orchestrator_effort) == true,
                      "the effort is corrected for the new model")
        let effort = try XCTUnwrap(state.effortOptions?.last?.value)
        state = try settingsReply(control, SettingsCommand(clientId: UUID().uuidString, action: .set, effort: effort, sizing: "user_default"))
        XCTAssertNil(state.error)
        XCTAssertEqual(liveConfig.general.orchestrator_effort, effort)
        XCTAssertEqual(liveConfig.general.subagent_sizing_policy, .userDefault)
    }

    func testSettingsSetRefusesInvalidValuesAndSavesNothing() throws {
        var config = AppConfig()
        config.general.selectProvider(.claude)
        let control = settingsControl(config)
        let before = liveConfig
        for command in [
            SettingsCommand(clientId: UUID().uuidString, action: .set, speechSpeedPercent: 250),
            SettingsCommand(clientId: UUID().uuidString, action: .set, speechSpeedPercent: 135),
            SettingsCommand(clientId: UUID().uuidString, action: .set, model: "not-a-model"),
            SettingsCommand(clientId: UUID().uuidString, action: .set, effort: "ludicrous"),
            SettingsCommand(clientId: UUID().uuidString, action: .set, sizing: "whatever"),
        ] {
            let state = try settingsReply(control, command)
            XCTAssertNotNil(state.error, "\(command)")
            XCTAssertEqual(state.model, before.general.model)
            XCTAssertEqual(state.speechSpeedPercent, Int((before.tts.rate * 100).rounded()))
        }
        XCTAssertEqual(savedConfigs.count, 0)
        // A key outside the five is refused at decode, so nothing reaches the handler.
        let bad = control.handle(line: Data(#"{"type":"settings_command","client_id":"x","action":"set","provider":"codex"}"#.utf8))
        guard case .settingsState(let refused)? = bad.first else { return XCTFail("expected settings_state") }
        XCTAssertNotNil(refused.error)
        XCTAssertEqual(refused.provider, "claude")
        XCTAssertEqual(liveConfig.general.provider, .claude)
        XCTAssertEqual(savedConfigs.count, 0)
    }

    /// RR-536: a change made on the Mac is pushed once, after the baseline.
    func testSettingsChangeOnTheMacIsPushed() throws {
        let control = settingsControl(AppConfig())
        XCTAssertNil(control.settingsPushIfChanged(), "the first call takes the baseline")
        XCTAssertNil(control.settingsPushIfChanged())
        liveConfig.tts.rate = 0.8
        XCTAssertEqual(control.settingsPushIfChanged()?.speechSpeedPercent, 80)
        XCTAssertNil(control.settingsPushIfChanged())
        _ = try settingsReply(control, SettingsCommand(clientId: UUID().uuidString, action: .set, speechSpeedPercent: 150))
        XCTAssertNil(control.settingsPushIfChanged(), "a phone's own change is not echoed as a push")
    }

    /// RR-532: each new command reaches its own handler and gets one
    /// well-formed reply. RR-535: the Workspace is answered by the socket
    /// server, which needs the daemon, so `handle` validates it and says nothing.
    func testWorkspaceAndSettingsCommandsGetWellFormedReplies() throws {
        let id = UUID().uuidString
        func reply(_ frame: Frame) throws -> [Frame] {
            let replies = control.handle(line: Data(try FrameCodec.encode(frame).dropLast()))
            for each in replies { XCTAssertNoThrow(try FrameCodec.encode(each), "the reply is well formed") }
            return replies
        }
        XCTAssertEqual(try reply(.workspaceCommand(WorkspaceCommand(clientId: id))), [])
        guard case .settingsState(let settings)? = try reply(.settingsCommand(SettingsCommand(clientId: id, action: .get))).first else {
            return XCTFail("a settings_state answers settings_command")
        }
        XCTAssertNil(settings.error)
        XCTAssertEqual(fake.started, [])
        XCTAssertEqual(fake.stops, 0)
        // A malformed command is answered with the codec's error, as session_command is.
        let bad = control.handle(line: Data(#"{"type":"workspace_command","client_id":"abc","action":"list"}"#.utf8))
        XCTAssertEqual(bad, [.error(ErrorFrame(code: "invalid_field", message: "Frame rejected"))])
    }

    /// RR-534: every agent is reported, running or not, and each state the
    /// desktop shows is pushed as it changes, without the phone asking.
    func testAgentsReportEveryAgentThroughItsLifecycle() throws {
        func george(_ pushed: SessionState?, file: StaticString = #filePath, line: UInt = #line) -> AgentStatus? {
            guard let pushed else {
                XCTFail("expected a push", file: file, line: line)
                return nil
            }
            XCTAssertEqual(pushed.agents?.map(\.agent), ["puck", "isabella", "george", "sky"], file: file, line: line)
            return pushed.agents?.first { $0.agent == "george" }
        }
        let off = try XCTUnwrap(state(control.handle(line: command(.state))))
        XCTAssertEqual(off.agents?.map(\.state), [.off, .off, .off, .off])
        XCTAssertEqual(off.agents?.map(\.running), [false, false, false, false])
        _ = control.pushIfChanged()

        fake.snapshot.launching = true
        fake.snapshot.activity.launching = .george
        XCTAssertEqual(george(control.pushIfChanged())?.state, .starting)
        XCTAssertEqual(george(control.state())?.running, false)

        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner", agent: .george, ready: false)],
                              activeAgent: .george)
        control.bridgeAccepting = true
        let live = george(control.pushIfChanged())
        XCTAssertEqual(live?.state, .starting, "its provider is still starting")
        XCTAssertEqual(live?.running, true)

        fake.snapshot.live[0].ready = true
        XCTAssertEqual(george(control.pushIfChanged())?.state, .ready)
        XCTAssertNil(control.pushIfChanged(), "an unchanged state is not pushed again")

        fake.snapshot.activity.working = [.george]
        fake.snapshot.activity.workingOn = [.george: "Relay Remote routing"]
        let working = george(control.pushIfChanged())
        XCTAssertEqual(working?.state, .working)
        XCTAssertEqual(working?.workingOn, "Relay Remote routing")

        fake.snapshot.activity.playing = .george
        XCTAssertEqual(george(control.pushIfChanged())?.state, .playing)
        fake.snapshot.activity = .init()
        let rested = george(control.pushIfChanged())
        XCTAssertEqual(rested?.state, .ready)
        XCTAssertNil(rested?.workingOn)
        XCTAssertEqual(control.state().agents?.filter { $0.agent != "george" }.map(\.state), [.off, .off, .off])
    }

    /// RR-534: a background agent's own turn is reported, while the active
    /// one listens; a stopped agent's description is not shown.
    func testEachAgentReportsItsOwnActivity() throws {
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner", agent: .puck),
                                     .init(projectID: "p-relay", name: "relay-runner", agent: .sky)],
                              activeAgent: .puck,
                              activity: .init(listening: .puck, working: [.sky],
                                              workingOn: [.sky: "Settings review", .george: "Old work"]))
        control.bridgeAccepting = true
        let agents = try XCTUnwrap(control.state().agents)
        XCTAssertEqual(agents.map(\.state), [.listening, .off, .off, .working])
        XCTAssertEqual(agents.map(\.workingOn), [nil, nil, nil, "Settings review"])
    }

    /// RR-534: with a session running, a named agent and no project starts
    /// beside it in the running project, as the Mac's "+" does.
    func testANamedAgentWithoutAProjectStartsBesideTheRunningSession() throws {
        var host = fake.host
        host.generalTasksProjectID = { "p-general" }
        control = RelaySessionControl(host: host)
        fake.snapshot = .init(live: [.init(projectID: "p-notes", name: "notes", agent: .puck)], activeAgent: .puck)
        control.bridgeAccepting = true
        let reply = try XCTUnwrap(state(control.handle(line: command(.start, agent: "isabella"))))
        XCTAssertNil(reply.error)
        XCTAssertEqual(fake.started, ["/repos/notes"])
        XCTAssertEqual(fake.startedAgents, [.isabella])
    }

    /// RR-534: the bridge's request to start an agent for a phone message.
    func testTheBridgesStartRequestNamesAKnownAgent() {
        XCTAssertEqual(RelayRemoteAgents.startRequest(["source": "remote_agent", "state": "start", "agent": "george"]), .george)
        XCTAssertNil(RelayRemoteAgents.startRequest(["source": "remote_agent", "state": "start", "agent": "oberon"]))
        XCTAssertNil(RelayRemoteAgents.startRequest(["source": "remote_device", "state": "start", "agent": "george"]))
    }

    func testStopEndsTheSessionAndReportsNoneAtOnce() throws {
        // endSession() returns before the provider releases its PTY.
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner")])
        var host = fake.host
        host.stop = { self.fake.stops += 1 }
        let control = RelaySessionControl(host: host)
        control.bridgeAccepting = true

        let reply = try XCTUnwrap(state(control.handle(line: command(.stop))))
        XCTAssertEqual(fake.stops, 1)
        XCTAssertEqual(reply.session, .noSession)
        XCTAssertEqual(control.pushIfChanged()?.session, .noSession, "still ending")

        fake.snapshot = .init()
        XCTAssertNil(control.pushIfChanged())
        // A session started later on the Mac is reported again.
        fake.snapshot = .init(live: [.init(projectID: "p-notes", name: "notes")])
        XCTAssertEqual(control.pushIfChanged()?.session, .ready)
    }

    func testStopWithNothingRunningDoesNotCallEndSession() throws {
        XCTAssertEqual(try XCTUnwrap(state(control.handle(line: command(.stop)))).session, .noSession)
        XCTAssertEqual(fake.stops, 0)
    }

    func testARetriedCommandIsNotPerformedTwice() throws {
        let id = UUID().uuidString
        _ = control.handle(line: command(.start, project: "p-relay", clientID: id))
        let retry = try XCTUnwrap(state(control.handle(line: command(.start, project: "p-relay", clientID: id))))
        XCTAssertEqual(fake.started.count, 1)
        XCTAssertEqual(retry.session, .starting)
        XCTAssertNil(retry.error, "the retry is not refused as a second start")
    }

    // MARK: Socket

    func testSocketIsOwnerOnlyAnswersIdentifyAndPushesReadyFromTheBridgeProbe() async throws {
        let directory = "/tmp/rsc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/c.sock"
        let bridgePath = directory + "/b.sock"
        let server = RelaySessionControlServer(control: control, path: path, bridgePath: bridgePath, tickInterval: 0.05)
        try server.start()
        defer { server.stop() }
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)

        let client = try SocketClient(path: path)
        client.send(#"{"device_id":"phone-1","type":"identify"}"#)
        let first = try await client.frame()
        guard case .sessionState(let none) = first else { return XCTFail("expected session_state, got \(first)") }
        XCTAssertEqual(none.session, .noSession)
        XCTAssertEqual(none.projects?.map(\.projectId), ["p-relay", "p-notes", "p-gone"])

        // Pushes of the unchanged `none` state may arrive before the reply.
        client.send(String(decoding: command(.start, project: "p-relay"), as: UTF8.self))
        while try await client.sessionPhase() != .starting {}
        XCTAssertEqual(fake.started, ["/repos/relay-runner"])

        // The provider comes up, then the bridge starts consuming.
        fake.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner")])
        let bridge = try FakeBridge(path: bridgePath)
        defer { bridge.close() }
        while try await client.sessionPhase() != .ready {}
        XCTAssertGreaterThanOrEqual(bridge.probes, 1)
    }

    /// RR-535: a `workspace_command` is answered from the feed, then the phone is
    /// pushed a fresh `workspace_state` when the board changes, once for a burst.
    func testWorkspaceCommandIsAnsweredThenPushedWhenTheBoardChanges() async throws {
        let board = WorkspaceBoard(tickets: [("RR-1", "First", "backlog")])
        let directory = "/tmp/rsw-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let feed = RelayRemoteWorkspaceFeed(
            projects: { self.fake.projects }, fetchDashboard: { _ in board.snapshot }, fetchOwners: { [:] })
        let server = RelaySessionControlServer(
            control: control, workspace: feed, path: directory + "/c.sock", bridgePath: directory + "/b.sock",
            tickInterval: 0.05, workspaceInterval: 0.3)
        try server.start()
        defer { server.stop() }

        let client = try SocketClient(path: directory + "/c.sock")
        client.send(#"{"device_id":"phone-1","type":"identify"}"#)
        client.send(String(decoding: Data(try FrameCodec.encode(.workspaceCommand(WorkspaceCommand(clientId: UUID().uuidString))).dropLast()),
                           as: UTF8.self))
        let first = try await client.workspaceState()
        XCTAssertEqual(first.tickets.map(\.id), ["RR-1"])
        XCTAssertEqual(first.projects.map(\.id), ["p-relay", "p-notes", "p-gone"])
        XCTAssertNil(first.error)

        // Nothing changed: nothing is pushed.
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(try client.pendingWorkspaceStates(), 0)

        // A burst of changes inside one interval is one push.
        board.tickets = [("RR-1", "First", "in_progress")]
        board.tickets.append(("RR-2", "Second", "ready"))
        board.tickets.append(("RR-3", "Third", "backlog"))
        let pushed = try await client.workspaceState()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: pushed.tickets.map { ($0.id, $0.status) }),
                       ["RR-1": .inProgress, "RR-2": .queued, "RR-3": .backlog])
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(try client.pendingWorkspaceStates(), 0)
    }

    /// RR-551: `get` is answered with that one ticket and does not subscribe the
    /// phone to board pushes; one with no ids is a well-formed error.
    func testGetIsAnsweredWithTheTicketAndSubscribesToNothing() async throws {
        let board = WorkspaceBoard(tickets: [("RR-1", "First", "backlog")])
        let directory = "/tmp/rsg-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let feed = RelayRemoteWorkspaceFeed(
            projects: { self.fake.projects }, fetchDashboard: { _ in board.snapshot }, fetchOwners: { [:] },
            loadTicket: { item in
                let ticket = Ticket(id: "RR-1", title: "First", status: .backlog, priority: .medium, dependsOn: [],
                                    runId: nil, canceled: false, order: 1, description: nil, body: "\nThe body.\n")
                return ProgramTicketDetail(item: item, identity: nil, ticket: ticket, ticketPath: nil, description: nil,
                                           acceptanceCriteria: nil, imageAttachments: [], unavailableMessage: nil)
            })
        let server = RelaySessionControlServer(
            control: control, workspace: feed, path: directory + "/c.sock", bridgePath: directory + "/b.sock",
            tickInterval: 0.05, workspaceInterval: 0.1)
        try server.start()
        defer { server.stop() }
        let client = try SocketClient(path: directory + "/c.sock")
        client.send(#"{"device_id":"phone-1","type":"identify"}"#)
        func line(_ command: WorkspaceCommand) throws -> String {
            String(decoding: Data(try FrameCodec.encode(.workspaceCommand(command)).dropLast()), as: UTF8.self)
        }
        client.send(try line(WorkspaceCommand(clientId: UUID().uuidString, action: .get, projectId: "p-relay",
                                              ticketId: "RR-1")))
        let reply = try await client.workspaceTicket()
        XCTAssertEqual(reply.ticketId, "RR-1")
        XCTAssertEqual(reply.title, "First")
        XCTAssertEqual(reply.status, .backlog)
        XCTAssertEqual(reply.markdown, "\nThe body.\n")
        XCTAssertNil(reply.error)
        // A body is never pushed: no board change reaches a phone that only asked for a ticket.
        board.tickets = [("RR-1", "First", "in_progress")]
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(try client.pendingWorkspaceStates(), 0)

        client.send(try line(WorkspaceCommand(clientId: UUID().uuidString, action: .get)))
        let bad = try await client.workspaceTicket()
        XCTAssertEqual(bad.error, RelayRemoteWorkspaceFeed.unidentifiedTicket)
        XCTAssertNil(bad.markdown)
    }

    /// RR-535: with the daemon unreachable the reply is a well-formed error, and quickly.
    func testWorkspaceCommandWithTheDaemonDownAnswersWithAnError() async throws {
        let directory = "/tmp/rsx-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var feed = RelayRemoteWorkspaceFeed(
            projects: { self.fake.projects },
            fetchDashboard: { _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw URLError(.cannotConnectToHost)
            },
            fetchOwners: { [:] })
        feed.timeout = 0.3
        let server = RelaySessionControlServer(
            control: control, workspace: feed, path: directory + "/c.sock", bridgePath: directory + "/b.sock",
            tickInterval: 0.05)
        try server.start()
        defer { server.stop() }
        let client = try SocketClient(path: directory + "/c.sock")
        client.send(#"{"device_id":"phone-1","type":"identify"}"#)
        client.send(String(decoding: Data(try FrameCodec.encode(.workspaceCommand(WorkspaceCommand(clientId: UUID().uuidString))).dropLast()),
                           as: UTF8.self))
        let state = try await client.workspaceState()
        XCTAssertEqual(state.error, RelayRemoteWorkspaceFeed.timedOut)
        XCTAssertEqual(state.tickets, [])
        XCTAssertEqual(state.projects.count, 3, "the project list still shows")
    }

    func testBridgeProbeNeedsARunningBridge() throws {
        let directory = "/tmp/rsb-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        XCTAssertFalse(RelaySessionControlServer.bridgeAccepting(at: directory + "/none.sock"))
        let idle = try FakeBridge(path: directory + "/idle.sock", text: "idle")
        defer { idle.close() }
        XCTAssertFalse(RelaySessionControlServer.bridgeAccepting(at: directory + "/idle.sock"))
        let running = try FakeBridge(path: directory + "/run.sock")
        defer { running.close() }
        XCTAssertTrue(RelaySessionControlServer.bridgeAccepting(at: directory + "/run.sock"))
        XCTAssertEqual(running.identifies.first, #"{"command":"status","device_id":"relay-runner-app","type":"identify"}"#)
    }
}

/// A connected Unix stream socket with a line reader.
private final class SocketClient {
    private let fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    deinit { close(fd) }

    func send(_ line: String) {
        let data = Data((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    /// The next `workspace_state`, skipping the session_state pushes around it.
    @MainActor
    func workspaceState() async throws -> WorkspaceState {
        while true {
            if case .workspaceState(let state) = try await frame() { return state }
        }
    }

    /// The next `workspace_ticket`, skipping the session_state pushes around it.
    @MainActor
    func workspaceTicket() async throws -> WorkspaceTicketDetail {
        while true {
            if case .workspaceTicket(let ticket) = try await frame() { return ticket }
        }
    }

    /// `workspace_state` frames already waiting on the socket.
    @MainActor
    func pendingWorkspaceStates() throws -> Int {
        var count = 0
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            if case .workspaceState = try FrameCodec.decode(line) { count += 1 }
        }
        return count
    }

    @MainActor
    func sessionPhase() async throws -> SessionPhase? {
        guard case .sessionState(let state) = try await frame() else { return nil }
        return state.session
    }

    /// The next frame, polling so the main actor keeps serving the server's hops.
    @MainActor
    func frame(timeout: Double = 5) async throws -> Frame {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                return try FrameCodec.decode(line)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 { throw POSIXError(.ECONNRESET) }
            guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Answers the helper's `status` identify like services/relay_remote.py.
private final class FakeBridge: @unchecked Sendable {
    private let listenFD: Int32
    private let path: String
    private let lock = NSLock()
    private var lines: [String] = []

    var probes: Int { lock.withLock { lines.count } }
    var identifies: [String] { lock.withLock { lines } }

    init(path: String, text: String = "running") throws {
        self.path = path
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(listenFD, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let conn = accept(fd, nil, nil)
                guard conn >= 0 else { return }
                var bytes: [UInt8] = []
                var b: UInt8 = 0
                while read(conn, &b, 1) == 1, b != 0x0A { bytes.append(b) }
                self?.lock.withLock { self?.lines.append(String(decoding: bytes, as: UTF8.self)) }
                let reply = Data(#"{"seq":0,"text":"\#(text)","type":"status"}"#.utf8 + [0x0A])
                _ = reply.withUnsafeBytes { write(conn, $0.baseAddress, reply.count) }
                Darwin.close(conn)
            }
        }
    }

    func close() {
        shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        unlink(path)
    }
}
