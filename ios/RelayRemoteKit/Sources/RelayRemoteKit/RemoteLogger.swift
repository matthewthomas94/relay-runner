import os

/// Relay Remote's only log sink. Callers pass fixed event names and
/// non-sensitive values (states, error codes, counts). Key material,
/// fingerprints, tokens, the pairing code and utterance text are never passed
/// here, so nothing secret can reach the unified log.
public struct RemoteLogger: Sendable {
    private let sink: @Sendable (String) -> Void

    public init(_ sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }

    public func callAsFunction(_ event: String) {
        sink(event)
    }

    public static let system: RemoteLogger = {
        let logger = Logger(subsystem: "com.relayrunner.remote", category: "transport")
        return RemoteLogger { logger.info("\($0, privacy: .public)") }
    }()

    public static let silent = RemoteLogger { _ in }
}
