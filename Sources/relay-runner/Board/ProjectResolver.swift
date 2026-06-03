import Foundation

/// Resolves the currently-active project from the running voice-bridge session.
///
/// The board only opens when a `/relay-bridge` session is live. The bridge
/// writes its launching cwd to `/tmp/voice_bridge.cwd` at startup and clears
/// it on shutdown; the bridge socket plus the agent-consumer heartbeat are
/// the liveness check. Together they let the board show "the repo this voice
/// session is rooted in" without a separate project registry — there's
/// exactly one bridge session at a time, so there's no ambiguity.
///
/// A path resolves to a project iff it points to a git repo. Fresh repos get
/// `.orchestrator/config.toml` initialized on first resolve so the board can
/// open empty and mint repo-scoped ticket IDs.
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
        bridgeSessionAlive: () -> Bool = { true }
    ) -> LinkedProject? {
        let fm = FileManager.default
        // Tests can pass explicit fixture paths and use the default healthy
        // closure; production resolve() checks process + consumer liveness.
        guard bridgeSessionAlive() else { return nil }
        guard fm.fileExists(atPath: bridgeSocket.path) else { return nil }
        guard let raw = try? String(contentsOf: bridgeCwdFile, encoding: .utf8) else {
            return nil
        }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let repoURL = URL(fileURLWithPath: path)
        let dotGit = repoURL.appendingPathComponent(".git", isDirectory: false).path
        guard fm.fileExists(atPath: dotGit) else {
            return nil
        }
        do {
            try BoardProjectConfig.ensureExists(forRepoAt: repoURL)
        } catch {
            NSLog("[relay-runner] failed to initialize board project at \(repoURL.path): \(error)")
            return nil
        }
        return LinkedProject(repoPath: repoURL)
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
