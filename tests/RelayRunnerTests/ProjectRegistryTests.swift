import XCTest
@testable import relay_runner

final class ProjectRegistryTests: XCTestCase {

    func testExplicitActivationRegistersExistingRepoAndInitializesBoard() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let registry = ProjectRegistry(
            fileURL: root.appendingPathComponent("projects.json"),
            now: { timestamp }
        )

        let project = try ProjectResolver.activateProject(
            at: repo,
            alias: "Mouse Assist",
            provider: "codex",
            registry: registry
        )

        XCTAssertEqual(resolvedPath(project.repoPath), resolvedPath(repo))
        XCTAssertEqual(
            try String(
                contentsOf: repo.appendingPathComponent(".orchestrator/config.toml"),
                encoding: .utf8
            ),
            """
            prefix = "MA"
            next_id = 1

            """
        )

        let document = try registry.load()
        let record = try XCTUnwrap(document.projects.first)
        XCTAssertEqual(document.activeProjectID, record.id)
        XCTAssertEqual(record.id, resolvedPath(repo))
        XCTAssertEqual(record.repoPath, resolvedPath(repo))
        XCTAssertEqual(record.alias, "Mouse Assist")
        XCTAssertEqual(record.displayName, "Mouse Assist")
        XCTAssertEqual(record.lastSeenAt, timestamp)
        XCTAssertEqual(record.lastActivationSource, .programmatic)
        XCTAssertEqual(record.providers["codex"]?.lastActivatedAt, timestamp)
        XCTAssertEqual(record.providers["codex"]?.lastActivationSource, .programmatic)
    }

    func testProgrammaticActivationResolvesKnownAliasAndUsesProviderNeutralMetadata() throws {
        let repo = try makeTempRepo(named: "client-dashboard")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var timestamp = firstTimestamp
        let registry = ProjectRegistry(
            fileURL: root.appendingPathComponent("projects.json"),
            now: { timestamp }
        )

        _ = try ProjectResolver.activateProject(
            at: repo,
            alias: "client",
            provider: "codex",
            registry: registry
        )

        timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        let project = try ProjectResolver.activateProject(
            matching: "CLIENT",
            provider: "Claude",
            registry: registry
        )

        XCTAssertEqual(resolvedPath(project.repoPath), resolvedPath(repo))

        let record = try XCTUnwrap(try registry.load().projects.first)
        XCTAssertEqual(record.alias, "client")
        XCTAssertEqual(record.providers["codex"]?.lastActivatedAt, firstTimestamp)
        XCTAssertEqual(record.providers["codex"]?.lastActivationSource, .programmatic)
        XCTAssertEqual(record.providers["claude"]?.lastActivatedAt, timestamp)
        XCTAssertEqual(record.providers["claude"]?.lastActivationSource, .programmatic)
    }

    func testBridgeResolveRegistersAndActivatesExistingRepo() throws {
        let repo = try makeTempRepo(named: "relay-runner")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(repo.path.utf8).write(to: bridgeCwd)

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let registry = ProjectRegistry(
            fileURL: root.appendingPathComponent("projects.json"),
            now: { timestamp }
        )

        let project = ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: registry
        )

        XCTAssertEqual(resolvedPath(project?.repoPath), resolvedPath(repo))
        let record = try XCTUnwrap(try registry.load().projects.first)
        XCTAssertEqual(record.alias, "relay-runner")
        XCTAssertEqual(record.lastSeenAt, timestamp)
        XCTAssertEqual(record.lastActivationSource, .bridgeCwd)
        XCTAssertTrue(record.providers.isEmpty)
    }

    func testBridgeResolvePreservesExistingAlias() throws {
        let repo = try makeTempRepo(named: "client-dashboard")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))
        _ = try ProjectResolver.activateProject(
            at: repo,
            alias: "client",
            provider: "codex",
            registry: registry
        )

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(repo.path.utf8).write(to: bridgeCwd)

        let project = ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: registry
        )

        XCTAssertEqual(resolvedPath(project?.repoPath), resolvedPath(repo))
        let record = try XCTUnwrap(try registry.load().projects.first)
        XCTAssertEqual(record.alias, "client")
        XCTAssertNotNil(record.providers["codex"])
        XCTAssertEqual(record.lastActivationSource, .bridgeCwd)
    }

    func testBridgeResolveRecordsProviderMetadataForCodexAndClaude() throws {
        let repo = try makeTempRepo(named: "client-dashboard")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        let bridgeProvider = root.appendingPathComponent("voice_bridge.provider")
        try Data().write(to: bridgeSocket)
        try Data(repo.path.utf8).write(to: bridgeCwd)

        var timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let registry = ProjectRegistry(
            fileURL: root.appendingPathComponent("projects.json"),
            now: { timestamp }
        )

        try Data("codex\n".utf8).write(to: bridgeProvider)
        XCTAssertNotNil(ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            bridgeProviderFile: bridgeProvider,
            registry: registry
        ))

        timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        try Data("Claude\n".utf8).write(to: bridgeProvider)
        XCTAssertNotNil(ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            bridgeProviderFile: bridgeProvider,
            registry: registry
        ))

        let record = try XCTUnwrap(try registry.load().projects.first)
        XCTAssertEqual(record.providers["codex"]?.lastActivationSource, .bridgeCwd)
        XCTAssertEqual(record.providers["codex"]?.lastActivatedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(record.providers["claude"]?.lastActivationSource, .bridgeCwd)
        XCTAssertEqual(record.providers["claude"]?.lastActivatedAt, Date(timeIntervalSince1970: 1_700_000_060))
    }

    func testBridgeResolveClassifiesWorkspaceRootWithoutCreatingParentBoard() throws {
        let workspace = try makeTempDirectory(named: "dev")
        let root = workspace.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let clientRepo = workspace.appendingPathComponent("client-dashboard", isDirectory: true)
        let toolsRepo = workspace.appendingPathComponent("tools", isDirectory: true)
        try makeGitRepo(at: clientRepo)
        try makeGitRepo(at: toolsRepo)

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        let bridgeProvider = root.appendingPathComponent("voice_bridge.provider")
        try Data().write(to: bridgeSocket)
        try Data(workspace.path.utf8).write(to: bridgeCwd)
        try Data("codex\n".utf8).write(to: bridgeProvider)

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))
        let project = ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            bridgeProviderFile: bridgeProvider,
            registry: registry
        )

        XCTAssertNil(project)
        let document = try registry.load()
        XCTAssertNil(document.activeProjectID)
        XCTAssertEqual(document.activeWorkspaceRootID, resolvedPath(workspace))
        XCTAssertEqual(document.workspaceRoots.first?.providers["codex"]?.lastActivationSource, .bridgeCwd)
        XCTAssertEqual(document.projects.map(\.repoPath), [
            resolvedPath(clientRepo) ?? clientRepo.path,
            resolvedPath(toolsRepo) ?? toolsRepo.path,
        ])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".orchestrator").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: clientRepo.appendingPathComponent(".orchestrator").path
        ))
    }

    func testBoardRouteOpensProjectBoardForSingleProjectBridgeSession() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(repo.path.utf8).write(to: bridgeCwd)

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))
        let route = ProjectResolver.resolveBoardRoute(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: registry
        )

        guard case .project(let project) = route else {
            return XCTFail("Expected project board route.")
        }
        XCTAssertEqual(resolvedPath(project.repoPath), resolvedPath(repo))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".orchestrator/config.toml").path
        ))
    }

    func testBoardRouteOpensProgramBoardForWorkspaceBridgeSession() throws {
        let workspace = try makeTempDirectory(named: "dev")
        let root = workspace.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let clientRepo = workspace.appendingPathComponent("client-dashboard", isDirectory: true)
        let toolsRepo = workspace.appendingPathComponent("tools", isDirectory: true)
        try makeGitRepo(at: clientRepo)
        try makeGitRepo(at: toolsRepo)

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        let bridgeProvider = root.appendingPathComponent("voice_bridge.provider")
        try Data().write(to: bridgeSocket)
        try Data(workspace.path.utf8).write(to: bridgeCwd)

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))
        for provider in ["codex", "Claude"] {
            try Data("\(provider)\n".utf8).write(to: bridgeProvider)
            let route = ProjectResolver.resolveBoardRoute(
                bridgeSocket: bridgeSocket,
                bridgeCwdFile: bridgeCwd,
                bridgeProviderFile: bridgeProvider,
                registry: registry
            )
            guard case .programBoard = route else {
                return XCTFail("Expected Program Board route for \(provider).")
            }
        }

        let document = try registry.load()
        XCTAssertEqual(document.activeWorkspaceRootID, resolvedPath(workspace))
        XCTAssertEqual(document.workspaceRoots.first?.providers["codex"]?.lastActivationSource, .bridgeCwd)
        XCTAssertEqual(document.workspaceRoots.first?.providers["claude"]?.lastActivationSource, .bridgeCwd)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".orchestrator").path
        ))
    }

    func testBoardRoutePrefersWorkspaceRootForAmbiguousParentRepo() throws {
        let parentRepo = try makeTempRepo(named: "platform")
        let root = parentRepo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let childRepo = parentRepo.appendingPathComponent("client-dashboard", isDirectory: true)
        try makeGitRepo(at: childRepo)

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(parentRepo.path.utf8).write(to: bridgeCwd)

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))
        let route = ProjectResolver.resolveBoardRoute(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: registry
        )

        guard case .programBoard = route else {
            return XCTFail("Expected ambiguous parent repo to route to Program Board.")
        }
        let document = try registry.load()
        XCTAssertEqual(document.activeWorkspaceRootID, resolvedPath(parentRepo))
        XCTAssertNil(document.projects.first { $0.repoPath == resolvedPath(parentRepo) })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: parentRepo.appendingPathComponent(".orchestrator").path
        ))
    }

    func testExplicitParentProjectActivationCanOpenProjectBoard() throws {
        let parentRepo = try makeTempRepo(named: "platform")
        let root = parentRepo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let childRepo = parentRepo.appendingPathComponent("client-dashboard", isDirectory: true)
        try makeGitRepo(at: childRepo)

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))
        _ = try registry.registerDiscovery(at: parentRepo, provider: "codex")
        _ = try ProjectResolver.activateProject(
            at: parentRepo,
            alias: "platform",
            provider: "Claude",
            registry: registry
        )
        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(parentRepo.path.utf8).write(to: bridgeCwd)

        let route = ProjectResolver.resolveBoardRoute(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: registry
        )

        guard case .project(let project) = route else {
            return XCTFail("Expected explicit parent project activation to route to project board.")
        }
        XCTAssertEqual(resolvedPath(project.repoPath), resolvedPath(parentRepo))
        let document = try registry.load()
        XCTAssertEqual(document.activeProjectID, resolvedPath(parentRepo))
        XCTAssertNil(document.activeWorkspaceRootID)
        XCTAssertEqual(document.projects.first { $0.repoPath == resolvedPath(parentRepo) }?.providers["claude"]?.lastActivationSource, .programmatic)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: parentRepo.appendingPathComponent(".orchestrator/config.toml").path
        ))
    }

    func testResolveUsesProgrammaticallyActiveProjectWithoutBridge() throws {
        let repo = try makeTempRepo(named: "client-dashboard")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))
        _ = try ProjectResolver.activateProject(
            at: repo,
            alias: "client",
            provider: "claude",
            registry: registry
        )

        let project = ProjectResolver.resolve(
            bridgeSocket: root.appendingPathComponent("missing.sock"),
            bridgeCwdFile: root.appendingPathComponent("missing.cwd"),
            registry: registry
        )

        XCTAssertEqual(resolvedPath(project?.repoPath), resolvedPath(repo))
    }

    func testResolveDoesNotUseBridgeOnlyActivationAfterBridgeIsUnavailable() throws {
        let repo = try makeTempRepo(named: "client-dashboard")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))
        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(repo.path.utf8).write(to: bridgeCwd)

        XCTAssertNotNil(ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: registry
        ))
        try FileManager.default.removeItem(at: bridgeSocket)

        let project = ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: registry
        )

        XCTAssertNil(project)
    }

    func testDiscoveryRegistersNonGitWorkspaceChildrenWithoutWorkspaceProject() throws {
        let workspace = try makeTempDirectory(named: "dev")
        let root = workspace.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let clientRepo = workspace.appendingPathComponent("client-dashboard", isDirectory: true)
        let toolsRepo = workspace.appendingPathComponent("tools", isDirectory: true)
        try makeGitRepo(at: clientRepo)
        try makeGitRepo(at: toolsRepo)

        var timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let registry = ProjectRegistry(
            fileURL: root.appendingPathComponent("projects.json"),
            now: { timestamp }
        )

        let classification = try registry.registerDiscovery(at: workspace, provider: "Codex")
        guard case .workspaceRoot(let rootPath, let childRepoPaths) = classification else {
            return XCTFail("Expected workspace-root discovery.")
        }
        XCTAssertEqual(resolvedPath(rootPath), resolvedPath(workspace))
        XCTAssertEqual(childRepoPaths.map { resolvedPath($0) }, [
            resolvedPath(clientRepo),
            resolvedPath(toolsRepo),
        ])

        timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        _ = try registry.registerDiscovery(at: workspace, provider: "Claude")

        let document = try registry.load()
        XCTAssertNil(document.activeProjectID)
        XCTAssertEqual(document.activeWorkspaceRootID, resolvedPath(workspace))
        let workspaceRecord = try XCTUnwrap(document.workspaceRoots.first)
        XCTAssertEqual(workspaceRecord.rootPath, resolvedPath(workspace))
        XCTAssertEqual(workspaceRecord.discoveredProjectIDs, [
            resolvedPath(clientRepo) ?? clientRepo.path,
            resolvedPath(toolsRepo) ?? toolsRepo.path,
        ])
        XCTAssertEqual(workspaceRecord.providers["codex"]?.lastActivationSource, .discovery)
        XCTAssertEqual(workspaceRecord.providers["claude"]?.lastActivationSource, .discovery)
        XCTAssertEqual(document.projects.map(\.repoPath), [
            resolvedPath(clientRepo) ?? clientRepo.path,
            resolvedPath(toolsRepo) ?? toolsRepo.path,
        ])
        XCTAssertTrue(document.projects.allSatisfy { $0.lastActivationSource == .discovery })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".orchestrator").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: clientRepo.appendingPathComponent(".orchestrator").path
        ))
    }

    func testDiscoveryTreatsSingleGitRepoAsActiveProject() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let registry = ProjectRegistry(
            fileURL: root.appendingPathComponent("projects.json"),
            now: { timestamp }
        )

        let classification = try registry.registerDiscovery(at: repo, provider: "Claude")
        guard case .singleProject(let repoPath) = classification else {
            return XCTFail("Expected single-project discovery.")
        }

        XCTAssertEqual(resolvedPath(repoPath), resolvedPath(repo))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".orchestrator/config.toml").path
        ))

        let document = try registry.load()
        XCTAssertNil(document.activeWorkspaceRootID)
        let record = try XCTUnwrap(document.projects.first)
        XCTAssertEqual(document.activeProjectID, record.id)
        XCTAssertEqual(record.repoPath, resolvedPath(repo))
        XCTAssertEqual(record.lastSeenAt, timestamp)
        XCTAssertEqual(record.lastActivationSource, .programmatic)
        XCTAssertEqual(record.providers["claude"]?.lastActivationSource, .programmatic)
        XCTAssertTrue(document.workspaceRoots.isEmpty)
    }

    func testDiscoveryTreatsGitRepoWithChildReposAsWorkspaceRoot() throws {
        let parentRepo = try makeTempRepo(named: "platform")
        let root = parentRepo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let childRepo = parentRepo.appendingPathComponent("client-dashboard", isDirectory: true)
        try makeGitRepo(at: childRepo)

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))

        let classification = try registry.registerDiscovery(at: parentRepo, provider: "codex")
        guard case .workspaceRoot(let rootPath, let childRepoPaths) = classification else {
            return XCTFail("Expected parent repo to be classified as a workspace root.")
        }

        XCTAssertEqual(resolvedPath(rootPath), resolvedPath(parentRepo))
        XCTAssertEqual(childRepoPaths.map { resolvedPath($0) }, [resolvedPath(childRepo)])

        let document = try registry.load()
        XCTAssertNil(document.activeProjectID)
        XCTAssertEqual(document.activeWorkspaceRootID, resolvedPath(parentRepo))
        XCTAssertEqual(document.workspaceRoots.first?.rootPath, resolvedPath(parentRepo))
        XCTAssertEqual(document.projects.map(\.repoPath), [resolvedPath(childRepo) ?? childRepo.path])
        XCTAssertNil(document.projects.first { $0.repoPath == resolvedPath(parentRepo) })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: parentRepo.appendingPathComponent(".orchestrator").path
        ))
    }

    func testDiscoveryRejectsNonGitFolderWithNoProjectsWithoutInitializingIt() throws {
        let directory = try makeTempDirectory(named: "scratch-work")
        let root = directory.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))

        XCTAssertThrowsError(try registry.registerDiscovery(at: directory, provider: "codex")) { error in
            XCTAssertEqual(
                error as? ProjectRegistry.ActivationError,
                .noProjectsFound(path: resolvedPath(directory) ?? directory.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".git").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".orchestrator").path
        ))
        XCTAssertEqual(try registry.load(), .empty)
    }

    func testWorkspaceFolderRefreshDiscoversConfiguredWorkingDirectoryForBothProviders() throws {
        let workspace = try makeTempDirectory(named: "dev")
        let root = workspace.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let clientRepo = workspace.appendingPathComponent("client-dashboard", isDirectory: true)
        let toolsRepo = workspace.appendingPathComponent("tools", isDirectory: true)
        try makeGitRepo(at: clientRepo)
        try makeGitRepo(at: toolsRepo)

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))
        var config = GeneralConfig()
        config.provider = .codex
        config.working_directory = workspace.path

        let codexClassification = try WorkspaceFolder.refreshDiscovery(for: config, registry: registry)
        guard case .workspaceRoot(let rootPath, let childRepoPaths) = codexClassification else {
            return XCTFail("Expected configured workspace folder to discover child repos.")
        }
        XCTAssertEqual(resolvedPath(rootPath), resolvedPath(workspace))
        XCTAssertEqual(childRepoPaths.map { resolvedPath($0) }, [
            resolvedPath(clientRepo),
            resolvedPath(toolsRepo),
        ])

        config.provider = .claude
        _ = try WorkspaceFolder.refreshDiscovery(for: config, registry: registry)

        let document = try registry.load()
        XCTAssertNil(document.activeProjectID)
        XCTAssertEqual(document.activeWorkspaceRootID, resolvedPath(workspace))
        let workspaceRecord = try XCTUnwrap(document.workspaceRoots.first)
        XCTAssertEqual(workspaceRecord.providers["codex"]?.lastActivationSource, .discovery)
        XCTAssertEqual(workspaceRecord.providers["claude"]?.lastActivationSource, .discovery)
        XCTAssertEqual(document.projects.map(\.repoPath), [
            resolvedPath(clientRepo) ?? clientRepo.path,
            resolvedPath(toolsRepo) ?? toolsRepo.path,
        ])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".orchestrator").path
        ))
    }

    func testWorkspaceFolderRefreshMigratesLegacySingleRepoWorkingDirectory() throws {
        let repo = try makeTempRepo(named: "relay-runner")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))
        var config = GeneralConfig()
        config.provider = .claude
        config.working_directory = repo.path

        let classification = try WorkspaceFolder.refreshDiscovery(for: config, registry: registry)
        guard case .singleProject(let repoPath) = classification else {
            return XCTFail("Expected legacy single-repo working_directory to activate one project.")
        }

        XCTAssertEqual(resolvedPath(repoPath), resolvedPath(repo))
        let document = try registry.load()
        XCTAssertNil(document.activeWorkspaceRootID)
        let record = try XCTUnwrap(document.projects.first)
        XCTAssertEqual(document.activeProjectID, record.id)
        XCTAssertEqual(record.providers["claude"]?.lastActivationSource, .programmatic)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".orchestrator/config.toml").path
        ))
    }

    func testActivationRejectsNonGitFolderWithoutInitializingIt() throws {
        let directory = try makeTempDirectory(named: "scratch-work")
        let root = directory.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))

        XCTAssertThrowsError(try ProjectResolver.activateProject(
            at: directory,
            provider: "claude",
            registry: registry
        )) { error in
            XCTAssertEqual(
                error as? ProjectRegistry.ActivationError,
                .notGitRepository(path: resolvedPath(directory) ?? directory.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".git").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".orchestrator").path
        ))
        XCTAssertEqual(try registry.load(), .empty)
    }

    private func resolvedPath(_ url: URL?) -> String? {
        url?.resolvingSymlinksInPath().path
    }

    private func makeTempRepo(named name: String) throws -> URL {
        let repo = try makeTempDirectory(named: name)
        try makeGitRepo(at: repo)
        return repo
    }

    private func makeGitRepo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], in: url)
    }

    private func makeTempDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayRunnerTests-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        return repo
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
