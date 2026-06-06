import Foundation

/// Resolves or activates the currently-active board project.
///
/// A `/relay-bridge` session remains the default activation path. The bridge
/// writes its launching cwd to `/tmp/voice_bridge.cwd` at startup and clears
/// it on shutdown; the bridge socket plus the agent-consumer heartbeat are
/// the liveness check. When no bridge is live, an explicitly activated
/// registry project can still back UI/MCP programmatic flows.
///
/// If the bridge starts inside an existing git repo, the board uses that repo
/// root, registers it, marks it active, and initializes `.orchestrator/config.toml`
/// if needed. Non-git bridge cwd values are refused; callers must initialize git
/// explicitly before activating them.
enum ProjectResolver {

    /// Minimal value type the board passes around. The previous
    /// repoRemote/defaultBranch fields are gone — defaults come from
    /// `git symbolic-ref` daemon-side now, and nothing in the UI used them.
    struct LinkedProject {
        let repoPath: URL
    }

    private static let bridgeSocketPath = "/tmp/voice_bridge.sock"
    private static let bridgeCwdFilePath = "/tmp/voice_bridge.cwd"

    static func resolve() -> LinkedProject? {
        resolve(
            bridgeSocket: URL(fileURLWithPath: bridgeSocketPath),
            bridgeCwdFile: URL(fileURLWithPath: bridgeCwdFilePath),
            bridgeSessionAlive: ProcessManager.activeRelaySessionAlive
        )
    }

    static func resolve(
        bridgeSocket: URL,
        bridgeCwdFile: URL,
        bridgeSessionAlive: () -> Bool = { true },
        registry: ProjectRegistry = ProjectRegistry()
    ) -> LinkedProject? {
        let fm = FileManager.default
        // Tests can pass explicit fixture paths and use the default healthy
        // closure; production resolve() checks process + consumer liveness.
        let bridgeAlive = bridgeSessionAlive() && fm.fileExists(atPath: bridgeSocket.path)
        if bridgeAlive,
           let raw = try? String(contentsOf: bridgeCwdFile, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }

            let cwdURL = URL(fileURLWithPath: path)
            do {
                return try registry.activateProject(at: cwdURL, source: .bridgeCwd)
            } catch {
                NSLog("[relay-runner] failed to activate board project at \(cwdURL.path): \(error)")
                return nil
            }
        }

        do {
            return try registry.activeProject()
        } catch {
            NSLog("[relay-runner] failed to resolve active project: \(error)")
            return nil
        }
    }

    static func activateProject(
        matching pathOrAlias: String,
        provider: String? = nil,
        registry: ProjectRegistry = ProjectRegistry()
    ) throws -> LinkedProject {
        try registry.activateProject(matching: pathOrAlias, provider: provider, source: .programmatic)
    }

    static func activateProject(
        at path: URL,
        alias: String? = nil,
        provider: String? = nil,
        registry: ProjectRegistry = ProjectRegistry()
    ) throws -> LinkedProject {
        try registry.activateProject(at: path, alias: alias, provider: provider, source: .programmatic)
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

}
