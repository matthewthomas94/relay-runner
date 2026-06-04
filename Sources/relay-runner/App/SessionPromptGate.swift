import Foundation

struct SessionPromptGate {
    static let defaultCooldown: TimeInterval = 20

    private var lastShownAt: Date = .distantPast

    mutating func shouldShow(now: Date = Date(),
                             cooldown: TimeInterval = Self.defaultCooldown) -> Bool {
        guard now.timeIntervalSince(lastShownAt) >= cooldown else {
            return false
        }
        lastShownAt = now
        return true
    }

    mutating func reset() {
        lastShownAt = .distantPast
    }
}
