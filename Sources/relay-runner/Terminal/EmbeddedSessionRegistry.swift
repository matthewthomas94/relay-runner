import Foundation
import Observation

/// RR-394: one embedded provider session per assistant context.
///
/// `sessions` maps an `AssistantSessionContext.id` to its long-lived
/// `EmbeddedTerminalSession`; `focusedContextID` names the session the
/// Workspace terminal shows (`AppState.embeddedTerminal`). Starting or
/// focusing one context never ends another, and ending a context stops only
/// that session's PTY and spool. Voice focus re-targeting and per-session
/// inbox routing build on these two properties.
@Observable
final class EmbeddedSessionRegistry {
    /// Soft cap on concurrently live sessions.
    static let maxConcurrentSessions = 4

    enum Admission {
        /// The context already has a live session; it is now focused.
        case focusedExisting(EmbeddedTerminalSession)
        /// Launch into this idle or finished session; it is now focused.
        case start(EmbeddedTerminalSession)
        /// The cap is reached; nothing changed.
        case refused(String)
    }

    static var capMessage: String {
        "Relay Runner runs at most \(maxConcurrentSessions) sessions at once. End one before starting another."
    }

    private(set) var sessions: [String: EmbeddedTerminalSession] = [:]
    private(set) var focusedContextID: String?

    /// Stands in while no context is focused, so callers always have a session.
    @ObservationIgnored let placeholder: EmbeddedTerminalSession
    @ObservationIgnored private let makeSession: () -> EmbeddedTerminalSession
    @ObservationIgnored private var spools: [String: VoiceSessionSpool] = [:]
    @ObservationIgnored private var exitHandler: ((String, Int32?) -> Void)?
    @ObservationIgnored private var readyHandler: ((String) -> Void)?

    init(makeSession: @escaping () -> EmbeddedTerminalSession = { EmbeddedTerminalSession() }) {
        self.makeSession = makeSession
        placeholder = makeSession()
    }

    var focused: EmbeddedTerminalSession {
        focusedContextID.flatMap { sessions[$0] } ?? placeholder
    }

    /// A session is live from preparing until its child releases the PTY.
    func isLive(_ contextID: String) -> Bool {
        sessions[contextID].map(Self.isLive) ?? false
    }

    var liveContextIDs: [String] {
        sessions.filter { Self.isLive($0.value) }.map(\.key).sorted()
    }

    var hasLiveSessions: Bool { sessions.values.contains(where: Self.isLive) }

    /// Exit and ready callbacks carry the context id of the session that fired.
    func setHandlers(exit: @escaping (String, Int32?) -> Void, ready: @escaping (String) -> Void) {
        exitHandler = exit
        readyHandler = ready
    }

    func admit(contextID: String) -> Admission {
        if let existing = sessions[contextID], Self.isLive(existing) {
            focus(contextID: contextID)
            return .focusedExisting(existing)
        }
        guard liveContextIDs.count < Self.maxConcurrentSessions else {
            return .refused(Self.capMessage)
        }
        let session = sessions[contextID] ?? makeContextSession(contextID)
        sessions[contextID] = session
        focusedContextID = contextID
        return .start(session)
    }

    /// Select the context the Workspace terminal shows; one without a session
    /// shows `placeholder`. Keyboard focus is left to the caller.
    func focus(contextID: String) {
        focusedContextID = contextID
    }

    /// Record the spool a context's launch uses; a replaced spool is removed.
    func setSpool(_ spool: VoiceSessionSpool, for contextID: String) {
        if let previous = spools[contextID], previous != spool { previous.remove() }
        spools[contextID] = spool
    }

    /// Stop only this context's PTY and remove only its spool.
    func end(contextID: String) {
        sessions[contextID]?.end()
        spools.removeValue(forKey: contextID)?.remove()
    }

    func endAll() {
        for contextID in sessions.keys { end(contextID: contextID) }
    }

    /// App quit or update relaunch: drop every PTY and spool.
    func shutdownAll() {
        for session in sessions.values { session.shutdown() }
        for spool in spools.values { spool.remove() }
        spools = [:]
        sessions = [:]
        focusedContextID = nil
    }

    private func makeContextSession(_ contextID: String) -> EmbeddedTerminalSession {
        let session = makeSession()
        session.setExitHandler { [weak self] exitCode in
            self?.exitHandler?(contextID, exitCode)
        }
        session.setReadyHandler { [weak self] in
            self?.readyHandler?(contextID)
        }
        return session
    }

    private static func isLive(_ session: EmbeddedTerminalSession) -> Bool {
        session.phase.isActive || session.hasLiveEmbeddedProcess
    }
}
