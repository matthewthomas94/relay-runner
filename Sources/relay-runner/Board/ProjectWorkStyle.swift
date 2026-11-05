import Foundation

/// How a project's sessions route change requests. Mirrors `WORK_STYLES` in
/// services/command_actions.py, which reads the choice from `work-styles.json`.
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

/// Per-project work style chosen in the Workspace, keyed by the resolved
/// project path. The Python classifier reads the same file.
enum ProjectWorkStyleStore {
    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["RELAY_WORK_STYLES_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("relay-runner", isDirectory: true)
            .appendingPathComponent("work-styles.json")
    }

    static func key(for path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The Workspace choice, else the project's `.relay-runner.toml`, else auto.
    static func style(for path: String, fileURL: URL = fileURL) -> ProjectWorkStyle {
        if let chosen = load(fileURL)[key(for: path)].flatMap(ProjectWorkStyle.init(rawValue:)) {
            return chosen
        }
        return projectFileStyle(at: path) ?? .auto
    }

    static func projectFileStyle(at path: String) -> ProjectWorkStyle? {
        let url = URL(fileURLWithPath: path).appendingPathComponent(".relay-runner.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "work_style" else { continue }
            return ProjectWorkStyle(rawValue: parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased())
        }
        return nil
    }

    static func setStyle(_ style: ProjectWorkStyle, for path: String, fileURL: URL = fileURL) {
        var styles = load(fileURL)
        styles[key(for: path)] = style.rawValue
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: styles, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[relay-runner] Could not save work style: \(error.localizedDescription)")
        }
    }

    private static func load(_ fileURL: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }
}
