import Foundation

/// One line of an agent's chat (RR-540).
struct ChatMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable {
        /// What the user typed or said.
        case user
        /// The agent's reply: the text of one `speech` frame.
        case agent
        /// A `status` frame, such as a ticket the agent created.
        case status
    }

    var id = UUID()
    let role: Role
    let text: String
    let date: Date
    /// The Mac's seq for an agent reply or status, which maps playback to its chat.
    var seq: Int?
    /// The names of the files sent with a message of the user's.
    var files: [String]?
}

/// Each agent's chat on disk: one JSON file per agent under Application
/// Support, keeping the newest `limit` messages, so history survives a relaunch.
struct ChatStore {
    static let limit = 200

    /// Nil keeps nothing on disk, for sample screens.
    let directory: URL?

    init(directory: URL?) {
        self.directory = directory
    }

    static var standard: ChatStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return ChatStore(directory: base?.appendingPathComponent("AgentChats", isDirectory: true))
    }

    func load(_ agent: String) -> [ChatMessage] {
        guard let url = url(agent), let data = try? Data(contentsOf: url),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return [] }
        return Self.capped(messages)
    }

    func save(_ messages: [ChatMessage], for agent: String) {
        guard let directory, let url = url(agent) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Self.capped(messages)) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func capped(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.count > limit ? Array(messages.suffix(limit)) : messages
    }

    private func url(_ agent: String) -> URL? {
        directory?.appendingPathComponent("\(agent).json")
    }
}
