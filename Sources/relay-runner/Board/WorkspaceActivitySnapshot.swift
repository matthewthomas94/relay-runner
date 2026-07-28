import Foundation

struct WorkspaceActivitySnapshot {
    let route: ProjectResolver.BoardRoute
    let projects: [ProjectResolver.LinkedProject]
    let runStates: [RunState]
    let tickets: [Ticket]
    let ticketsByRunKey: [String: Ticket]
    let foregroundProviderTurnActive: Bool

    static let empty = WorkspaceActivitySnapshot(
        route: .unavailable,
        projects: [],
        runStates: [],
        tickets: [],
        ticketsByRunKey: [:],
        foregroundProviderTurnActive: false
    )
}

/// Owns the one background refresh shared by the notch, sleep prevention, and
/// Workspace route/scope consumers. Route classification is reused until the
/// bridge identity changes or a caller explicitly invalidates it. Ticket
/// parsing and the shared runs index are likewise reused while file revisions
/// remain unchanged.
actor WorkspaceActivitySnapshotStore {
    struct RouteKey: Equatable {
        let bridgeSessionAlive: Bool
        let bridgeSocketExists: Bool
        let bridgeCwd: String?
        let bridgeProvider: String?
    }

    struct ActivityData {
        let runStates: [RunState]
        let tickets: [Ticket]
        let ticketsByRunKey: [String: Ticket]
        let foregroundProviderTurnActive: Bool
        let runRevision: FileRevision?
        let ticketFiles: [String: CachedTicket]
    }

    struct Dependencies {
        var routeKey: (Bool) -> RouteKey
        var resolveScope: (Bool) -> ProjectResolver.WorkspaceScope
        var loadActivity: (ProjectResolver.WorkspaceScope, Cache?) -> ActivityData

        static let live = Dependencies(
            routeKey: WorkspaceActivitySnapshotStore.loadRouteKey,
            resolveScope: WorkspaceActivitySnapshotStore.resolveScope,
            loadActivity: WorkspaceActivitySnapshotStore.loadActivity
        )
    }

    struct FileRevision: Equatable {
        let modifiedAt: Date?
        let size: Int?
    }

    struct CachedTicket {
        let revision: FileRevision
        let ticket: Ticket
    }

    struct Cache {
        let routeKey: RouteKey
        let scope: ProjectResolver.WorkspaceScope
        let runRevision: FileRevision?
        let runStates: [RunState]
        let ticketFiles: [String: CachedTicket]
    }

    private struct InFlight {
        let id: Int
        let bridgeSessionAlive: Bool
        let task: Task<(WorkspaceActivitySnapshot, Cache), Never>
    }

    private let dependencies: Dependencies
    private var cache: Cache?
    private var inFlight: InFlight?
    private var generation = 0
    private var nextID = 0

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func refresh(bridgeSessionAlive: Bool) async -> WorkspaceActivitySnapshot {
        if let inFlight, inFlight.bridgeSessionAlive == bridgeSessionAlive {
            return await inFlight.task.value.0
        }
        if let inFlight {
            inFlight.task.cancel()
            self.inFlight = nil
        }

        nextID += 1
        let id = nextID
        let generation = generation
        let dependencies = dependencies
        let previous = cache
        let task = Task.detached(priority: .utility) {
            let routeKey = dependencies.routeKey(bridgeSessionAlive)
            let scope: ProjectResolver.WorkspaceScope
            if previous?.routeKey == routeKey, let cachedScope = previous?.scope {
                scope = cachedScope
            } else {
                scope = dependencies.resolveScope(bridgeSessionAlive)
            }

            let activity = dependencies.loadActivity(scope, previous)
            let snapshot = WorkspaceActivitySnapshot(
                route: scope.route,
                projects: scope.projects,
                runStates: activity.runStates,
                tickets: activity.tickets,
                ticketsByRunKey: activity.ticketsByRunKey,
                foregroundProviderTurnActive: activity.foregroundProviderTurnActive
            )
            let cache = Cache(
                routeKey: routeKey,
                scope: scope,
                runRevision: activity.runRevision,
                runStates: activity.runStates,
                ticketFiles: activity.ticketFiles
            )
            return (snapshot, cache)
        }
        inFlight = InFlight(id: id, bridgeSessionAlive: bridgeSessionAlive, task: task)

        let result = await task.value
        if inFlight?.id == id {
            inFlight = nil
        }
        if self.generation == generation, !task.isCancelled {
            cache = result.1
        }
        return result.0
    }

    func cancel(invalidate: Bool) {
        generation += 1
        inFlight?.task.cancel()
        inFlight = nil
        if invalidate {
            cache = nil
        }
    }

    private static func loadRouteKey(bridgeSessionAlive: Bool) -> RouteKey {
        let socket = URL(fileURLWithPath: "/tmp/voice_bridge.sock")
        let cwd = URL(fileURLWithPath: "/tmp/voice_bridge.cwd")
        let provider = URL(fileURLWithPath: "/tmp/voice_bridge.provider")
        let socketExists = bridgeSessionAlive && FileManager.default.fileExists(atPath: socket.path)
        return RouteKey(
            bridgeSessionAlive: bridgeSessionAlive,
            bridgeSocketExists: socketExists,
            bridgeCwd: socketExists ? readTrimmed(cwd) : nil,
            bridgeProvider: socketExists ? readTrimmed(provider)?.lowercased() : nil
        )
    }

    private static func resolveScope(bridgeSessionAlive: Bool) -> ProjectResolver.WorkspaceScope {
        ProjectResolver.resolveWorkspaceScope(
            bridgeSocket: URL(fileURLWithPath: "/tmp/voice_bridge.sock"),
            bridgeCwdFile: URL(fileURLWithPath: "/tmp/voice_bridge.cwd"),
            bridgeProviderFile: URL(fileURLWithPath: "/tmp/voice_bridge.provider"),
            bridgeSessionAlive: { bridgeSessionAlive }
        )
    }

    private static func loadActivity(
        scope: ProjectResolver.WorkspaceScope,
        previous: Cache?
    ) -> ActivityData {
        let projectURLs = scope.projects.map(\.repoPath)
        let runRevision = RunStateStore.indexURL.flatMap(fileRevision)
        let runStates = previous?.runRevision == runRevision
            ? previous?.runStates ?? []
            : RunStateStore.load(forRepos: projectURLs)

        var ticketFiles: [String: CachedTicket] = [:]
        var tickets: [Ticket] = []
        var ticketsByRunKey: [String: Ticket] = [:]
        for project in scope.projects {
            guard !Task.isCancelled else { break }
            let directory = ProjectResolver.ticketsDirectory(in: project)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            let repoPath = project.repoPath.resolvingSymlinksInPath().path
            for url in entries where url.pathExtension == "md" {
                guard !Task.isCancelled, let revision = fileRevision(url) else { continue }
                let cached: CachedTicket
                if let existing = previous?.ticketFiles[url.path],
                   existing.revision == revision {
                    cached = existing
                } else {
                    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    do {
                        cached = CachedTicket(
                            revision: revision,
                            ticket: try TicketParser.parse(
                                contents: contents,
                                modifiedAt: revision.modifiedAt
                            )
                        )
                    } catch {
                        NSLog("[relay-runner] skipping ticket \(url.lastPathComponent): \(error)")
                        continue
                    }
                }
                ticketFiles[url.path] = cached
                tickets.append(cached.ticket)
                ticketsByRunKey[runKey(repoPath: repoPath, ticketID: cached.ticket.id)] = cached.ticket
            }
        }

        return ActivityData(
            runStates: runStates,
            tickets: tickets,
            ticketsByRunKey: ticketsByRunKey,
            foregroundProviderTurnActive: ProcessManager.foregroundProviderTurnActive(),
            runRevision: runRevision,
            ticketFiles: ticketFiles
        )
    }

    private static func fileRevision(_ url: URL) -> FileRevision? {
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else {
            return nil
        }
        return FileRevision(modifiedAt: values.contentModificationDate, size: values.fileSize)
    }

    private static func readTrimmed(_ url: URL) -> String? {
        guard let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func runKey(repoPath: String, ticketID: String) -> String {
        "\(repoPath)|\(ticketID)"
    }
}
