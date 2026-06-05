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

        XCTAssertEqual(resolvedPath(project?.repoPath), resolvedPath(repo))
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

    func testResolveUsesExistingRepoRootWhenBridgeStartsInSubdirectory() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let subdirectory = repo.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(subdirectory.path.utf8).write(to: bridgeCwd)

        let project = ProjectResolver.resolve(bridgeSocket: bridgeSocket, bridgeCwdFile: bridgeCwd)

        XCTAssertEqual(resolvedPath(project?.repoPath), resolvedPath(repo))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: subdirectory.appendingPathComponent(".git").path
        ))
    }

    func testResolveInitializesNonGitBridgeCwdAndCanMintTickets() throws {
        let repo = try makeTempDirectory(named: "scratch-work")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(repo.path.utf8).write(to: bridgeCwd)

        let project = try XCTUnwrap(ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd
        ))

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".git").path
        ))
        XCTAssertEqual(
            try String(
                contentsOf: repo.appendingPathComponent(".orchestrator/config.toml"),
                encoding: .utf8
            ),
            """
            prefix = "SW"
            next_id = 1

            """
        )

        let ticket = try TicketWriter.mint(in: project, status: .ready, order: 10)
        XCTAssertEqual(ticket.id, "SW-1")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".orchestrator/SW-1.md").path
        ))
        XCTAssertEqual(
            try String(
                contentsOf: repo.appendingPathComponent(".orchestrator/config.toml"),
                encoding: .utf8
            ),
            """
            prefix = "SW"
            next_id = 2

            """
        )
    }

    func testResolveRejectsUnhealthyBridgeSession() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(repo.path.utf8).write(to: bridgeCwd)

        let project = ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            bridgeSessionAlive: { false }
        )

        XCTAssertNil(project)
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

    func testTicketNewestFirstSortsByNumericIdDescending() {
        let tickets = [
            makeTicket(id: "RR-1", order: 30),
            makeTicket(id: "RR-30", order: 10),
            makeTicket(id: "RR-2", order: 20),
        ]

        XCTAssertEqual(tickets.sorted(by: Ticket.newestFirst).map(\.id), ["RR-30", "RR-2", "RR-1"])
    }

    private func makeTicket(id: String, order: Int) -> Ticket {
        Ticket(
            id: id,
            title: id,
            status: .backlog,
            priority: .medium,
            dependsOn: [],
            runId: nil,
            canceled: false,
            order: order,
            description: nil,
            body: ""
        )
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
