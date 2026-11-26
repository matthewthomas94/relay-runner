import RelayRemoteProtocol

/// The Mac's settings for the phone (RR-532 seam; RR-536 fills it in).
///
/// The phone's `settings_command` reaches the app over the session-control
/// socket and is answered with one `settings_state` (docs/specs/relay-remote.md,
/// "Settings"). Until RR-536 lands every command, `get` or `set`, is answered
/// with only an `error` and nothing is changed.
enum RelayRemoteSettings {
    static let unsupported = "Settings cannot be changed from the phone on this Mac yet."

    static func reply(to command: SettingsCommand) -> SettingsState {
        SettingsState(error: unsupported)
    }
}
