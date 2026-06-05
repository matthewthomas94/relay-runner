import AppKit
import Foundation

enum ParentPermissionGuidance {
    static let defaultParentApps = ["Terminal.app", "Codex.app", "Claude.app"]

    static func defaultParentHint(for provider: GeneralConfig.AgentProvider) -> String {
        switch provider {
        case .codex:
            return "the terminal or IDE running Codex (or Codex.app when using the native app)"
        case .claude:
            return "the terminal or IDE running Claude (or Claude.app when using the native app)"
        }
    }

    static func targetList(for provider: GeneralConfig.AgentProvider) -> String {
        defaultParentHint(for: provider)
    }

    static func appTargets(for provider: GeneralConfig.AgentProvider) -> [PermissionAppTarget] {
        switch provider {
        case .codex:
            return [
                target(displayName: "Codex.app", bundleIDs: ["com.openai.codex"], fallbackPaths: ["/Applications/Codex.app"]),
                terminalTarget()
            ]
        case .claude:
            return [
                target(
                    displayName: "Claude.app",
                    bundleIDs: ["com.anthropic.claudefordesktop", "com.anthropic.claude"],
                    fallbackPaths: ["/Applications/Claude.app"]
                ),
                terminalTarget()
            ]
        }
    }

    static func appTargets(detectedParent parent: String) -> [PermissionAppTarget] {
        let name = displayName(for: parent)
        guard !name.isEmpty else {
            return defaultParentApps.map { PermissionAppTarget(displayName: $0, bundleURL: nil) }
        }
        switch name {
        case "Terminal.app":
            return [terminalTarget()]
        case "Codex.app":
            return [target(displayName: "Codex.app", bundleIDs: ["com.openai.codex"], fallbackPaths: ["/Applications/Codex.app"])]
        case "Claude.app":
            return [
                target(
                    displayName: "Claude.app",
                    bundleIDs: ["com.anthropic.claudefordesktop", "com.anthropic.claude"],
                    fallbackPaths: ["/Applications/Claude.app"]
                )
            ]
        default:
            return [PermissionAppTarget(displayName: name, bundleURL: nil)]
        }
    }

    static func targetNames(detectedParent parent: String) -> [String] {
        let detected = displayName(for: parent)
        if !detected.isEmpty {
            return [detected]
        }
        return defaultParentApps
    }

    static func targetList(detectedParent parent: String) -> String {
        formatList(targetNames(detectedParent: parent))
    }

    static func displayName(for parent: String) -> String {
        let trimmed = parent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "unknown" else { return "" }

        switch trimmed.lowercased() {
        case "terminal", "terminal.app":
            return "Terminal.app"
        case "codex", "codex.app":
            return "Codex.app"
        case "claude", "claude.app":
            return "Claude.app"
        default:
            return trimmed
        }
    }

    private static func formatList(_ items: [String]) -> String {
        switch items.count {
        case 0:
            return ""
        case 1:
            return items[0]
        case 2:
            return "\(items[0]) and \(items[1])"
        default:
            return "\(items.dropLast().joined(separator: ", ")), and \(items.last!)"
        }
    }

    private static func terminalTarget() -> PermissionAppTarget {
        target(
            displayName: "Terminal.app",
            bundleIDs: ["com.apple.Terminal"],
            fallbackPaths: [
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/Utilities/Terminal.app"
            ]
        )
    }

    private static func target(displayName: String,
                               bundleIDs: [String],
                               fallbackPaths: [String]) -> PermissionAppTarget {
        for bundleID in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return PermissionAppTarget(displayName: displayName, bundleURL: url)
            }
        }
        for path in fallbackPaths {
            if FileManager.default.fileExists(atPath: path) {
                return PermissionAppTarget(displayName: displayName, bundleURL: URL(fileURLWithPath: path))
            }
        }
        return PermissionAppTarget(displayName: displayName, bundleURL: nil)
    }
}
