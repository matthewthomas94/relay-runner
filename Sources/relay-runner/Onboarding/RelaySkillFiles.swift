import Foundation

/// The Relay skill files relay-bridge installs for each provider. Mirrors the
/// RELAY_SKILLS_OK and ORCH_OK gates in scripts/relay-bridge: the install is
/// complete only when every skill exists for both Claude and Codex.
enum RelaySkillFiles {
    static let names = ["relay-bridge", "relay-stop", "relay-dispatch", "relay-workflow"]

    static func paths(home: String = NSHomeDirectory()) -> [String] {
        let homeDir = home as NSString
        return [".claude/skills", ".codex/skills"].flatMap { dir in
            names.map { homeDir.appendingPathComponent("\(dir)/\($0)/SKILL.md") }
        }
    }

    static func allInstalled(home: String = NSHomeDirectory(),
                             fileManager: FileManager = .default) -> Bool {
        paths(home: home).allSatisfy { fileManager.fileExists(atPath: $0) }
    }
}
