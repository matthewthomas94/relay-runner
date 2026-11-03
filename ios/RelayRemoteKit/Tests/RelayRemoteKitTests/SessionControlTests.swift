import Network
import RelayRemoteProtocol
import XCTest
@testable import RelayRemoteKit

/// RR-456: listing projects, starting and stopping the Mac's session, and
/// attaching to it once it is ready, against a scripted Mac.
@MainActor
final class SessionControlTests: XCTestCase {
    private func status(_ session: RemoteSession) -> MacSessionStatus { MacSessionStatus(session) }

    func testWithNoSessionTheChannelReachesTheAppAndListsItsProjects() async throws {
        let mac = FakeMac()
        mac.sessionRunning = false
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: TestClock())
        session.start()
        await eventually { session.state == .connectedToApp }

        let shown = status(session)
        XCTAssertEqual(shown.phase, .noSession)
        XCTAssertEqual(shown.projects.map(\.displayName), ["relay-runner", "old"])
        XCTAssertTrue(shown.canStart(chosen: nil))
        XCTAssertEqual(shown.startProject(chosen: "p-old"), "p-relay", "an unavailable project cannot start")
        XCTAssertFalse(shown.canStop)
        XCTAssertTrue(mac.hellos.isEmpty, "the app ignores hello")
        // Liveness still runs on this channel: the app answers the ping.
        await eventually { transport.lastConnection?.sentFrames.contains { if case .ping = $0 { true } else { false } } == true }
        session.stop()
    }

    func testStartAttachesToTheNewSessionWithoutUserActionAndAcceptsATypedRequest() async throws {
        let mac = FakeMac()
        mac.sessionRunning = false
        let clock = TestClock()
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { session.state == .connectedToApp }

        // Typed before the session exists: held until a bridge accepts it.
        XCTAssertTrue(session.send(text: "what is on the board"))
        XCTAssertTrue(session.send(sessionCommand: .start, projectID: "p-relay"))
        await eventually { self.status(session).phase == .starting }
        XCTAssertEqual(status(session).projectName, "relay-runner")
        XCTAssertFalse(status(session).canStart(chosen: nil))
        XCTAssertTrue(status(session).canStop)
        XCTAssertEqual(mac.sessionCommands.map(\.action), [.start])
        XCTAssertEqual(mac.sessionCommands.first?.projectId, "p-relay")
        XCTAssertTrue(mac.utteranceFrames.isEmpty)

        mac.finishStart()
        await eventually { session.state == .connected }
        XCTAssertEqual(clock.delays, [], "attaching skips the backoff")
        XCTAssertEqual(transport.attemptCount, 2)
        XCTAssertEqual(mac.hellos.count, 1, "the second channel reached the bridge")
        await eventually { mac.commands.map(\.text) == ["what is on the board"] && session.pending.isEmpty }

        // After welcome the phone asks which project it is attached to.
        await eventually { mac.sessionCommands.map(\.action) == [.start, .state] }
        XCTAssertEqual(status(session).phase, .ready)
        XCTAssertEqual(status(session).projectName, "relay-runner")
        XCTAssertTrue(session.send(text: "and now?"))
        await eventually { mac.commands.count == 2 }
        session.stop()
    }

    func testReadyOnArrivalReattachesAfterABackoff() async throws {
        let mac = FakeMac()
        mac.sessionRunning = false
        mac.phase = .ready // the helper raced the bridge coming up
        let clock = TestClock()
        clock.holdBackoff = true
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { if case .waiting = session.state { return true } else { return false } }
        XCTAssertEqual(clock.delays, [0.5])
        XCTAssertEqual(transport.attemptCount, 1)
        session.stop()
    }

    func testStopGoesFromTheAttachedSessionToTheApp() async throws {
        let mac = FakeMac()
        let clock = TestClock()
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { session.state == .connected }
        XCTAssertTrue(status(session).canStop)
        XCTAssertTrue(session.send(sessionCommand: .stop))
        await eventually { mac.sessionCommands.map(\.action).contains(.stop) }

        // The bridge goes with the session; the next channel finds only the app.
        mac.sessionRunning = false
        mac.dropConnection()
        await eventually { session.state == .connectedToApp }
        XCTAssertEqual(status(session).phase, .noSession)
        session.stop()
    }

    func testAppNotRunningIsReportedApartFromAnUnreachableMac() async throws {
        let mac = FakeMac()
        mac.appRunning = false
        let clock = TestClock()
        clock.holdBackoff = true
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { if case .waiting = session.state { return true } else { return false } }
        XCTAssertEqual(status(session).phase, .appNotRunning)
        XCTAssertFalse(session.send(sessionCommand: .listProjects), "nothing to send it to")

        // Relay Runner opened on the Mac: the retry reaches it.
        mac.appRunning = true
        mac.sessionRunning = false
        session.retryNow()
        await eventually { session.state == .connectedToApp }
        XCTAssertEqual(status(session).phase, .noSession)
        session.stop()

        let unreachable = Fixtures.session(transport: FakeTransport(mac: nil, outcomes: [.fail(.unreachable)]), clock: clock)
        unreachable.start()
        await eventually { if case .waiting = unreachable.state { return true } else { return false } }
        XCTAssertEqual(status(unreachable).phase, .unreachable)
        unreachable.stop()
    }

    func testFailedStartShowsTheMacsReason() async throws {
        let mac = FakeMac()
        mac.sessionRunning = false
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: TestClock())
        session.start()
        await eventually { session.state == .connectedToApp }
        transport.lastConnection?.deliver(.sessionState(SessionState(
            appRunning: true, session: .failed, projectId: "p-relay", projectName: "relay-runner",
            error: "Relay Runner could not start relay-runner on this Mac.")))
        await eventually { self.status(session).phase == .failed }
        XCTAssertEqual(status(session).error, "Relay Runner could not start relay-runner on this Mac.")
        XCTAssertTrue(status(session).canStart(chosen: "p-relay"), "the user can try again")
        XCTAssertEqual(status(session).projects.count, 2, "the earlier list is kept")
        session.stop()
    }

    // MARK: SessionCore

    func testCoreTracksTheControlLinkAndWhenToReattach() {
        var core = SessionCore(deviceID: "d", deviceName: "n", appVersion: "0.1", resumeAfterSeq: nil)
        _ = core.connectionOpened()
        let none = core.receive(.sessionState(SessionState(appRunning: true, session: .noSession, projects: [
            ProjectSummary(projectId: "p", displayName: "p", availability: "available"),
        ])), now: 0)
        XCTAssertTrue(core.isControlLink)
        XCTAssertTrue(core.isEstablished)
        XCTAssertFalse(core.isWelcomed)
        XCTAssertNil(none.reattach)
        XCTAssertNil(core.receive(.sessionState(SessionState(appRunning: true, session: .starting)), now: 0).reattach)
        XCTAssertEqual(core.receive(.sessionState(SessionState(appRunning: true, session: .ready)), now: 0).reattach, .now)
        XCTAssertEqual(core.macSession?.projects?.count, 1, "a state without projects keeps the list")

        _ = core.connectionOpened()
        XCTAssertFalse(core.isControlLink)
        XCTAssertEqual(core.receive(.sessionState(SessionState(appRunning: true, session: .ready)), now: 0).reattach,
                       .afterBackoff)

        // Beside a bridge the app's answers never reattach.
        _ = core.connectionOpened()
        _ = core.receive(.welcome(Welcome(sessionState: "running", serverSeq: 0, dropped: false)), now: 0)
        XCTAssertNil(core.receive(.sessionState(SessionState(appRunning: true, session: .ready)), now: 0).reattach)
        XCTAssertFalse(core.isControlLink)
    }

    func testCoreKeepsTheReasonUntilTheNextCommandOrAChange() {
        var core = SessionCore(deviceID: "d", deviceName: "n", appVersion: "0.1", resumeAfterSeq: nil)
        _ = core.connectionOpened()
        _ = core.receive(.sessionState(SessionState(appRunning: true, session: .ready, projectName: "notes",
                                                    error: "notes is already running on this Mac.")), now: 0)
        XCTAssertEqual(core.sessionError, "notes is already running on this Mac.")
        _ = core.receive(.sessionState(SessionState(appRunning: true, session: .ready, projectName: "notes")), now: 0)
        XCTAssertEqual(core.sessionError, "notes is already running on this Mac.", "the next push does not erase it")
        _ = core.receive(.sessionState(SessionState(appRunning: true, session: .noSession)), now: 0)
        XCTAssertNil(core.sessionError, "the session changed on its own")
        _ = core.receive(.sessionState(SessionState(appRunning: true, session: .noSession, error: "Choose a project to start.")), now: 0)
        core.sessionCommandSent()
        XCTAssertNil(core.sessionError)
    }

    func testCoreTracksWhetherTheAppIsRunning() {
        var core = SessionCore(deviceID: "d", deviceName: "n", appVersion: "0.1", resumeAfterSeq: nil)
        _ = core.connectionOpened()
        _ = core.receive(.sessionState(SessionState(appRunning: false, session: .noSession)), now: 0)
        XCTAssertTrue(core.appUnavailable)
        XCTAssertFalse(core.isEstablished, "nothing answers on that channel")
        core.connectionClosed()
        XCTAssertTrue(core.appUnavailable, "kept while the phone retries")
        core.connectionFailed()
        XCTAssertFalse(core.appUnavailable, "a transport failure means the Mac was not reached")
        _ = core.connectionOpened()
        _ = core.receive(.sessionState(SessionState(appRunning: false, session: .noSession)), now: 0)
        _ = core.connectionOpened()
        _ = core.receive(.welcome(Welcome(sessionState: "running", serverSeq: 0, dropped: false)), now: 0)
        XCTAssertFalse(core.appUnavailable)
    }

    // MARK: Picker

    func testStatusFollowsTheConnectionAndTheMacsState() {
        let projects = [
            ProjectSummary(projectId: "a", displayName: "a", availability: "offline"),
            ProjectSummary(projectId: "b", displayName: "b", availability: "available"),
        ]
        func shown(_ connection: RemoteSession.State, _ phase: SessionPhase?, appUnavailable: Bool = false) -> MacSessionStatus {
            MacSessionStatus(connection: connection, appUnavailable: appUnavailable,
                             mac: phase.map { SessionState(appRunning: !appUnavailable, session: $0, projectName: "b", projects: projects) },
                             error: nil)
        }
        XCTAssertEqual(shown(.idle, nil).phase, .unreachable)
        XCTAssertEqual(shown(.waiting(retryIn: 1), nil).phase, .unreachable)
        XCTAssertEqual(shown(.failed(.hostKeyMismatch), .ready).phase, .unreachable)
        XCTAssertEqual(shown(.connecting, nil).phase, .connecting)
        XCTAssertEqual(shown(.waiting(retryIn: 1), .noSession, appUnavailable: true).phase, .appNotRunning)
        XCTAssertEqual(shown(.connecting, .noSession, appUnavailable: true).phase, .appNotRunning)
        XCTAssertEqual(shown(.connectedToApp, .noSession).phase, .noSession)
        XCTAssertNil(shown(.connectedToApp, .noSession).projectName)
        XCTAssertEqual(shown(.connectedToApp, .starting).phase, .starting)
        XCTAssertEqual(shown(.connectedToApp, .ready).phase, .ready)
        XCTAssertEqual(shown(.connectedToApp, .failed).phase, .failed)
        XCTAssertEqual(shown(.connected, nil).phase, .ready, "attached without the app's answer yet")
        XCTAssertNil(shown(.connected, nil).projectName)
        XCTAssertEqual(shown(.connected, .ready).projectName, "b")

        XCTAssertTrue(shown(.connectedToApp, .noSession).canStart(chosen: nil))
        XCTAssertTrue(shown(.connectedToApp, .failed).canStart(chosen: nil))
        XCTAssertFalse(shown(.connectedToApp, .starting).canStart(chosen: nil))
        XCTAssertFalse(shown(.connected, .ready).canStart(chosen: nil))
        XCTAssertFalse(shown(.waiting(retryIn: 1), .noSession).canStart(chosen: nil))
        XCTAssertEqual(shown(.connectedToApp, .noSession).startProject(chosen: "a"), "b")
        XCTAssertEqual(shown(.connectedToApp, .noSession).startProject(chosen: nil), "b")
        XCTAssertTrue(shown(.connectedToApp, .starting).canStop)
        XCTAssertTrue(shown(.connected, nil).canStop)
        XCTAssertFalse(shown(.connectedToApp, .noSession).canStop)

        let empty = MacSessionStatus(connection: .connectedToApp, appUnavailable: false,
                                     mac: SessionState(appRunning: true, session: .noSession, projects: []), error: nil)
        XCTAssertFalse(empty.canStart(chosen: nil), "nothing to start")
    }
}
