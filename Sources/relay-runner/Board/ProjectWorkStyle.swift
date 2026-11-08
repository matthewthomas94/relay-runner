import Foundation
import Observation

/// How the session routes change requests. Mirrors `WORK_STYLES` in
/// services/command_actions.py, which reads the choice from `session-work-style.json`.
enum ProjectWorkStyle: String, CaseIterable, Identifiable, Codable {
    case auto
    case direct
    case orchestrated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .direct: return "Direct"
        case .orchestrated: return "Orchestrated"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Decides per request, and asks when unsure"
        case .direct: return "Makes changes now, without tickets"
        case .orchestrated: return "Turns changes into tickets for workers"
        }
    }
}

/// The session-wide work style picked from the Start button's menu. The
/// Python router reads the same file on every request, so a change applies
/// from the next request and wins over a project's `.relay-runner.toml`.
/// No file means no choice yet: the menu shows Auto.
@MainActor
@Observable
final class SessionWorkStyleStore {
    static let shared = SessionWorkStyleStore()

    private let fileURL: URL
    private(set) var style: ProjectWorkStyle

    init(fileURL: URL = SessionWorkStyleStore.defaultFileURL) {
        self.fileURL = fileURL
        style = Self.load(from: fileURL)
    }

    nonisolated static var defaultFileURL: URL {
        if let override = ProcessInfo.processInfo.environment["RELAY_SESSION_WORK_STYLE_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("relay-runner", isDirectory: true)
            .appendingPathComponent("session-work-style.json")
    }

    func select(_ style: ProjectWorkStyle) {
        self.style = style
        Self.save(style, to: fileURL)
    }

    /// Picks up a change made by voice or `relay-work-style` since the last read.
    func reload() {
        let saved = Self.load(from: fileURL)
        if saved != style { style = saved }
    }

    nonisolated static func load(from fileURL: URL) -> ProjectWorkStyle {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["work_style"] as? String,
              let style = ProjectWorkStyle(rawValue: raw.lowercased())
        else { return .auto }
        return style
    }

    nonisolated static func save(_ style: ProjectWorkStyle, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: ["work_style": style.rawValue], options: [.sortedKeys])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[relay-runner] Could not save work style: \(error.localizedDescription)")
        }
    }
}
