import Foundation
import Network
import RelayRemoteKit
import RelayRemoteProtocol
import SwiftUI
import XCTest
@testable import RelayRemote

/// A scripted Mac over the kit's `RemoteTransport`: the test delivers frames
/// and reads what the phone sent. The kit's own `FakeMac` lives in its test
/// target, which the app's tests cannot import.
private final class ScriptedConnection: RemoteConnection, @unchecked Sendable {
    let lines: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var sent: [Data] = []

    init() {
        (lines, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
    }

    func send(_ line: Data) { lock.withLock { sent.append(line) } }
    func close() { continuation.finish() }

    func deliver(_ frame: Frame) {
        continuation.yield(try! FrameCodec.encode(frame).dropLast())
    }

    var sentFrames: [Frame] { lock.withLock { sent }.compactMap { try? FrameCodec.decode($0) } }
}

private final class ScriptedTransport: RemoteTransport, @unchecked Sendable {
    let connection = ScriptedConnection()

    func connect(to endpoint: NWEndpoint, credentials: SSHCredentials) async throws -> RemoteConnection {
        connection
    }
}

@MainActor
final class AgentsTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var keychain: KeychainStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString)")
        suite = "com.relayrunner.remote.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        keychain = KeychainStore(service: "com.relayrunner.remote.tests.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        try? keychain.delete("device-key.ed25519")
        try? keychain.delete("device-key.secure-enclave-p256")
    }

    private func model() -> AgentsModel {
        AgentsModel(store: ChatStore(directory: directory), defaults: defaults)
    }

    /// A session welcomed by the scripted Mac, feeding `agents` as the app does.
    private func connect(_ agents: AgentsModel) async throws -> (RemoteSession, ScriptedConnection) {
        let key = try DeviceKeyStore.loadOrCreate(in: keychain)
        let configuration = SessionConfiguration(
            deviceID: "phone-1", deviceName: "iPhone", appVersion: "0.1",
            credentials: SSHCredentials(user: "me", privateKey: key.privateKey,
                                        pinnedHostKeys: ["SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"]))
        let transport = ScriptedTransport()
        let environment = SessionEnvironment(
            now: { 0 }, sleep: { _, _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) },
            random: { $0.upperBound }, wallClock: { 0 })
        let session = RemoteSession(configuration: configuration, transport: transport,
                                    endpoints: StaticEndpoints([.hostPort(host: "192.0.2.1", port: 22)]),
                                    environment: environment, log: .silent)
        agents.session = session
        session.onInbound = { [weak agents] frame in agents?.receive(frame) }
        session.start()
        let connection = transport.connection
        await eventually { connection.sentFrames.contains { if case .hello = $0 { return true } else { return false } } }
        connection.deliver(.welcome(Welcome(sessionState: "running", serverSeq: 0, resumedFrom: nil, dropped: false)))
        await eventually { session.state == .connected }
        return (session, connection)
    }

    private func eventually(timeout: Double = 3, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func speech(_ seq: Int, _ text: String, agent: String? = nil) -> Frame {
        .speech(Speech(seq: seq, kind: .final, source: .orchestrator, text: text, agent: agent))
    }

    // MARK: - Chats

    func testEachAgentHasItsOwnChatAndRepliesAreFiledByAgent() async throws {
        let agents = model()
        agents.select("george")
        let (_, mac) = try await connect(agents)

        XCTAssertTrue(agents.send("Cut a release"))
        let utterance = mac.sentFrames.compactMap { frame -> Utterance? in
            if case .utterance(let utterance) = frame { return utterance } else { return nil }
        }.last
        XCTAssertEqual(utterance?.agent, "george")
        XCTAssertEqual(utterance?.text, "Cut a release")
        XCTAssertEqual(agents.chat("george").map(\.text), ["Cut a release"])

        mac.deliver(speech(1, "Puck here.", agent: "puck"))
        await eventually { !agents.chat("puck").isEmpty }
        XCTAssertEqual(agents.chat("puck").map(\.text), ["Puck here."])
        XCTAssertEqual(agents.chat("george").map(\.text), ["Cut a release"], "Puck's reply stays out of George's chat")
        XCTAssertTrue(agents.marked.contains("puck"), "a reply for another agent marks its tab")
        XCTAssertEqual(agents.agent(ofSeq: 1), "puck")

        // A Mac before RR-534 sends untagged replies: the active agent owns them,
        // or the selected agent when it reports none.
        mac.deliver(speech(2, "Untagged, nobody active."))
        await eventually { agents.chat("george").count == 2 }
        mac.deliver(.sessionState(SessionState(appRunning: true, session: .ready, activeAgent: "sky",
                                               runningAgents: ["sky"])))
        mac.deliver(speech(3, "Untagged, Sky active."))
        await eventually { !agents.chat("sky").isEmpty }
        XCTAssertEqual(agents.chat("sky").map(\.text), ["Untagged, Sky active."])

        mac.deliver(.status(Status(seq: 4, text: "Created RR-531 in relay-runner", agent: "george")))
        await eventually { agents.chat("george").count == 3 }
        XCTAssertEqual(agents.chat("george").last?.role, .status)

        agents.select("puck")
        XCTAssertFalse(agents.marked.contains("puck"), "opening the tab clears its mark")
    }

    func testHistorySurvivesARelaunchCappedAt200PerAgent() {
        let agents = model()
        for seq in 1...230 { agents.receive(speech(seq, "Reply \(seq)", agent: "isabella")) }
        agents.receive(speech(231, "For Sky", agent: "sky"))
        agents.select("isabella")
        XCTAssertEqual(agents.chat("isabella").count, ChatStore.limit)

        let relaunched = model()
        XCTAssertEqual(relaunched.selected, "isabella", "the selected agent persists")
        XCTAssertEqual(relaunched.chat("isabella").count, 200)
        XCTAssertEqual(relaunched.chat("isabella").first?.text, "Reply 31")
        XCTAssertEqual(relaunched.chat("isabella").last?.text, "Reply 230")
        XCTAssertEqual(relaunched.chat("sky").map(\.text), ["For Sky"])
        XCTAssertEqual(relaunched.chat("puck"), [])

        // A replay after the relaunch does not file a reply twice.
        relaunched.receive(speech(230, "Reply 230", agent: "isabella"))
        XCTAssertEqual(relaunched.chat("isabella").count, 200)
        XCTAssertEqual(relaunched.chat("isabella").last?.seq, 230)
    }

    func testAnUnknownSavedSelectionFallsBackToPuck() {
        defaults.set("nobody", forKey: AgentsModel.selectionKey)
        XCTAssertEqual(model().selected, "puck")
        let agents = model()
        agents.select("nobody")
        XCTAssertEqual(agents.selected, "puck")
    }

    // MARK: - State mapping

    func testTabGlyphsFollowTheMacsPerAgentState() async throws {
        let agents = model()
        let (session, mac) = try await connect(agents)
        mac.deliver(.sessionState(SessionState(appRunning: true, session: .ready, activeAgent: "george",
                                               runningAgents: ["isabella", "george", "sky"], agents: [
            AgentStatus(agent: "puck", running: false, state: .off),
            AgentStatus(agent: "isabella", running: false, state: .starting),
            AgentStatus(agent: "george", running: true, state: .ready),
            AgentStatus(agent: "sky", running: true, state: .working),
        ])))
        await eventually { session.agents.count == 4 }
        agents.update(MacSessionStatus(session))
        XCTAssertEqual(AgentsModel.slugs.map { agents.glyph(for: $0, talking: nil, playing: nil) },
                       [.off, .working, .ready, .working])
        XCTAssertTrue(agents.isStopped("puck"))
        XCTAssertFalse(agents.isStopped("isabella"))

        mac.deliver(.sessionState(SessionState(appRunning: true, session: .ready, activeAgent: "george",
                                               runningAgents: ["isabella", "george", "sky"], agents: [
            AgentStatus(agent: "puck", running: false, state: .off),
            AgentStatus(agent: "isabella", running: true, state: .listening),
            AgentStatus(agent: "george", running: true, state: .playing),
            AgentStatus(agent: "sky", running: true, state: .ready),
        ])))
        await eventually { session.agents.first { $0.agent == "george" }?.state == .playing }
        agents.update(MacSessionStatus(session))
        XCTAssertEqual(AgentsModel.slugs.map { agents.glyph(for: $0, talking: nil, playing: nil) },
                       [.off, .listening, .playing, .ready])

        // The phone's own talking and playback win over the Mac's report.
        XCTAssertEqual(agents.glyph(for: "sky", talking: "sky", playing: nil), .listening)
        XCTAssertEqual(agents.glyph(for: "puck", talking: nil, playing: "puck"), .playing)

        // Losing the Mac keeps the last states under the banner.
        session.stop()
        agents.update(MacSessionStatus(connection: .waiting(retryIn: 1), appUnavailable: false, mac: nil, error: nil))
        XCTAssertEqual(agents.reachability, .unreachable)
        XCTAssertEqual(agents.glyph(for: "sky", talking: nil, playing: nil), .ready)
        agents.update(MacSessionStatus(connection: .connecting, appUnavailable: false, mac: nil, error: nil))
        XCTAssertEqual(agents.reachability, .unreachable, "the banner stays while reconnecting")
        agents.update(MacSessionStatus(connection: .idle, appUnavailable: true, mac: nil, error: nil))
        XCTAssertEqual(agents.reachability, .appNotRunning)
    }

    /// The header's work style switch (user, 2026-11-28): it shows the Mac's
    /// style, sends a change, shows the choice at once and settles on the Mac's.
    func testTheWorkStyleSwitchSendsTheChangeAndShowsItAtOnce() async throws {
        let agents = model()
        var clock = Date(timeIntervalSince1970: 1000)
        agents.now = { clock }
        let (session, mac) = try await connect(agents)
        func report(_ georgeStyle: String) async {
            mac.deliver(.sessionState(SessionState(appRunning: true, session: .ready, agents: [
                AgentStatus(agent: "puck", running: true, state: .ready, workStyle: "auto"),
                AgentStatus(agent: "george", running: true, state: .ready, workStyle: georgeStyle),
            ])))
            await eventually { session.agents.first { $0.agent == "george" }?.workStyle == georgeStyle }
            agents.update(MacSessionStatus(session))
        }
        await report("auto")
        XCTAssertEqual(agents.workStyle("george"), "auto")
        XCTAssertNil(agents.workStyle("sky"), "no switch for an agent the Mac gives no style")

        agents.setWorkStyle("direct", for: "george")
        await eventually { mac.sentFrames.contains { if case .settingsCommand = $0 { return true } else { return false } } }
        let set = mac.sentFrames.compactMap { frame -> SettingsCommand? in
            if case .settingsCommand(let command) = frame { return command } else { return nil }
        }
        XCTAssertEqual(set.map(\.agent), ["george"])
        XCTAssertEqual(set.map(\.workStyle), ["direct"])
        XCTAssertEqual(set.first?.action, .set)
        XCTAssertEqual(agents.workStyle("george"), "direct", "the choice shows before the Mac answers")

        await report("auto")
        XCTAssertEqual(agents.workStyle("george"), "direct", "an older report does not undo it")
        await report("direct")
        XCTAssertEqual(agents.workStyle("george"), "direct")

        agents.setWorkStyle("orchestrated", for: "george")
        clock.addTimeInterval(AgentsModel.workStyleWait + 1)
        await report("direct")
        XCTAssertEqual(agents.workStyle("george"), "direct", "a change the Mac never takes falls back to its style")
    }

    func testRunningAgentsFromAMacWithoutPerAgentState() {
        func activity(_ slug: String, _ phase: SessionPhase, running: [String]?, active: String?) -> AgentActivity {
            AgentsModel.activity(of: slug, in: MacSessionStatus(
                connection: .connectedToApp, appUnavailable: false,
                mac: SessionState(appRunning: true, session: phase, activeAgent: active, runningAgents: running),
                error: nil))
        }
        XCTAssertEqual(activity("george", .ready, running: ["puck", "george"], active: "puck"), .ready)
        XCTAssertEqual(activity("sky", .ready, running: ["puck", "george"], active: "puck"), .off)
        XCTAssertEqual(activity("puck", .starting, running: ["puck"], active: "puck"), .starting)
        XCTAssertEqual(activity("puck", .noSession, running: nil, active: nil), .off)
        XCTAssertEqual(activity("sky", .ready, running: nil, active: nil), .ready, "a Mac that names no agents")
    }

    // MARK: - Starting an agent

    func testStartAndMessagingAStoppedAgentStartIt() async throws {
        let agents = model()
        agents.select("puck")
        let (session, mac) = try await connect(agents)
        mac.deliver(.sessionState(SessionState(appRunning: true, session: .ready, activeAgent: "george",
                                               runningAgents: ["george"])))
        await eventually { session.macSession?.runningAgents == ["george"] }
        agents.update(MacSessionStatus(session))
        XCTAssertTrue(AgentsScreenState(agents: agents, voice: VoiceSnapshot(), talkMode: .hold).notRunning)

        agents.start("puck")
        let start = mac.sentFrames.compactMap { frame -> SessionCommand? in
            if case .sessionCommand(let command) = frame, command.action == .start { return command } else { return nil }
        }
        XCTAssertEqual(start.last?.agent, "puck")
        XCTAssertNil(start.last?.projectId, "no project: the Mac's general-tasks project")
        XCTAssertEqual(agents.glyph(for: "puck", talking: nil, playing: nil), .working, "starting spins")
        XCTAssertFalse(agents.isStopped("puck"))

        agents.select("isabella")
        XCTAssertTrue(agents.send("Hi Isabella"))
        let frames = mac.sentFrames
        let startIndex = frames.lastIndex { if case .sessionCommand(let c) = $0 { return c.agent == "isabella" } else { return false } }
        let utteranceIndex = frames.lastIndex { if case .utterance(let u) = $0 { return u.agent == "isabella" } else { return false } }
        XCTAssertNotNil(startIndex, "sending to a stopped agent starts it")
        XCTAssertNotNil(utteranceIndex)
        XCTAssertLessThan(startIndex ?? .max, utteranceIndex ?? .min)

        mac.deliver(.sessionState(SessionState(appRunning: true, session: .ready, activeAgent: "george",
                                               runningAgents: ["puck", "george"])))
        await eventually { session.macSession?.runningAgents == ["puck", "george"] }
        agents.update(MacSessionStatus(session))
        XCTAssertEqual(agents.glyph(for: "puck", talking: nil, playing: nil), .ready, "the dot split into four")
        XCTAssertEqual(agents.glyph(for: "isabella", talking: nil, playing: nil), .working, "still starting")
    }

    // MARK: - Playback and talking

    func testQueueModeShowsTheSelectedAgentsWaitingReplyAndPlaybackMarksItsAgent() {
        let agents = model()
        agents.select("george")
        agents.receive(speech(5, "For Puck", agent: "puck"))
        agents.receive(speech(6, "George one", agent: "george"))
        agents.receive(speech(7, "George two", agent: "george"))

        let waiting = AgentsScreenState(agents: agents, voice: VoiceSnapshot(waitingSeqs: [5, 6, 7]), talkMode: .hold)
        XCTAssertEqual(waiting.waiting?.seq, 7)
        XCTAssertEqual(waiting.waiting?.skipping, [6])
        XCTAssertEqual(waiting.feed.map(\.text), ["George one", "George two"],
                       "every waiting reply shows in the chat as a bubble at once")
        XCTAssertEqual(waiting.orb, .idle)
        let glyphs = Dictionary(uniqueKeysWithValues: waiting.tabs.map { ($0.slug, $0.glyph) })
        XCTAssertEqual(glyphs["puck"], .playing, "an agent with a reply waiting shows the purple glyph, as on the Mac")
        XCTAssertEqual(glyphs["george"], .playing)
        XCTAssertNotEqual(glyphs["isabella"], .playing, "no reply waiting")
        let nothingWaiting = AgentsScreenState(agents: agents, voice: VoiceSnapshot(), talkMode: .hold)
        XCTAssertNotEqual(nothingWaiting.tabs.first { $0.slug == "george" }?.glyph, .playing, "played replies clear it")

        let playingPuck = AgentsScreenState(agents: agents, voice: VoiceSnapshot(playingSeq: 5), talkMode: .hold)
        XCTAssertNil(playingPuck.waiting)
        XCTAssertEqual(playingPuck.tabs.first { $0.slug == "puck" }?.glyph, .playing)
        XCTAssertTrue(playingPuck.tabs.first { $0.slug == "puck" }?.marked == true)
        XCTAssertEqual(playingPuck.orb, .idle, "the header follows only the selected agent")

        let playingGeorge = AgentsScreenState(agents: agents, voice: VoiceSnapshot(playingSeq: 7), talkMode: .hold)
        XCTAssertEqual(playingGeorge.orb, .playing)
        XCTAssertEqual(playingGeorge.speakingSeq, 7)
        XCTAssertEqual(playingGeorge.feed.map(\.text), ["George one", "George two"])

        let talking = AgentsScreenState(agents: agents, voice: VoiceSnapshot(isTalking: true, transcript: "Hi"),
                                        talkMode: .toggle)
        XCTAssertEqual(talking.orb, .listening)
        XCTAssertEqual(talking.tabs.first { $0.slug == "george" }?.glyph, .listening)
        XCTAssertEqual(talking.transcript, "Hi")
    }

    func testAReplyReusingAnOldSeqAfterAMacRestartWaitsAsItself() {
        let agents = model()
        agents.select("george")
        agents.receive(speech(6, "Old George reply", agent: "george"))
        // The Mac restarted and its numbering began again.
        agents.receive(speech(6, "New George reply", agent: "george"))

        let state = AgentsScreenState(agents: agents, voice: VoiceSnapshot(waitingSeqs: [6]), talkMode: .hold)
        XCTAssertEqual(state.feed.map(\.text), ["Old George reply", "New George reply"],
                       "the older reply stays in the chat")
        XCTAssertEqual(state.waiting?.seq, 6)
    }

    func testTheDockReadsPlayForAnUnplayedReplyThenReplay() {
        let agents = model()
        agents.select("george")
        agents.receive(speech(5, "For Puck", agent: "puck"))
        agents.receive(speech(6, "For George", agent: "george"))

        func face(_ voice: VoiceSnapshot) -> AgentDock.ReplayFace {
            let state = AgentsScreenState(agents: agents, voice: voice, talkMode: .hold)
            return AgentDock(text: .constant(""), placeholder: "", isTalking: state.isTalking,
                             canPlay: state.waiting != nil, isPlaying: state.isPlaying,
                             isPreparing: state.isPreparing).replayFace
        }

        XCTAssertEqual(face(VoiceSnapshot(waitingSeqs: [5, 6])), .play, "George's reply has not played")
        XCTAssertEqual(face(VoiceSnapshot(playingSeq: 6, waitingSeqs: [5])), .stop, "while it plays it reads Stop")
        XCTAssertEqual(face(VoiceSnapshot(waitingSeqs: [5])), .replay, "once played it reads Replay")
        XCTAssertEqual(face(VoiceSnapshot(playingSeq: 5)), .stop, "another agent's reply playing reads Stop too")
        XCTAssertEqual(face(VoiceSnapshot(isTalking: true, waitingSeqs: [6])), .cancel, "talking still reads Cancel")
        XCTAssertEqual(face(VoiceSnapshot(waitingSeqs: [5], isPreparing: true)), .preparing,
                       "a pressed Replay reads Preparing until its audio starts")
        XCTAssertEqual(face(VoiceSnapshot(playingSeq: 6, isPreparing: true)), .preparing,
                       "a reply whose audio has not arrived reads Preparing, not Stop")
        XCTAssertEqual(face(VoiceSnapshot(isTalking: true, isPreparing: true)), .cancel, "talking wins")

        agents.select("puck")
        XCTAssertEqual(face(VoiceSnapshot(waitingSeqs: [5])), .play, "Puck's own reply is still unplayed")
        XCTAssertEqual(face(VoiceSnapshot()), .replay, "auto-play leaves nothing waiting")
    }

    func testTheHeaderStatusSaysWhatTheAgentIsDoing() {
        func status(_ glyph: StatusGlyphState, _ workingOn: String? = nil, waiting: Bool = false) -> String {
            AgentsScreenState.status(glyph: glyph, workingOn: workingOn, replyWaiting: waiting)
        }
        XCTAssertEqual(status(.listening, "Replay states"), "Listening", "talking wins")
        XCTAssertEqual(status(.playing, "Replay states"), "Playing reply")
        XCTAssertEqual(status(.working, "Replay states"), "Replay states", "the agent card's work while working")
        XCTAssertEqual(status(.ready, "Replay states"), "Replay states", "and while it waits on the user")
        XCTAssertEqual(status(.working), "Working")
        XCTAssertEqual(status(.ready), "Ready")
        XCTAssertEqual(status(.ready, waiting: true), "New reply")
        XCTAssertEqual(status(.off, "Old work"), "Not running")
    }

    func testAnAgentStartingUpSaysSoUntilItIsReady() {
        let agents = model()
        agents.setSample(activities: ["puck": .starting, "isabella": .ready, "george": .off, "sky": .working],
                         marked: [], reachability: .reachable, chats: [:])
        func status(_ slug: String, _ voice: VoiceSnapshot = VoiceSnapshot()) -> String {
            agents.select(slug)
            return AgentsScreenState(agents: agents, voice: voice, talkMode: .hold).status
        }
        XCTAssertEqual(status("puck"), "Starting up", "a starting agent can't take a message yet")
        XCTAssertEqual(status("puck", VoiceSnapshot(isTalking: true)), "Listening", "talking still wins")
        XCTAssertEqual(status("isabella"), "Ready")
        XCTAssertEqual(status("sky"), "Working", "a turn in progress is not starting up")
        XCTAssertEqual(status("george"), "Not running")

        // Nothing can be sent to it, by text or voice, until it is ready.
        agents.select("puck")
        XCTAssertTrue(AgentsScreenState(agents: agents, voice: VoiceSnapshot(), talkMode: .hold).isStarting)
        XCTAssertFalse(agents.send("Hello?"), "a starting agent takes no message")
        XCTAssertTrue(agents.chat("puck").isEmpty)
        agents.select("isabella")
        XCTAssertFalse(AgentsScreenState(agents: agents, voice: VoiceSnapshot(), talkMode: .hold).isStarting)
    }

    func testAReplayedReplyPlaysWithoutBeingFiledAgain() {
        let agents = model()
        agents.select("george")
        agents.receive(speech(4, "Done, installed.", agent: "george"))
        agents.replayRequested(for: "george")
        agents.receive(speech(5, "Done, installed.", agent: "george"))
        XCTAssertEqual(agents.chat("george").map(\.text), ["Done, installed."])
        XCTAssertEqual(agents.agent(ofSeq: 5), "george", "the replay still plays as George's")
        agents.receive(speech(6, "Done, installed.", agent: "george"))
        XCTAssertEqual(agents.chat("george").count, 2, "only the one replay is folded in")
    }

    func testTheTutorialSpeaksInTheTalkSetting() {
        XCTAssertEqual(TutorialStep.releaseToSend.hero(talkMode: .hold), "Now release to send")
        XCTAssertNotEqual(TutorialStep.releaseToSend.hero(talkMode: .toggle), "Now release to send")
        XCTAssertNotEqual(TutorialStep.holdToTalk.hero(talkMode: .hold), TutorialStep.holdToTalk.hero(talkMode: .toggle))
    }

    func testTalkModes() {
        // Hold: touching starts, letting go sends.
        XCTAssertEqual(TalkGesture.touchDown(mode: .hold, isTalking: false), .start)
        XCTAssertEqual(TalkGesture.touchUp(mode: .hold, isTalking: true), .send)
        XCTAssertEqual(TalkGesture.touchUp(mode: .hold, isTalking: false), .none, "a start that failed sends nothing")
        XCTAssertEqual(TalkGesture.touchDown(mode: .hold, isTalking: true), .none)
        // Toggle: one tap starts, the next sends; touching down does nothing.
        XCTAssertEqual(TalkGesture.touchDown(mode: .toggle, isTalking: false), .none)
        XCTAssertEqual(TalkGesture.touchUp(mode: .toggle, isTalking: false), .start)
        XCTAssertEqual(TalkGesture.touchDown(mode: .toggle, isTalking: true), .none)
        XCTAssertEqual(TalkGesture.touchUp(mode: .toggle, isTalking: true), .send)
        XCTAssertEqual(TalkMode.allCases, [.hold, .toggle], "there is no hands-free mode")
    }

    func testSpokenRequestGoesToTheSelectedAgentsChat() async throws {
        let agents = model()
        agents.select("sky")
        let (session, mac) = try await connect(agents)
        let voice = VoiceController(session: session)
        voice.onSpokenRequest = { agents.send($0) }
        voice.onSpokenRequest?("Hello Sky")
        XCTAssertEqual(agents.chat("sky").map(\.text), ["Hello Sky"])
        XCTAssertTrue(mac.sentFrames.contains { if case .utterance(let u) = $0 { return u.agent == "sky" } else { return false } })
        voice.stop(agents: ["sky"])
        voice.replay(agent: "sky")
        let controls = mac.sentFrames.compactMap { frame -> Control? in
            if case .control(let control) = frame { return control } else { return nil }
        }
        XCTAssertEqual(controls.map(\.action), [.stop, .replay])
        XCTAssertEqual(controls.map(\.agent), ["sky", "sky"])
    }

    func testSampleScreensBuild() {
        for sample in AgentsSample.allCases {
            let state = sample.state
            XCTAssertEqual(state.tabs.map(\.name), ["Puck", "Isabella", "George", "Sky"])
            XCTAssertEqual(state.notRunning, sample == .notRunning)
            XCTAssertEqual(state.reachability == .unreachable, sample == .unreachable)
        }
        XCTAssertEqual(LaunchOptions(arguments: ["--agents-sample=holding"]).agentsSample, "holding")
    }
}
