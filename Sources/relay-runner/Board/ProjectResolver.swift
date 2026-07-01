import Foundation

/// Resolves or activates the currently-active board project.
///
/// A `/relay-bridge` session remains the default activation path. The bridge
/// writes its launching cwd to `/tmp/voice_bridge.cwd` at startup and clears
/// it on shutdown; the bridge daemon plus cwd/provider metadata are the
/// liveness check. The agent-consumer heartbeat is watchdog input only, since
/// completed Codex App turns can stop touching it while the bridge session is
/// still valid. When no bridge is live, an explicitly activated registry
/// project can still back UI/MCP programmatic flows.
///
/// Bridge cwd values run through the workspace/project classifier: a single
/// repo activates that repo and initializes `.orchestrator/config.toml` when
/// needed, while a workspace root records Program Manager discovery state
/// without creating a parent board.
enum ProjectResolver {

    /// Minimal value type the board passes around. The previous
    /// repoRemote/defaultBranch fields are gone — defaults come from
    /// `git symbolic-ref` daemon-side now, and nothing in the UI used them.
    struct LinkedProject {
        let repoPath: URL
    }

    enum BoardRoute {
        case project(LinkedProject)
        case programBoard
        case unavailable
    }

    private static let bridgeSocketPath = "/tmp/voice_bridge.sock"
    private static let bridgeCwdFilePath = "/tmp/voice_bridge.cwd"
    private static let bridgeProviderFilePath = "/tmp/voice_bridge.provider"

    static func resolve() -> LinkedProject? {
        resolve(
            bridgeSocket: URL(fileURLWithPath: bridgeSocketPath),
            bridgeCwdFile: URL(fileURLWithPath: bridgeCwdFilePath),
            bridgeProviderFile: URL(fileURLWithPath: bridgeProviderFilePath),
            bridgeSessionAlive: ProcessManager.activeRelaySessionAlive
        )
    }

    static func resolve(
        bridgeSocket: URL,
        bridgeCwdFile: URL,
        bridgeProviderFile: URL? = nil,
        bridgeSessionAlive: () -> Bool = { true },
        registry: ProjectRegistry = ProjectRegistry()
    ) -> LinkedProject? {
        let fm = FileManager.default
        // Tests can pass explicit fixture paths and use the default healthy
        // closure; production resolve() checks process + bridge metadata.
        let bridgeAlive = bridgeSessionAlive() && fm.fileExists(atPath: bridgeSocket.path)
        if bridgeAlive,
           let raw = try? String(contentsOf: bridgeCwdFile, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }

            let cwdURL = URL(fileURLWithPath: path)
            let provider = bridgeProviderFile.flatMap(readBridgeProvider)
            do {
                return try registry.activateBridgeCwd(at: cwdURL, provider: provider)
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

    static func resolveActivityProjects() -> [LinkedProject] {
        resolveActivityProjects(
            bridgeSocket: URL(fileURLWithPath: bridgeSocketPath),
            bridgeCwdFile: URL(fileURLWithPath: bridgeCwdFilePath),
            bridgeProviderFile: URL(fileURLWithPath: bridgeProviderFilePath),
            bridgeSessionAlive: ProcessManager.activeRelaySessionAlive
        )
    }

    static func resolveActivityProjects(
        bridgeSocket: URL,
        bridgeCwdFile: URL,
        bridgeProviderFile: URL? = nil,
        bridgeSessionAlive: () -> Bool = { true },
        registry: ProjectRegistry = ProjectRegistry()
    ) -> [LinkedProject] {
        let fm = FileManager.default
        let bridgeAlive = bridgeSessionAlive() && fm.fileExists(atPath: bridgeSocket.path)
        if bridgeAlive,
           let raw = try? String(contentsOf: bridgeCwdFile, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return [] }

            let cwdURL = URL(fileURLWithPath: path)
            let provider = bridgeProviderFile.flatMap(readBridgeProvider)
            do {
                if let project = try registry.activateBridgeCwd(at: cwdURL, provider: provider) {
                    return [project]
                }
                return try registry.activeWorkspaceProjects()
            } catch {
                NSLog("[relay-runner] failed to resolve activity projects for \(cwdURL.path): \(error)")
                return []
            }
        }

        do {
            if let project = try registry.activeProject() {
                return [project]
            }
            return try registry.activeWorkspaceProjects()
        } catch {
            NSLog("[relay-runner] failed to resolve activity projects: \(error)")
            return []
        }
    }

    static func resolveBoardRoute() -> BoardRoute {
        resolveBoardRoute(
            bridgeSocket: URL(fileURLWithPath: bridgeSocketPath),
            bridgeCwdFile: URL(fileURLWithPath: bridgeCwdFilePath),
            bridgeProviderFile: URL(fileURLWithPath: bridgeProviderFilePath),
            bridgeSessionAlive: ProcessManager.activeRelaySessionAlive
        )
    }

    static func resolveBoardRoute(
        bridgeSocket: URL,
        bridgeCwdFile: URL,
        bridgeProviderFile: URL? = nil,
        bridgeSessionAlive: () -> Bool = { true },
        registry: ProjectRegistry = ProjectRegistry()
    ) -> BoardRoute {
        let fm = FileManager.default
        let bridgeAlive = bridgeSessionAlive() && fm.fileExists(atPath: bridgeSocket.path)
        if bridgeAlive,
           let raw = try? String(contentsOf: bridgeCwdFile, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return .unavailable }

            let cwdURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let provider = bridgeProviderFile.flatMap(readBridgeProvider)
            do {
                if let explicitProject = try registry.activeProject(),
                   explicitProject.repoPath.standardizedFileURL.resolvingSymlinksInPath().path == cwdURL.path {
                    return .project(explicitProject)
                }
                if let project = try registry.activateBridgeCwd(at: cwdURL, provider: provider) {
                    return .project(project)
                }
                if let workspaceRoot = try registry.activeWorkspaceRoot(),
                   !workspaceRoot.discoveredProjectIDs.isEmpty {
                    return .programBoard
                }
                return .unavailable
            } catch {
                NSLog("[relay-runner] failed to route board for \(cwdURL.path): \(error)")
                return .unavailable
            }
        }

        do {
            if let workspaceRoot = try registry.activeWorkspaceRoot(),
               !workspaceRoot.discoveredProjectIDs.isEmpty {
                return .programBoard
            }
            if let project = try registry.activeProject() {
                return .project(project)
            }
            return .unavailable
        } catch {
            NSLog("[relay-runner] failed to resolve board route: \(error)")
            return .unavailable
        }
    }

    private static func readBridgeProvider(from url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let provider = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return provider.isEmpty ? nil : provider
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
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var tickets: [Ticket] = []
        for url in entries where url.pathExtension == "md" {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            do {
                tickets.append(try TicketParser.parse(contents: contents, modifiedAt: modifiedAt))
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
