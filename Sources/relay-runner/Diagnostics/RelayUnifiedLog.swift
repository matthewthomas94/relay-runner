import os

/// Unified-log sinks for diagnostics that a support report must be able to
/// read. NSLog lines were absent from the RR-517 report while this subsystem's
/// STTModelPreparation line was present, so gesture and speech start/failure
/// lines use the same subsystem. Messages are logged public: callers pass only
/// states, counts and error descriptions, never key contents or transcripts.
enum RelayUnifiedLog {
    static let subsystem = "com.relay-runner"

    static func sink(category: String) -> (String) -> Void {
        let logger = Logger(subsystem: subsystem, category: category)
        return { message in logger.notice("\(message, privacy: .public)") }
    }
}
