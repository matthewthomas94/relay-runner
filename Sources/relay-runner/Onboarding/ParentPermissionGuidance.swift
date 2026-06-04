import Foundation

enum ParentPermissionGuidance {
    static let defaultParentApps = ["Terminal.app", "Codex.app", "Claude.app"]

    static func defaultParentApps(for provider: GeneralConfig.AgentProvider) -> [String] {
        switch provider {
        case .codex: return ["Terminal.app", "Codex.app"]
        case .claude: return ["Terminal.app", "Claude.app"]
        }
    }

    static func targetList(for provider: GeneralConfig.AgentProvider) -> String {
        formatList(defaultParentApps(for: provider))
    }

    static func targetNames(detectedParent parent: String) -> [String] {
        var targets = defaultParentApps
        let detected = displayName(for: parent)
        if !detected.isEmpty && !targets.contains(detected) {
            targets.append(detected)
        }
        return targets
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
}
