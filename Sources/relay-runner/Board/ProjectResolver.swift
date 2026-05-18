import Foundation
import TOMLKit

/// Locates the currently-active project's `.orchestrator/` directory.
///
/// V1 strategy: read the orchestrator daemon's `projects.toml` and return the
/// first linked project's repo path. This matches the spec's "single linked
/// project" assumption; a real picker UI (and voice-bridge-cwd resolution)
/// land in later milestones.
enum ProjectResolver {

    struct LinkedProject {
        let repoPath: URL
        let repoRemote: String
        let defaultBranch: String
    }

    static func resolve() -> LinkedProject? {
        guard let supportDir = applicationSupportDir() else { return nil }
        let tomlPath = supportDir
            .appendingPathComponent("orchestrator", isDirectory: true)
            .appendingPathComponent("projects.toml", isDirectory: false)

        guard let raw = try? String(contentsOf: tomlPath, encoding: .utf8),
              let table = try? TOMLTable(string: raw),
              let projects = table["projects"]?.tomlValue.table else {
            return nil
        }

        // Pick the first project. TOMLTable doesn't promise iteration order,
        // but for v1 (zero or one linked project per user) any deterministic
        // pick is fine.
        for (_, value) in projects {
            guard let entry = value.tomlValue.table,
                  let repoPath = entry["repo_path"]?.tomlValue.string else { continue }
            let remote = entry["repo_remote"]?.tomlValue.string ?? ""
            let branch = entry["default_branch"]?.tomlValue.string ?? "main"
            return LinkedProject(
                repoPath: URL(fileURLWithPath: repoPath),
                repoRemote: remote,
                defaultBranch: branch
            )
        }
        return nil
    }

    static func scanTickets(in project: LinkedProject) -> [Ticket] {
        let dir = ticketsDirectory(in: project)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var tickets: [Ticket] = []
        for url in entries where url.pathExtension == "md" {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            do {
                tickets.append(try TicketParser.parse(contents: contents))
            } catch {
                NSLog("[relay-runner] skipping ticket \(url.lastPathComponent): \(error)")
            }
        }
        return tickets
    }

    /// `.orchestrator/` under the linked project. The writer and scanner share
    /// this so they stay aligned.
    static func ticketsDirectory(in project: LinkedProject) -> URL {
        project.repoPath.appendingPathComponent(".orchestrator", isDirectory: true)
    }

    private static func applicationSupportDir() -> URL? {
        let fm = FileManager.default
        return try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("relay-runner", isDirectory: true)
    }
}
