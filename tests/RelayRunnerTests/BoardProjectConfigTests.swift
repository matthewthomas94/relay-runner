import XCTest
@testable import relay_runner

final class BoardProjectConfigTests: XCTestCase {

    func testDerivesInitialPrefixesForSeparatedRepoNames() {
        XCTAssertEqual(BoardProjectConfig.derivedPrefix(forRepoNamed: "relay-runner"), "RR")
        XCTAssertEqual(BoardProjectConfig.derivedPrefix(forRepoNamed: "mouse-assist"), "MA")
        XCTAssertEqual(BoardProjectConfig.derivedPrefix(forRepoNamed: "mouse_assist"), "MA")
    }

    func testDerivesShortPrefixForSingleWordRepoName() {
        XCTAssertEqual(BoardProjectConfig.derivedPrefix(forRepoNamed: "notebook"), "NO")
    }

    func testEnsureExistsCreatesMissingConfigAndPreservesExistingConfig() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

        try BoardProjectConfig.ensureExists(forRepoAt: repo)
        let configURL = repo.appendingPathComponent(".orchestrator/config.toml")
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), """
        prefix = "MA"
        next_id = 1

        """)

        let custom = """
        prefix = "CUSTOM"
        next_id = 7
        # keep this line

        """
        try Data(custom.utf8).write(to: configURL)

        try BoardProjectConfig.ensureExists(forRepoAt: repo)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), custom)
    }

    func testMintInitializesMouseAssistAndBumpsNextId() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

        let project = ProjectResolver.LinkedProject(repoPath: repo)
        let ticket = try TicketWriter.mint(in: project, status: .backlog, order: 10)

        XCTAssertEqual(ticket.id, "MA-1")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".orchestrator/MA-1.md").path
        ))
        XCTAssertEqual(
            try String(
                contentsOf: repo.appendingPathComponent(".orchestrator/config.toml"),
                encoding: .utf8
            ),
            """
            prefix = "MA"
            next_id = 2

            """
        )
    }

    func testResolveInitializesFreshGitRepoFromBridgeCwd() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(repo.path.utf8).write(to: bridgeCwd)

        let project = ProjectResolver.resolve(bridgeSocket: bridgeSocket, bridgeCwdFile: bridgeCwd)

        XCTAssertEqual(project?.repoPath.path, repo.path)
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
    }

    func testMintRejectsInvalidConfig() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

        let orchDir = repo.appendingPathComponent(".orchestrator", isDirectory: true)
        try FileManager.default.createDirectory(at: orchDir, withIntermediateDirectories: true)
        try Data("prefix = \"\"\nnext_id = 1\n".utf8)
            .write(to: orchDir.appendingPathComponent("config.toml"))

        let project = ProjectResolver.LinkedProject(repoPath: repo)
        XCTAssertThrowsError(try TicketWriter.mint(in: project, status: .backlog, order: 10))
    }

    private func makeTempRepo(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayRunnerTests-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], in: repo)
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
