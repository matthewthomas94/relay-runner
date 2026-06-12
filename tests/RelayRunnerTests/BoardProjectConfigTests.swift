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

    func testMintDraftWritesOnlyCurrentProjectAndMarksDraft() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = ProjectResolver.LinkedProject(repoPath: repo)
        let ticket = try TicketWriter.mintDraft(
            in: project,
            status: .ready,
            existingTickets: [
                makeTicket(id: "MA-1", status: .ready, order: 10),
                makeTicket(id: "MA-2", status: .backlog, order: 80),
                makeTicket(id: "MA-3", status: .ready, order: 30),
            ]
        )

        let ticketURL = repo.appendingPathComponent(".orchestrator/MA-1.md")
        let contents = try String(contentsOf: ticketURL, encoding: .utf8)
        let parsed = try TicketParser.parse(contents: contents)

        XCTAssertEqual(ticket.id, "MA-1")
        XCTAssertEqual(ticket.status, .ready)
        XCTAssertEqual(ticket.order, 40)
        XCTAssertTrue(ticket.draft)
        XCTAssertEqual(parsed.status, .ready)
        XCTAssertEqual(parsed.order, 40)
        XCTAssertTrue(parsed.draft)
        XCTAssertTrue(contents.contains("\ndraft: true\n"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".orchestrator").path
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

    func testMintDraftClaimsSelectedProjectNextIdWithoutMutatingPeerProject() throws {
        let clientRepo = try makeTempRepo(named: "client-dashboard")
        let root = clientRepo.deletingLastPathComponent()
        let toolsRepo = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsRepo, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], in: toolsRepo)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeConfig(repo: clientRepo, prefix: "CD", nextID: 5)
        try writeConfig(repo: toolsRepo, prefix: "TL", nextID: 11)

        let project = ProjectResolver.LinkedProject(repoPath: clientRepo)
        let ticket = try TicketWriter.mintDraft(
            in: project,
            status: .backlog,
            existingTickets: [
                makeTicket(id: "CD-4", status: .backlog, order: 10),
            ],
            title: "Client ticket"
        )

        XCTAssertEqual(ticket.id, "CD-5")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: clientRepo.appendingPathComponent(".orchestrator/CD-5.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: toolsRepo.appendingPathComponent(".orchestrator/TL-11.md").path
        ))
        XCTAssertEqual(
            try String(
                contentsOf: clientRepo.appendingPathComponent(".orchestrator/config.toml"),
                encoding: .utf8
            ),
            """
            prefix = "CD"
            next_id = 6

            """
        )
        XCTAssertEqual(
            try String(
                contentsOf: toolsRepo.appendingPathComponent(".orchestrator/config.toml"),
                encoding: .utf8
            ),
            """
            prefix = "TL"
            next_id = 11

            """
        )
    }

    func testSavingDraftClearsDraftFlagWhenTicketIsNoLongerDraft() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

        let project = ProjectResolver.LinkedProject(repoPath: repo)
        let draft = try TicketWriter.mintDraft(in: project, status: .ready, existingTickets: [])
        let saved = Ticket(
            id: draft.id,
            title: "Dispatchable work",
            status: draft.status,
            priority: draft.priority,
            dependsOn: draft.dependsOn,
            runId: draft.runId,
            canceled: draft.canceled,
            draft: false,
            order: draft.order,
            description: draft.description,
            body: draft.body
        )

        try TicketWriter.save(saved, in: project)

        let contents = try String(
            contentsOf: repo.appendingPathComponent(".orchestrator/MA-1.md"),
            encoding: .utf8
        )
        XCTAssertFalse(contents.contains("draft:"))
        XCTAssertFalse(try TicketParser.parse(contents: contents).draft)
    }

    func testProjectBoardCreatedDraftCanBeSavedAndDeleted() throws {
        let repo = try makeTempRepo(named: "mouse-assist")
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

        let project = ProjectResolver.LinkedProject(repoPath: repo)
        let draft = try TicketWriter.mintDraft(in: project, status: .backlog, existingTickets: [])
        let editorDraft = TicketDraft(
            editorId: draft.id,
            original: draft,
            isNew: true,
            title: draft.title,
            description: TicketParser.extractFullDescription(draft.body) ?? ""
        )

        XCTAssertTrue(editorDraft.isNew)
        XCTAssertEqual(editorDraft.editorId, "MA-1")
        XCTAssertTrue(editorDraft.original.draft)

        let withDescription = TicketWriter.ticket(
            editorDraft.original,
            withDescription: "Write the project-board ticket."
        )
        let saved = Ticket(
            id: withDescription.id,
            title: "Project-board ticket",
            status: withDescription.status,
            priority: withDescription.priority,
            dependsOn: withDescription.dependsOn,
            runId: withDescription.runId,
            canceled: withDescription.canceled,
            draft: false,
            order: withDescription.order,
            description: withDescription.description,
            body: withDescription.body
        )

        try TicketWriter.save(saved, in: project)

        let savedContents = try String(
            contentsOf: repo.appendingPathComponent(".orchestrator/MA-1.md"),
            encoding: .utf8
        )
        let parsedSaved = try TicketParser.parse(contents: savedContents)
        XCTAssertEqual(parsedSaved.title, "Project-board ticket")
        XCTAssertEqual(parsedSaved.description, "Write the project-board ticket.")
        XCTAssertFalse(parsedSaved.draft)

        let deleteDraft = try TicketWriter.mintDraft(
            in: project,
            status: .backlog,
            existingTickets: [parsedSaved]
        )
        try TicketWriter.delete(deleteDraft.id, in: project)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".orchestrator/\(deleteDraft.id).md").path
        ))
    }

    func testResolveInitializesFreshGitRepoFromBridgeCwd() throws {
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
            registry: makeRegistry(root: root)
        )

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

    func testResolveInitializesUnderscoredGitRepoFromBridgeCwd() throws {
        let repo = try makeTempRepo(named: "client_dashboard")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(repo.path.utf8).write(to: bridgeCwd)

        let project = ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: makeRegistry(root: root)
        )

        XCTAssertEqual(resolvedPath(project?.repoPath), resolvedPath(repo))
        XCTAssertEqual(
            try String(
                contentsOf: repo.appendingPathComponent(".orchestrator/config.toml"),
                encoding: .utf8
            ),
            """
            prefix = "CD"
            next_id = 1

            """
        )
    }

    func testResolvePreservesExistingConfigFromBridgeCwd() throws {
        let repo = try makeTempRepo(named: "client_dashboard")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let orchDir = repo.appendingPathComponent(".orchestrator", isDirectory: true)
        try FileManager.default.createDirectory(at: orchDir, withIntermediateDirectories: true)
        let customConfig = """
        prefix = "CUSTOM"
        next_id = 7

        """
        try Data(customConfig.utf8).write(to: orchDir.appendingPathComponent("config.toml"))

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(repo.path.utf8).write(to: bridgeCwd)

        let project = try XCTUnwrap(ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: makeRegistry(root: root)
        ))
        let ticket = try TicketWriter.mint(in: project, status: .backlog, order: 10)

        XCTAssertEqual(ticket.id, "CUSTOM-7")
        XCTAssertEqual(
            try String(contentsOf: orchDir.appendingPathComponent("config.toml"), encoding: .utf8),
            """
            prefix = "CUSTOM"
            next_id = 8

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

        let project = ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: makeRegistry(root: root)
        )

        XCTAssertEqual(resolvedPath(project?.repoPath), resolvedPath(repo))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: subdirectory.appendingPathComponent(".git").path
        ))
    }

    func testResolveRejectsNonGitBridgeCwdWithoutInitializingIt() throws {
        let directory = try makeTempDirectory(named: "scratch-work")
        let root = directory.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(directory.path.utf8).write(to: bridgeCwd)

        let project = ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: makeRegistry(root: root)
        )

        XCTAssertNil(project)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".git").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".orchestrator").path
        ))
    }

    func testResolveInitializesFallbackPrefixForNonAlphanumericGitRepo() throws {
        let repo = try makeTempRepo(named: "!!!")
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridgeSocket = root.appendingPathComponent("voice_bridge.sock")
        let bridgeCwd = root.appendingPathComponent("voice_bridge.cwd")
        try Data().write(to: bridgeSocket)
        try Data(repo.path.utf8).write(to: bridgeCwd)

        let project = try XCTUnwrap(ProjectResolver.resolve(
            bridgeSocket: bridgeSocket,
            bridgeCwdFile: bridgeCwd,
            registry: makeRegistry(root: root)
        ))
        let ticket = try TicketWriter.mint(in: project, status: .backlog, order: 10)

        XCTAssertEqual(resolvedPath(project.repoPath), resolvedPath(repo))
        XCTAssertEqual(ticket.id, "T-1")
        XCTAssertEqual(
            try String(
                contentsOf: repo.appendingPathComponent(".orchestrator/config.toml"),
                encoding: .utf8
            ),
            """
            prefix = "T"
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
            bridgeSessionAlive: { false },
            registry: makeRegistry(root: root)
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

    private func makeTicket(
        id: String,
        status: Ticket.Status = .backlog,
        order: Int
    ) -> Ticket {
        Ticket(
            id: id,
            title: id,
            status: status,
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

    private func writeConfig(repo: URL, prefix: String, nextID: Int) throws {
        let dir = repo.appendingPathComponent(".orchestrator", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let contents = """
        prefix = "\(prefix)"
        next_id = \(nextID)

        """
        try contents.write(
            to: dir.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeRegistry(root: URL) -> ProjectRegistry {
        ProjectRegistry(fileURL: root.appendingPathComponent("projects.json"))
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
