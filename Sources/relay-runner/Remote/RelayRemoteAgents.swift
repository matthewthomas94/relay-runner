import RelayRemoteProtocol

/// Per-agent state for the phone (RR-534).
///
/// `session_state.agents` reports every agent, running or not, with what it
/// is doing (docs/specs/relay-remote.md, "Agents"). The state comes from the
/// sources that drive the desktop notch glyph (`NotchSessionStatus.resolve`):
/// the agent receiving the recording is `listening`, the one whose reply plays
/// is `playing`, and an agent running a turn is `working`. Routing a phone's
/// `agent` to that agent's session is the bridge's side, in
/// rust/relay-rs/src/bridge/remote_agents.rs.
enum RelayRemoteAgents {
    /// The `agents` entries for one `session_state`, in table order.
    /// `sessionReady` is the session-level `ready` (the bridge accepts
    /// commands); until then every live agent is still `starting`.
    /// `agents` is the app's per-agent config, for each agent's work style.
    static func states(_ snapshot: RelaySessionControlHost.Snapshot, sessionReady: Bool,
                       stopping: Bool = false, agents: AgentsConfig = AgentsConfig()) -> [AgentStatus] {
        let live = stopping ? [] : snapshot.live
        let activity = snapshot.activity
        return SessionAgent.allCases.map { agent in
            let session = live.first { $0.agent == agent }
            let state: AgentActivity
            if let session {
                if !sessionReady || !session.ready {
                    state = .starting
                } else if activity.listening == agent {
                    state = .listening
                } else if activity.playing == agent {
                    state = .playing
                } else if activity.working.contains(agent) {
                    state = .working
                } else {
                    state = .ready
                }
            } else {
                state = !stopping && activity.launching == agent ? .starting : .off
            }
            let workingOn = session == nil ? nil : activity.workingOn[agent]
            return AgentStatus(agent: agent.slug, running: session != nil, state: state, workingOn: workingOn,
                               workStyle: agents[agent].workStyle.rawValue)
        }
    }

    /// RR-534: the bridge's request to start an agent for a phone message
    /// addressed to it: `{"source":"remote_agent","state":"start","agent":…}`
    /// on the state socket. Nil for anything else.
    static func startRequest(_ json: [String: Any]) -> SessionAgent? {
        guard json["source"] as? String == "remote_agent", json["state"] as? String == "start",
              let slug = json["agent"] as? String else { return nil }
        return SessionAgent(choice: slug)
    }
}
