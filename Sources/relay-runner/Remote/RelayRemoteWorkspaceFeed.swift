import RelayRemoteProtocol

/// The Workspace feed for the phone (RR-532 seam; RR-535 fills it in).
///
/// The phone's `workspace_command` reaches the app over the session-control
/// socket and is answered with one `workspace_state` (docs/specs/relay-remote.md,
/// "Workspace feed"). Until RR-535 lands the answer is an empty list with an
/// `error`, so the phone can say the feed is unavailable rather than show an
/// empty board.
enum RelayRemoteWorkspaceFeed {
    static let unsupported = "The Workspace is not available from the phone on this Mac yet."

    static func reply(to command: WorkspaceCommand) -> WorkspaceState {
        WorkspaceState(projects: [], tickets: [], error: unsupported)
    }
}
