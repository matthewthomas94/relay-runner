import Foundation

enum SetupRuntimeReadiness: Equatable {
    case notStarted
    case preparing(String)
    case ready
    case failed(String)

    static let defaultTimeout: TimeInterval = 8 * 60

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }

    var canRetry: Bool {
        switch self {
        case .failed:
            return true
        case .notStarted, .preparing, .ready:
            return false
        }
    }

    var needsSetupAction: Bool {
        switch self {
        case .notStarted, .failed:
            return true
        case .preparing, .ready:
            return false
        }
    }

    var statusDetail: String {
        switch self {
        case .notStarted:
            return "Not started"
        case .preparing(let message):
            return message
        case .ready:
            return "Loaded and listening"
        case .failed(let message):
            return message
        }
    }

    static func resolve(
        engineStatusMessage: String?,
        engineError: String?,
        setupSucceeded: Bool = false,
        startedAt: Date?,
        now: Date = Date(),
        timeout: TimeInterval = Self.defaultTimeout
    ) -> SetupRuntimeReadiness {
        let message = engineStatusMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawError = engineError?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawError.isEmpty {
            return .failed(ErrorTranslator.translate(rawError).headline)
        }

        if setupSucceeded || message == "Listening" {
            return .ready
        }

        if let startedAt, now.timeIntervalSince(startedAt) >= timeout {
            return .failed(timeoutMessage(currentMessage: message))
        }

        if !message.isEmpty {
            return .preparing(message)
        }
        if startedAt != nil {
            return .preparing("Starting speech-to-text model...")
        }
        return .notStarted
    }

    private static func timeoutMessage(currentMessage: String) -> String {
        if currentMessage.isEmpty {
            return "Speech-to-Text setup timed out before the model reported ready. Retry setup to restart model loading."
        }
        let detail = currentMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return "Speech-to-Text setup timed out while \(detail). Retry setup to restart model loading."
    }
}
