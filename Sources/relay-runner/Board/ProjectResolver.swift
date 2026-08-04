import Foundation

/// Resolves or activates the currently-active Workspace scope.
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
        let projectID: String?

        init(repoPath: URL, projectID: String? = nil) {
            self.repoPath = repoPath
            self.projectID = projectID
        }
    }

    enum BoardRoute {
        case project(LinkedProject)
        case programBoard
        case unavailable
    }

    struct WorkspaceScope {
        let route: BoardRoute
        let projects: [LinkedProject]
    }

    private static let bridgeSocketPath = "/tmp/voice_bridge.sock"
    private static let bridgeCwdFilePath = "/tmp/voice_bridge.cwd"
    private static let bridgeProviderFilePath = "/tmp/voice_bridge.provider"

    static func resolve() -> LinkedProject? {
        if let registryV2 = ProjectRegistryV2Service.makeIfEnabled() {
            if case .project(let project) = resolveWorkspaceScope(registryV2: registryV2).route {
                return project
            }
            return nil
        }
        return resolve(
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
                NSLog("[relay-runner] failed to activate Workspace scope at \(cwdURL.path): \(error)")
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
        if let registryV2 = ProjectRegistryV2Service.makeIfEnabled() {
            return resolveWorkspaceScope(registryV2: registryV2).projects
        }
        return resolveActivityProjects(
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
        if let registryV2 = ProjectRegistryV2Service.makeIfEnabled() {
            return resolveWorkspaceScope(registryV2: registryV2).route
        }
        return resolveBoardRoute(
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
        resolveWorkspaceScope(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwdFile,
            bridgeProviderFile: bridgeProviderFile,
            bridgeSessionAlive: bridgeSessionAlive,
            registry: registry
        ).route
    }

    static func resolveWorkspaceScope(
        bridgeSocket: URL,
        bridgeCwdFile: URL,
        bridgeProviderFile: URL? = nil,
        bridgeSessionAlive: () -> Bool = { true },
        registry: ProjectRegistry = ProjectRegistry()
    ) -> WorkspaceScope {
        let fm = FileManager.default
        let bridgeAlive = bridgeSessionAlive() && fm.fileExists(atPath: bridgeSocket.path)
        if bridgeAlive,
           let raw = try? String(contentsOf: bridgeCwdFile, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                return WorkspaceScope(route: .unavailable, projects: [])
            }

            let cwdURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let provider = bridgeProviderFile.flatMap(readBridgeProvider)
            do {
                if let explicitProject = try registry.activeProject(),
                   explicitProject.repoPath.standardizedFileURL.resolvingSymlinksInPath().path == cwdURL.path {
                    return WorkspaceScope(route: .project(explicitProject), projects: [explicitProject])
                }
                if let project = try registry.activateBridgeCwd(at: cwdURL, provider: provider) {
                    return WorkspaceScope(route: .project(project), projects: [project])
                }
                if let workspaceRoot = try registry.activeWorkspaceRoot(),
                   !workspaceRoot.discoveredProjectIDs.isEmpty {
                    return WorkspaceScope(
                        route: .programBoard,
                        projects: try registry.activeWorkspaceProjects()
                    )
                }
                return WorkspaceScope(route: .unavailable, projects: [])
            } catch {
                NSLog("[relay-runner] failed to route board for \(cwdURL.path): \(error)")
                return WorkspaceScope(route: .unavailable, projects: [])
            }
        }

        do {
            if let workspaceRoot = try registry.activeWorkspaceRoot(),
               !workspaceRoot.discoveredProjectIDs.isEmpty {
                return WorkspaceScope(
                    route: .programBoard,
                    projects: try registry.activeWorkspaceProjects()
                )
            }
            if let project = try registry.activeProject() {
                return WorkspaceScope(route: .project(project), projects: [project])
            }
            return WorkspaceScope(route: .unavailable, projects: [])
        } catch {
            NSLog("[relay-runner] failed to resolve Workspace route: \(error)")
            return WorkspaceScope(route: .unavailable, projects: [])
        }
    }

    /// Registry-v2 is app-home backed and therefore resolves without a live
    /// bridge. Bridge cwd is intentionally not consulted here: it may suggest
    /// a project elsewhere, but it cannot confirm mutation ownership.
    static func resolveWorkspaceScope(
        registryV2: ProjectRegistryV2Service,
        fileManager: FileManager = .default
    ) -> WorkspaceScope {
        guard let document = try? registryV2.load().document else {
            return WorkspaceScope(route: .programBoard, projects: [])
        }
        let projects = document.projects.compactMap { record -> LinkedProject? in
            guard record.availability == .available else { return nil }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: record.lastResolvedPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            return LinkedProject(
                repoPath: URL(fileURLWithPath: record.lastResolvedPath, isDirectory: true),
                projectID: record.projectID
            )
        }
        if let activeProjectID = document.activeProjectID,
           let active = projects.first(where: { $0.projectID == activeProjectID }) {
            return WorkspaceScope(route: .project(active), projects: [active])
        }
        // An empty registry is an honest Workspace state, not an unavailable
        // utility surface. The Work tab owns Add Existing/Create Project.
        return WorkspaceScope(route: .programBoard, projects: projects)
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
        if let registryV2 = ProjectRegistryV2Service.makeIfEnabled() {
            let token = try registryV2.confirmProject(matching: pathOrAlias)
            return LinkedProject(
                repoPath: URL(fileURLWithPath: token.repositoryPath, isDirectory: true),
                projectID: token.projectID
            )
        }
        return try registry.activateProject(matching: pathOrAlias, provider: provider, source: .programmatic)
    }

    static func activateProject(
        at path: URL,
        alias: String? = nil,
        provider: String? = nil,
        registry: ProjectRegistry = ProjectRegistry()
    ) throws -> LinkedProject {
        if let registryV2 = ProjectRegistryV2Service.makeIfEnabled() {
            let token = try registryV2.confirmProject(matching: path.path)
            return LinkedProject(
                repoPath: URL(fileURLWithPath: token.repositoryPath, isDirectory: true),
                projectID: token.projectID
            )
        }
        return try registry.activateProject(at: path, alias: alias, provider: provider, source: .programmatic)
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
