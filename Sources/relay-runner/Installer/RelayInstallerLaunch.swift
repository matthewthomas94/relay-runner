import AppKit
import Foundation

enum RelayInstallerLaunch {
    static let minimumVisibleInstallDuration: TimeInterval = 3.0

    static func remainingDelay(startedAt: Date, now: Date = Date()) -> TimeInterval {
        max(0, minimumVisibleInstallDuration - now.timeIntervalSince(startedAt))
    }

    static func openConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }
}
