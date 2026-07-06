import Foundation

enum ActionPurposeContext {
    private static var lastProposedSummary: String?
    private static var lastProposedAt: Date?
    private static let purposeTTL: TimeInterval = 15
    private static let lock = NSLock()

    static func recordProposedAction(summary: String) {
        lock.lock()
        defer { lock.unlock() }
        lastProposedSummary = summary
        lastProposedAt = Date()
    }

    static func recentPurpose(fallback: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let when = lastProposedAt,
              Date().timeIntervalSince(when) < purposeTTL,
              let summary = lastProposedSummary else {
            return fallback
        }
        return summary
    }
}
