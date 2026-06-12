import Foundation

struct MenuBarServiceLifecycleStatus: Equatable {
    let label: String
    let detail: String

    private static let maximumLabelCharacters = 44

    init?(_ message: String?) {
        guard let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty
        else { return nil }

        self.detail = detail
        self.label = Self.compactLabel(for: detail)
    }

    private static func compactLabel(for detail: String) -> String {
        if detail.hasPrefix("Bundled service refresh failed") {
            return "Bundled service refresh failed"
        }
        if detail.hasPrefix("Bundled service refresh deferred") {
            return "Bundled service refresh deferred"
        }
        guard detail.count > maximumLabelCharacters else { return detail }

        let prefixLength = maximumLabelCharacters - 3
        return String(detail.prefix(prefixLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
