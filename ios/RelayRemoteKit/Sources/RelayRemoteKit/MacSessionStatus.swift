import RelayRemoteProtocol

/// What the phone's session controls show (RR-456): the project picker, Start
/// and Stop, derived from the channel and the Mac's latest `session_state`.
public struct MacSessionStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// SSH did not get through: asleep, offline or Remote Login off.
        case unreachable
        case connecting
        /// The Mac answered, but Relay Runner is not running there.
        case appNotRunning
        case noSession
        case starting
        /// Attached to the session's voice bridge, or about to attach.
        case ready
        case failed
    }

    public let phase: Phase
    public let projectName: String?
    /// Why the last command was refused or the session failed.
    public let error: String?
    /// The Mac's registered projects, kept from the last list it sent.
    public let projects: [ProjectSummary]

    public init(connection: RemoteSession.State, appUnavailable: Bool, mac: SessionState?, error: String?) {
        projects = mac?.projects ?? []
        self.error = error
        let macPhase = mac?.session
        let macProject = mac?.projectName
        switch connection {
        case .connected:
            phase = .ready
            projectName = macPhase == .ready || macPhase == .starting ? macProject : nil
        case .connectedToApp:
            switch macPhase ?? .noSession {
            case .noSession: phase = .noSession
            case .starting: phase = .starting
            case .ready: phase = .ready
            case .failed: phase = .failed
            }
            projectName = macPhase == .noSession ? nil : macProject
        case .connecting, .idle, .waiting, .failed:
            if appUnavailable {
                phase = .appNotRunning
            } else if connection == .connecting {
                phase = .connecting
            } else {
                phase = .unreachable
            }
            projectName = nil
        }
    }

    @MainActor
    public init(_ session: RemoteSession) {
        self.init(connection: session.state, appUnavailable: session.appUnavailable, mac: session.macSession,
                  error: session.sessionError)
    }

    /// Start needs Relay Runner and no session, and a project that can start.
    public func canStart(chosen: String?) -> Bool {
        (phase == .noSession || phase == .failed) && startProject(chosen: chosen) != nil
    }

    /// Stop ends a session that is starting or running.
    public var canStop: Bool { phase == .starting || phase == .ready }

    /// The project Start uses: the chosen one while it is listed and
    /// available, otherwise the first available one.
    public func startProject(chosen: String?) -> String? {
        let available = projects.filter(\.isAvailable)
        if let chosen, available.contains(where: { $0.projectId == chosen }) { return chosen }
        return available.first?.projectId
    }
}
