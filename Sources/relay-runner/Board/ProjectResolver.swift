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
/// If the bridge starts inside an existing git repo, the board uses that repo
/// root. If it starts in a directory that is not already in a repo, the board
/// initializes that cwd as a repo. Either way, the project gets
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

        let cwdURL = URL(fileURLWithPath: path)
        do {
            let repoURL = try ensureGitRepo(forBridgeCwd: cwdURL)
            try BoardProjectConfig.ensureExists(forRepoAt: repoURL)
            return LinkedProject(repoPath: repoURL)
        } catch {
            NSLog("[relay-runner] failed to initialize board project at \(cwdURL.path): \(error)")
            return nil
        }
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

    private static func ensureGitRepo(forBridgeCwd cwdURL: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwdURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GitError.notDirectory(path: cwdURL.path)
        }

        if let repoURL = try gitTopLevel(containing: cwdURL) {
            return repoURL
        }

        let initResult = try runGit(["init", "--quiet"], in: cwdURL)
        guard initResult.status == 0 else {
            throw GitError.initFailed(path: cwdURL.path, status: initResult.status)
        }
        return cwdURL
    }

    private static func gitTopLevel(containing cwdURL: URL) throws -> URL? {
        let result = try runGit(["rev-parse", "--show-toplevel"], in: cwdURL)
        guard result.status == 0 else { return nil }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func runGit(_ arguments: [String], in directory: URL) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private enum GitError: Error, CustomStringConvertible {
        case notDirectory(path: String)
        case initFailed(path: String, status: Int32)

        var description: String {
            switch self {
            case .notDirectory(let path):
                return "bridge cwd is not a directory: \(path)"
            case .initFailed(let path, let status):
                return "git init failed at \(path) with status \(status)"
            }
        }
    }
}
