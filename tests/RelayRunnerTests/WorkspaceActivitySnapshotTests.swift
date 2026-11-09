import XCTest
@testable import relay_runner

final class WorkspaceActivitySnapshotTests: XCTestCase {
    func testRegistryV2ScopeDoesNotLeakLegacyProjects() throws {
        let root = try makeTempDirectory(named: "registry-v2-scope")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let service = ProjectRegistryV2Service(
            store: ProjectRegistryV2Store(appSupportRoot: root),
            validator: ProjectRegistrationValidator(relayWorktreeRoots: []),
            accessGrants: ProjectAccessGrantManager(),
            appSupportRoot: root
        )

        let scope = WorkspaceActivitySnapshotStore.resolveScope(
            bridgeSessionAlive: false,
            registryV2: service
        )

        XCTAssertTrue(scope.projects.isEmpty)
        if case .programBoard = scope.route {
            // Empty registry-v2 is an honest project-management surface.
        } else {
            XCTFail("Registry-v2 must not fall through to the legacy project registry.")
        }
    }

    func testTicketFileRevisionsMoveWhenABoardWriteRewritesATicket() async throws {
        // RR-471: an open Work tab refreshes when these change, instead of
        // waiting up to 10 s for its poll.
        let repo = try makeTempDirectory(named: "board-change")
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let tickets = repo.appendingPathComponent(".orchestrator", isDirectory: true)
        try FileManager.default.createDirectory(at: tickets, withIntermediateDirectories: true)
        let ticket = tickets.appendingPathComponent("RR-1.md")
        func write(title: String, status: String) throws {
            try """
            ---
            id: RR-1
            title: \(title)
            status: \(status)
            priority: medium
            depends_on: []
            run_id: null
            canceled: false
            ---
            ## Description
            One
            """.write(to: ticket, atomically: true, encoding: .utf8)
        }
        try write(title: "First", status: "backlog")
        let project = ProjectResolver.LinkedProject(repoPath: repo)
        let store = WorkspaceActivitySnapshotStore(dependencies: .init(
            routeKey: { alive in
                WorkspaceActivitySnapshotStore.RouteKey(
                    bridgeSessionAlive: alive,
                    bridgeSocketExists: false,
                    bridgeCwd: nil,
                    bridgeProvider: nil
                )
            },
            resolveScope: { _ in
                ProjectResolver.WorkspaceScope(route: .project(project), projects: [project])
            },
            loadActivity: WorkspaceActivitySnapshotStore.loadActivity
        ))

        let first = await store.refresh(bridgeSessionAlive: false).ticketFileRevisions
        let unchanged = await store.refresh(bridgeSessionAlive: false).ticketFileRevisions
        try write(title: "First, edited", status: "ready")
        let edited = await store.refresh(bridgeSessionAlive: false).ticketFileRevisions

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first.keys.first?.hasSuffix("/.orchestrator/RR-1.md") == true)
        XCTAssertEqual(first, unchanged)
        XCTAssertNotEqual(first, edited)
    }

    func testConcurrentConsumersCoalesceRefreshAndReuseRouteClassification() async {
        let routeResolutions = LockedCounter()
        let activityLoads = LockedCounter()
        let mainThreadLoads = LockedCounter()
        let dependencies = WorkspaceActivitySnapshotStore.Dependencies(
            routeKey: { alive in
                if Thread.isMainThread { mainThreadLoads.increment() }
                return WorkspaceActivitySnapshotStore.RouteKey(
                    bridgeSessionAlive: alive,
                    bridgeSocketExists: alive,
                    bridgeCwd: alive ? "/workspace" : nil,
                    bridgeProvider: alive ? "codex" : nil
                )
            },
            resolveScope: { _ in
                if Thread.isMainThread { mainThreadLoads.increment() }
                routeResolutions.increment()
                Thread.sleep(forTimeInterval: 0.05)
                return ProjectResolver.WorkspaceScope(route: .unavailable, projects: [])
            },
            loadActivity: { _, _ in
                if Thread.isMainThread { mainThreadLoads.increment() }
                activityLoads.increment()
                return Self.emptyActivityData
            }
        )
        let store = WorkspaceActivitySnapshotStore(dependencies: dependencies)

        async let notch = store.refresh(bridgeSessionAlive: true)
        async let sleep = store.refresh(bridgeSessionAlive: true)
        _ = await (notch, sleep)

        XCTAssertEqual(routeResolutions.value, 1)
        XCTAssertEqual(activityLoads.value, 1)
        XCTAssertEqual(mainThreadLoads.value, 0)

        _ = await store.refresh(bridgeSessionAlive: true)
        XCTAssertEqual(routeResolutions.value, 1, "Unchanged bridge state must reuse its route.")
        XCTAssertEqual(activityLoads.value, 2, "Activity still polls for run and ticket changes.")

        await store.cancel(invalidate: true)
        _ = await store.refresh(bridgeSessionAlive: true)
        XCTAssertEqual(routeResolutions.value, 2, "Explicit invalidation must prepare a fresh route.")
    }

    func testCachedWorkspaceRoutePreparationStaysBelowFiveMillisecondsP95() {
        let projects = (1...227).map {
            ProjectResolver.LinkedProject(
                repoPath: URL(fileURLWithPath: "/workspace/project-\($0)")
            )
        }
        let paths = projects.map(\.repoPath.path)
        var samples: [Double] = []
        for _ in 0..<100 {
            let start = DispatchTime.now().uptimeNanoseconds
            let opening = ProgramBoardOverlayController.workspaceOpening(
                route: .programBoard,
                initialTab: .work,
                hasTerminalTab: true,
                hasSettingsTab: true,
                hasCachedSnapshot: true,
                activityProjectPaths: paths
            )
            samples.append(milliseconds(since: start))
            XCTAssertEqual(opening?.projectScope.count, projects.count)
        }

        XCTAssertLessThan(percentile(samples, 0.95), 5)
    }

    func testCachedActivityRefreshStaysBelowTwentyFiveMillisecondsP95At227Tickets() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RR242_BENCHMARK"] == "activity")

        let repo = try makeTempDirectory(named: "rr242-activity")
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let ticketsDirectory = repo.appendingPathComponent(".orchestrator", isDirectory: true)
        try FileManager.default.createDirectory(at: ticketsDirectory, withIntermediateDirectories: true)
        for index in 1...227 {
            let body = """
            ---
            id: RR-\(index)
            title: Activity benchmark \(index)
            status: backlog
            priority: medium
            depends_on: []
            run_id: null
            canceled: false
            ---

            ## Description

            Cached activity benchmark.
            """
            try Data(body.utf8).write(
                to: ticketsDirectory.appendingPathComponent("RR-\(index).md")
            )
        }

        let project = ProjectResolver.LinkedProject(repoPath: repo)
        let live = WorkspaceActivitySnapshotStore.Dependencies.live
        let dependencies = WorkspaceActivitySnapshotStore.Dependencies(
            routeKey: { alive in
                WorkspaceActivitySnapshotStore.RouteKey(
                    bridgeSessionAlive: alive,
                    bridgeSocketExists: false,
                    bridgeCwd: nil,
                    bridgeProvider: nil
                )
            },
            resolveScope: { _ in
                ProjectResolver.WorkspaceScope(route: .project(project), projects: [project])
            },
            loadActivity: live.loadActivity
        )
        let store = WorkspaceActivitySnapshotStore(dependencies: dependencies)
        _ = await store.refresh(bridgeSessionAlive: false)

        var samples: [Double] = []
        for _ in 0..<25 {
            let start = DispatchTime.now().uptimeNanoseconds
            let snapshot = await store.refresh(bridgeSessionAlive: false)
            samples.append(milliseconds(since: start))
            XCTAssertEqual(snapshot.tickets.count, 227)
        }

        let p95 = percentile(samples, 0.95)
        print("RR242_ACTIVITY tickets=227 refresh_p95_ms=\(p95)")
        XCTAssertLessThan(p95, 25)
    }

    private static let emptyActivityData = WorkspaceActivitySnapshotStore.ActivityData(
        runStates: [],
        tickets: [],
        ticketsByRunKey: [:],
        foregroundProviderTurnActive: false,
        runRevision: nil,
        ticketFiles: [:]
    )

    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func percentile(_ samples: [Double], _ percentile: Double) -> Double {
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * percentile).rounded(.up)) - 1)
        return sorted[max(0, index)]
    }

    private func makeTempDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
