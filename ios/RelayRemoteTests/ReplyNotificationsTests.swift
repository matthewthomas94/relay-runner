import Foundation
import RelayRemoteKit
import RelayRemoteProtocol
import XCTest
@testable import RelayRemote

@MainActor
private final class FakeNotificationCenter: LocalNotificationCenter {
    var authorized = true
    var posted: [LocalNotification] = []
    var removedThreads: [String] = []
    var removedIDs: [String] = []

    func isAuthorized() async -> Bool { authorized }
    func post(_ notification: LocalNotification) { posted.append(notification) }
    func removeDelivered(threadID: String) { removedThreads.append(threadID) }
    func removeDelivered(ids: [String]) { removedIDs += ids }
}

/// RR-545: reply notifications in the background, with the notification
/// centre and the audio session faked.
@MainActor
final class ReplyNotificationsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var center: FakeNotificationCenter!
    /// Every hold (true) and release (false) the notifier asked of the audio session.
    private var holds: [Bool] = []
    private var audioHolds = true

    override func setUp() async throws {
        suite = "com.relayrunner.remote.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        center = FakeNotificationCenter()
        holds = []
        audioHolds = true
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func notifier(preferenceOn: Bool = true, authorized: Bool = true) async -> ReplyNotifier {
        let preference = ReplyNotificationsPreference(defaults: defaults)
        preference.isOn = preferenceOn
        center.authorized = authorized
        let notifier = ReplyNotifier(center: center, preference: preference)
        notifier.holdAudio = { [unowned self] on in
            holds.append(on)
            return on && audioHolds
        }
        await notifier.refreshAuthorization()
        return notifier
    }

    private func speech(_ seq: Int, _ kind: SpeechKind, _ text: String, command: Int? = 7,
                        agent: String? = "george") -> Speech {
        Speech(seq: seq, kind: kind, source: kind == .handoff ? .messenger : .orchestrator, text: text,
               relayCommandSeq: command, agent: agent)
    }

    // MARK: - Assembly

    func testSeveralSpeechFramesOfOneReplyMakeOneNotice() {
        var assembler = ReplyNotificationAssembler()
        XCTAssertEqual(assembler.receive(speech(1, .handoff, "Looking at RR-120 now."), agent: "george"), [])
        XCTAssertEqual(assembler.receive(speech(2, .progress, "  The worker\nstarted. "), agent: "george"), [])
        XCTAssertEqual(assembler.receive(speech(3, .final, "RR-120 is in ready and dispatching."), agent: "george"),
                       [ReplyNotice(agent: "george", seq: 1,
                                    body: "Looking at RR-120 now. The worker started. RR-120 is in ready and dispatching.")])
    }

    func testRepliesAreKeptApartByAgentAndCommand() {
        var assembler = ReplyNotificationAssembler()
        XCTAssertEqual(assembler.receive(speech(1, .handoff, "George on it.", command: 1), agent: "george"), [])
        XCTAssertEqual(assembler.receive(speech(2, .handoff, "Sky on it.", command: 2, agent: "sky"), agent: "sky"), [])
        XCTAssertEqual(assembler.receive(speech(3, .final, "Sky done.", command: 2, agent: "sky"), agent: "sky"),
                       [ReplyNotice(agent: "sky", seq: 2, body: "Sky on it. Sky done.")])
        // George's next command arrives before the first one ended: the first posts as it stands.
        XCTAssertEqual(assembler.receive(speech(4, .clarification, "Which project?", command: 3), agent: "george"),
                       [ReplyNotice(agent: "george", seq: 1, body: "George on it."),
                        ReplyNotice(agent: "george", seq: 4, body: "Which project?")])
    }

    func testFramesWithoutACommandStandAloneAndReplaysAndControlsAreSkipped() {
        var assembler = ReplyNotificationAssembler()
        XCTAssertEqual(assembler.receive(speech(5, .progress, "The worker merged RR-12.", command: nil), agent: "puck"),
                       [ReplyNotice(agent: "puck", seq: 5, body: "The worker merged RR-12.")])
        XCTAssertEqual(assembler.receive(speech(5, .progress, "The worker merged RR-12.", command: nil), agent: "puck"),
                       [], "a frame replayed after a reconnect is not posted twice")
        XCTAssertEqual(assembler.receive(speech(6, .control, "Stopped.", command: nil), agent: "puck"), [])
        XCTAssertEqual(assembler.receive(speech(7, .final, "   ", command: nil), agent: "puck"), [])
    }

    func testLongRepliesAreCutAtAWord() {
        let long = Array(repeating: "word", count: 100).joined(separator: " ")
        let body = ReplyNotificationAssembler.body([long])
        XCTAssertLessThanOrEqual(body.count, ReplyNotificationAssembler.bodyLimit + 1)
        XCTAssertTrue(body.hasSuffix("word…"), body)
        XCTAssertEqual(ReplyNotificationAssembler.body(["Short."]), "Short.")
    }

    // MARK: - Lifecycle decision

    func testKeepAliveNeedsThePreferenceThePermissionAndASession() {
        XCTAssertTrue(ReplyNotifier.keepsAlive(preferenceOn: true, authorized: true, sessionUsable: true))
        XCTAssertFalse(ReplyNotifier.keepsAlive(preferenceOn: false, authorized: true, sessionUsable: true))
        XCTAssertFalse(ReplyNotifier.keepsAlive(preferenceOn: true, authorized: false, sessionUsable: true))
        XCTAssertFalse(ReplyNotifier.keepsAlive(preferenceOn: true, authorized: true, sessionUsable: false))
    }

    func testPreferenceOffOrPermissionDeniedBackgroundsAsBefore() async {
        for (preferenceOn, authorized) in [(false, true), (true, false), (false, false)] {
            holds = []
            let notifier = await notifier(preferenceOn: preferenceOn, authorized: authorized)
            XCTAssertFalse(notifier.enteredBackground(sessionUsable: true))
            XCTAssertEqual(holds, [], "the audio session is not touched")
            notifier.receive(speech(1, .final, "Done."), agent: "george")
            notifier.sessionStateChanged(.failed(.unreachable))
            XCTAssertEqual(center.posted, [])
        }
    }

    func testBackgroundHoldsTheAudioAndOpeningReleasesIt() async {
        let notifier = await notifier()
        XCTAssertTrue(notifier.enteredBackground(sessionUsable: true))
        XCTAssertEqual(holds, [true])
        XCTAssertTrue(notifier.isKeepingAlive)
        notifier.enteredForeground(showing: "george")
        XCTAssertEqual(holds, [true, false])
        XCTAssertFalse(notifier.isKeepingAlive)
    }

    func testAudioThatCannotBeHeldBackgroundsAsBefore() async {
        audioHolds = false
        let notifier = await notifier()
        XCTAssertFalse(notifier.enteredBackground(sessionUsable: true))
        notifier.receive(speech(1, .final, "Done."), agent: "george")
        XCTAssertEqual(center.posted, [])
    }

    // MARK: - Posting

    func testAReplyInTheBackgroundPostsOneNotificationTitledWithTheAgent() async {
        let notifier = await notifier()
        notifier.enteredBackground(sessionUsable: true)
        notifier.receive(speech(1, .handoff, "Checking the build."), agent: "george")
        XCTAssertEqual(center.posted, [], "nothing posts until the reply ends")
        notifier.receive(speech(2, .final, "It passed."), agent: "george")
        XCTAssertEqual(center.posted, [LocalNotification(id: "reply.george.1", title: "George",
                                                         body: "Checking the build. It passed.",
                                                         threadID: "agent.george", agent: "george")])
    }

    func testNoNotificationForAReplyInTheForeground() async {
        let notifier = await notifier()
        notifier.receive(speech(1, .final, "Done."), agent: "george")
        notifier.enteredBackground(sessionUsable: true)
        notifier.enteredForeground(showing: "george")
        notifier.receive(speech(2, .final, "Done again."), agent: "george")
        XCTAssertEqual(center.posted, [])
    }

    func testOpeningClearsTheShownChatsNotificationsAndTheLostNotice() async {
        let notifier = await notifier()
        notifier.enteredBackground(sessionUsable: true)
        notifier.enteredForeground(showing: "sky")
        XCTAssertEqual(center.removedThreads, ["agent.sky"])
        XCTAssertEqual(center.removedIDs, [ReplyNotifier.lostConnectionID])
        notifier.chatOpened("george")
        XCTAssertEqual(center.removedThreads, ["agent.sky", "agent.george"])
    }

    // MARK: - Lost connection

    func testALostConnectionPostsOnceAndReleasesTheAudio() async {
        let notifier = await notifier()
        notifier.enteredBackground(sessionUsable: true)
        for attempt in 1..<ConnectionLossWatch.attemptLimit {
            notifier.sessionStateChanged(.waiting(retryIn: Double(attempt)))
            notifier.sessionStateChanged(.connecting)
        }
        XCTAssertEqual(center.posted, [], "the normal reconnects get their tries")
        notifier.sessionStateChanged(.waiting(retryIn: 30))
        XCTAssertEqual(center.posted.map(\.body), [ReplyNotifier.lostConnectionText])
        XCTAssertEqual(center.posted.first?.agent, nil)
        XCTAssertEqual(holds, [true, false], "the audio session is released")

        for _ in 0..<10 { notifier.sessionStateChanged(.waiting(retryIn: 30)) }
        notifier.sessionStateChanged(.failed(.unreachable))
        XCTAssertEqual(center.posted.count, 1)

        // Opened, then backgrounded again: a new loss may be reported.
        notifier.enteredForeground(showing: "george")
        notifier.enteredBackground(sessionUsable: true)
        notifier.sessionStateChanged(.failed(.hostKeyMismatch))
        XCTAssertEqual(center.posted.count, 2)
    }

    func testAReconnectInTimeIsNotALoss() async {
        let notifier = await notifier()
        notifier.enteredBackground(sessionUsable: true)
        for _ in 0..<(ConnectionLossWatch.attemptLimit - 1) { notifier.sessionStateChanged(.waiting(retryIn: 1)) }
        notifier.sessionStateChanged(.connected)
        for _ in 0..<(ConnectionLossWatch.attemptLimit - 1) { notifier.sessionStateChanged(.waiting(retryIn: 1)) }
        XCTAssertEqual(center.posted, [])
        XCTAssertTrue(notifier.isKeepingAlive)
    }

    func testTheWatchReportsOnlyOnceUntilReplaced() {
        var watch = ConnectionLossWatch()
        XCTAssertTrue(watch.observe(.failed(.authenticationRejected)))
        XCTAssertFalse(watch.observe(.connected))
        for _ in 0..<(ConnectionLossWatch.attemptLimit * 2) { XCTAssertFalse(watch.observe(.waiting(retryIn: 1))) }
    }

    // MARK: - Opening a chat from a notification

    func testOpeningAnAgentChatSelectsItOnTheAgentsTab() {
        let agents = AgentsModel(store: ChatStore(directory: nil), defaults: defaults)
        let model = AppModel(agents: agents, notificationCenter: center)
        model.openAgentChat("sky")
        XCTAssertEqual(agents.selected, "sky")
        XCTAssertEqual(model.agentsTabRequests, 1)
        XCTAssertEqual(center.removedThreads, ["agent.sky"])
        model.openAgentChat("nobody")
        XCTAssertEqual(model.agentsTabRequests, 1)
    }

    func testATapThatArrivesBeforeTheAppIsReadyIsKept() {
        let router = NotificationRouter()
        var opened: [String] = []
        router.open("george")
        router.openAgent = { opened.append($0) }
        XCTAssertEqual(opened, ["george"])
        router.open("sky")
        XCTAssertEqual(opened, ["george", "sky"])
    }
}
