import Foundation

/// RR-394 slice A: the per-session voice handoff directory.
///
/// Every embedded provider session owns one spool keyed by a stable session
/// key (its transport/provider session id). The bridge publishes commands
/// into the spool of the session it targets, and each session's
/// `RelayVoiceCommandDelivery` claims only from its own spool, so two
/// concurrent sessions never claim each other's command.
///
/// Shared, process-wide surfaces stay in /tmp: `voice_in.fifo`,
/// `voice_bridge.sock`, `tts_in.fifo`, `tts_control.sock`, `voice_state.sock`,
/// the provider-turn projection, the heartbeat, and the daemon. The command
/// authorization ledger also stays shared until the orchestrator daemon
/// resolves per-session spools (slice H); command seq/id are globally unique,
/// so sharing it cannot cross-authorize sessions.
///
/// `services/voice_bridge.py` resolves the same file names from
/// `RELAY_SESSION_SPOOL_DIR`, falling back to `/tmp` like `legacy`.
struct VoiceSessionSpool: Equatable {
    static let rootDirectory = "/tmp/relay-sessions"
    /// Written by `relay-bridge --relay` with the spool directory the running
    /// bridge publishes into; absent when the bridge serves a manual session.
    static let bridgeTargetPath = "/tmp/voice_bridge.spool"
    static let sharedAuthorizationsPath = "/tmp/voice_command_authorizations.json"
    /// Manual and external-terminal sessions keep the historical /tmp files.
    static let legacy = VoiceSessionSpool(directory: "/tmp", key: nil)

    /// Sanitized session key; nil for `legacy`.
    let key: String?
    let directory: String

    init(key: String, rootDirectory: String = Self.rootDirectory) {
        let sanitized = String(
            key.lowercased().unicodeScalars
                .filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }
                .prefix(64)
                .map(Character.init)
        )
        let resolved = sanitized.isEmpty ? "session" : sanitized
        self.init(directory: (rootDirectory as NSString).appendingPathComponent(resolved), key: resolved)
    }

    private init(directory: String, key: String?) {
        self.directory = directory
        self.key = key
    }

    var isLegacy: Bool { key == nil }

    var command: String { path("voice_cmd_ready") }
    var metadata: String { path("voice_cmd_ready.meta") }
    var claimed: String { path("voice_cmd_claimed.json") }
    var manualAcknowledgement: String { path("voice_cmd_manual_ack.json") }
    var commandState: String { path("voice_command_state.json") }
    var providerSessionID: String { path("voice_provider_session_id") }
    var manualSubmission: String { path("relay_terminal_manual_submission.json") }
    var deliveryEvents: String { path("relay_terminal_delivery_events.jsonl") }
    var launcher: String { path("voice_bridge_launch.command") }
    var authorizations: String { Self.sharedAuthorizationsPath }

    /// This session's delivery files; the shared surfaces come from `base`.
    func deliveryPaths(sharing base: RelayVoiceCommandDelivery.Paths = .init()) -> RelayVoiceCommandDelivery.Paths {
        var paths = base
        paths.command = command
        paths.metadata = metadata
        paths.claimed = claimed
        paths.consumerAcknowledgement = manualAcknowledgement
        paths.commandState = commandState
        paths.manualSubmissions = manualSubmission
        paths.deliveryEvents = deliveryEvents
        return paths
    }

    /// Exported to the provider, its MCP servers, hooks, and reply helper.
    var environment: [(name: String, value: String)] {
        [
            ("RELAY_SESSION_KEY", key ?? ""),
            ("RELAY_SESSION_SPOOL_DIR", isLegacy ? "" : directory),
            ("VOICE_CMD_FILE", command),
            ("VOICE_COMMAND_STATE_FILE", commandState),
            ("VOICE_COMMAND_CLAIM_FILE", claimed),
            ("VOICE_COMMAND_AUTHORIZATION_FILE", authorizations),
            ("VOICE_MANUAL_CLAIM_ACK_FILE", manualAcknowledgement),
            ("RELAY_TERMINAL_MANUAL_SUBMISSION_FILE", manualSubmission),
        ]
    }

    static let environmentNames = legacy.environment.map(\.name)

    /// Create the private spool directory. Refuses a pre-planted symlink or a
    /// directory owned by another user.
    func prepare(fileManager: FileManager = .default) throws {
        guard !isLegacy else { return }
        let root = (directory as NSString).deletingLastPathComponent
        for path in [root, directory] {
            try fileManager.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var info = stat()
            guard lstat(path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid() else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
            }
        }
    }

    /// Remove only this session's spool. The legacy /tmp files stay owned by
    /// the bridge runtime cleanup.
    func remove(fileManager: FileManager = .default) {
        guard !isLegacy else { return }
        try? fileManager.removeItem(atPath: directory)
    }

    /// The spool the running bridge publishes into. Only a directory directly
    /// under `rootDirectory` is accepted; anything else resolves to `legacy`.
    static func bridgeTarget(
        targetFile: String = bridgeTargetPath,
        rootDirectory: String = rootDirectory
    ) -> VoiceSessionSpool {
        guard let raw = try? String(contentsOfFile: targetFile, encoding: .utf8) else { return legacy }
        let directory = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (directory as NSString).deletingLastPathComponent == rootDirectory else { return legacy }
        let spool = VoiceSessionSpool(key: (directory as NSString).lastPathComponent, rootDirectory: rootDirectory)
        return spool.directory == directory ? spool : legacy
    }

    private func path(_ name: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }
}
