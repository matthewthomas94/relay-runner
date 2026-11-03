import Foundation

/// Loads and saves the user's recorded `[Template]` as JSON. Templates hold
/// only labels and geometry frames, never camera images.
public struct TemplateStore {
    public let url: URL

    /// `~/Library/Application Support/relay-runner/true-whisper/templates.json`.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("relay-runner/true-whisper/templates.json")
    }

    public init(url: URL = TemplateStore.defaultURL) {
        self.url = url
    }

    /// The stored templates, or `[]` when the file is missing or unreadable.
    public func load() -> [Template] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Template].self, from: data)) ?? []
    }

    public func save(_ templates: [Template]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(templates).write(to: url, options: .atomic)
    }
}
