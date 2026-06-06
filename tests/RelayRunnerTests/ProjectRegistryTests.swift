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
        try runGit(["init", "--quiet"], in: repo)
        return repo
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
