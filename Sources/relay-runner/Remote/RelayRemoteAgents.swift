import RelayRemoteProtocol

/// Per-agent state for the phone (RR-532 seam; RR-534 fills it in).
///
/// `session_state.agents` reports every agent, running or not, with what it
/// is doing (docs/specs/relay-remote.md, "Agents"). Until RR-534 lands the Mac
/// reports none, so the field stays absent and `session_state` is exactly what
/// it was before RR-532. Routing a phone's `agent` to that agent's session is
/// the bridge's side, in rust/relay-rs/src/bridge/remote_agents.rs.
enum RelayRemoteAgents {
    /// The `agents` entries for one `session_state`, in table order, or nil
    /// while the Mac does not report per-agent state.
    static func states(_ snapshot: RelaySessionControlHost.Snapshot) -> [AgentStatus]? {
        nil
    }
}
