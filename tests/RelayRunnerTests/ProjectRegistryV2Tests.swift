import XCTest
@testable import relay_runner

final class ProjectRegistryV2Tests: XCTestCase {
    func testRegistrationPersistsVersionedMetadataAndKeychainReferenceWithoutBookmarkBytes() throws {
        let root = try makeTempDirectory(named: "registration")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("source", isDirectory: true)
        let symlink = root.appendingPathComponent("selected", isDirectory: true)
        try makeGitRepo(at: repo)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: repo)
        let before = try repositorySnapshot(repo)
        let fixture = makeService(root: root, projectID: "project-001")

        let candidate = try fixture.service.inspect(selectedURL: symlink)
        let project = try fixture.service.register(
            candidate: candidate,
            displayName: "Source",
            remote: ProjectRemoteMetadata(
                mode: .enabled,
                remoteName: "origin",
                artifactRef: "refs/heads/relay/artifacts"
            )
        )

        XCTAssertEqual(project.projectID, "project-001")
        XCTAssertEqual(project.selectedPath, symlink.standardizedFileURL.path)
        XCTAssertEqual(project.lastResolvedPath, repo.resolvingSymlinksInPath().path)
        XCTAssertFalse(project.gitCommonDirectoryFingerprint.isEmpty)
        XCTAssertEqual(project.availability, .available)
        XCTAssertEqual(project.bookmarkReference, .project("project-001"))
        XCTAssertEqual(fixture.grants.storedURLs["project-001"], symlink.standardizedFileURL)

        let load = try fixture.service.load()
        XCTAssertEqual(load.document.schemaVersion, 2)
        XCTAssertEqual(load.document.activeProjectID, "project-001")
        let json = try String(contentsOf: fixture.store.primaryURL, encoding: .utf8)
        XCTAssertTrue(json.contains("\"schema_version\" : 2"))
        XCTAssertTrue(json.contains(ProjectBookmarkReference.service))
        XCTAssertTrue(json.contains("\"account\" : \"project-001\""))
        XCTAssertFalse(json.contains("bookmark_data"))
        XCTAssertFalse(json.contains("security_scoped_bookmark"))
        XCTAssertEqual(try repositorySnapshot(repo), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".orchestrator").path
        ))
    }

    func testAtomicStoreRecoversCorruptPrimaryFromLastKnownGoodBackup() throws {
        let root = try makeTempDirectory(named: "recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let first = document(projectID: "first")
        let second = document(projectID: "second")
        try store.save(first)
        try store.save(second)
        try Data("not-json".utf8).write(to: store.primaryURL)

        let result = try store.load()

        XCTAssertEqual(result.source, .recoveredFromBackup)
        XCTAssertEqual(result.document, first)
        XCTAssertEqual(result.quarantinedFiles.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.quarantinedFiles[0].path))
        XCTAssertEqual(try store.load().document, first)
        XCTAssertEqual(
            try JSONDecoder.registryV2.decode(
                ProjectRegistryV2Document.self,
                from: Data(contentsOf: store.backupURL)
            ),
            first
        )
    }

    func testStoreQuarantinesUnusableCopiesAndTreatsTotalLossAsValidEmptyRegistry() throws {
        let root = try makeTempDirectory(named: "quarantine")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        try FileManager.default.createDirectory(
            at: store.primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("broken-primary".utf8).write(to: store.primaryURL)
        try Data("broken-backup".utf8).write(to: store.backupURL)

        let quarantined = try store.load()

        XCTAssertEqual(quarantined.source, .emptyAfterQuarantine)
        XCTAssertEqual(quarantined.document, .empty)
        XCTAssertEqual(quarantined.quarantinedFiles.count, 2)
        XCTAssertTrue(quarantined.quarantinedFiles.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupURL.path))
        XCTAssertEqual(try store.load().source, .primary)
        XCTAssertEqual(try store.load().document, .empty)

        let lostRoot = try makeTempDirectory(named: "total-loss")
        defer { try? FileManager.default.removeItem(at: lostRoot) }
        let totalLoss = try makeStore(root: lostRoot).load()
        XCTAssertEqual(totalLoss.source, .emptyAfterTotalLoss)
        XCTAssertEqual(totalLoss.document, .empty)
    }

    func testLegacyMigrationIsDeterministicIdempotentAndDoesNotMutateRepositories() throws {
        let root = try makeTempDirectory(named: "migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("legacy", isDirectory: true)
        try makeGitRepo(at: repo)
        try Data("keep\n".utf8).write(to: repo.appendingPathComponent("local.txt"))
        let before = try repositorySnapshot(repo)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let legacyRecord = RegisteredProject(
            id: repo.path,
            repoPath: repo.path,
            alias: "legacy",
            displayName: "Legacy Project",
            lastSeenAt: timestamp,
            lastActivationSource: .programmatic,
            providers: [:]
        )
        let legacy = ProjectRegistryDocument(
            activeProjectID: repo.path,
            activeWorkspaceRootID: nil,
            workspaceRoots: [],
            projects: [legacyRecord]
        )
        let fixture = makeService(root: root, projectID: "unused")

        let first = try fixture.service.migrateLegacy(legacy)
        let firstData = try Data(contentsOf: fixture.store.primaryURL)
        let second = try fixture.service.migrateLegacy(legacy)

        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: fixture.store.primaryURL), firstData)
        let project = try XCTUnwrap(first.projects.first)
        XCTAssertTrue(project.projectID.hasPrefix("legacy-"))
        XCTAssertEqual(first.activeProjectID, project.projectID)
        XCTAssertEqual(project.legacyRecordID, repo.path)
        XCTAssertEqual(project.availability, .accessRequiresRegrant)
        XCTAssertEqual(project.bookmarkReference, .project(project.projectID))
        XCTAssertTrue(fixture.grants.storedURLs.isEmpty)
        XCTAssertEqual(try repositorySnapshot(repo), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".orchestrator").path
        ))
    }

    func testValidationDistinguishesDuplicateLayersAndAcceptsUserWorktrees() throws {
        let root = try makeTempDirectory(named: "duplicates")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("primary", isDirectory: true)
        try makeCommittedGitRepo(at: repo)
        let baseValidator = ProjectRegistrationValidator(relayWorktreeRoots: [])
        let first = try baseValidator.validate(selectedURL: repo, existingProjects: [])
        let existing = record(projectID: "stable-project", candidate: first)

        let exact = try baseValidator.validate(selectedURL: repo, existingProjects: [existing])
        XCTAssertTrue(exact.duplicates.contains(.exactPath(existingProjectID: "stable-project")))
        XCTAssertTrue(exact.duplicates.contains(.gitCommonDirectory(existingProjectID: "stable-project")))

        var resourceOnly = existing
        resourceOnly.selectedPath = root.appendingPathComponent("old-selection").path
        resourceOnly.lastResolvedPath = root.appendingPathComponent("old-resolution").path
        resourceOnly.gitCommonDirectoryFingerprint = "different"
        let fileDuplicate = try baseValidator.validate(
            selectedURL: repo,
            existingProjects: [resourceOnly]
        )
        XCTAssertEqual(fileDuplicate.duplicates, [
            .fileResource(existingProjectID: "stable-project"),
        ])

        let secondRepo = root.appendingPathComponent("clone", isDirectory: true)
        try makeGitRepo(at: secondRepo)
        let identityValidator = ProjectRegistrationValidator(
            relayWorktreeRoots: [],
            committedProjectIDReader: { _ in "stable-project" }
        )
        let projectIDDuplicate = try identityValidator.validate(
            selectedURL: secondRepo,
            existingProjects: [existing]
        )
        XCTAssertTrue(projectIDDuplicate.duplicates.contains(
            .projectID(existingProjectID: "stable-project")
        ))

        let userWorktree = root.appendingPathComponent("user-worktree", isDirectory: true)
        try runGit(["worktree", "add", "-q", "-b", "user-worktree", userWorktree.path], in: repo)
        let worktreeCandidate = try baseValidator.validate(
            selectedURL: userWorktree,
            existingProjects: [existing]
        )
        XCTAssertTrue(worktreeCandidate.isUserWorktree)
        XCTAssertTrue(worktreeCandidate.duplicates.contains(
            .gitCommonDirectory(existingProjectID: "stable-project")
        ))
    }

    func testValidationRejectsBareRepositoriesAndRelayWorkerWorktrees() throws {
        let root = try makeTempDirectory(named: "rejections")
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = root.appendingPathComponent("bare.git", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try runGit(["init", "--bare", "--quiet"], in: bare)
        let validator = ProjectRegistrationValidator(relayWorktreeRoots: [])

        XCTAssertThrowsError(try validator.validate(selectedURL: bare, existingProjects: [])) {
            XCTAssertEqual(
                $0 as? ProjectRegistrationValidator.ValidationError,
                .bareRepository(bare.path)
            )
        }

        let relayRoot = root.appendingPathComponent("app/workspaces", isDirectory: true)
        let relayRepo = relayRoot.appendingPathComponent("rr-281", isDirectory: true)
        try makeGitRepo(at: relayRepo)
        let relayValidator = ProjectRegistrationValidator(relayWorktreeRoots: [relayRoot])
        XCTAssertThrowsError(try relayValidator.validate(
            selectedURL: relayRepo,
            existingProjects: []
        )) {
            XCTAssertEqual(
                $0 as? ProjectRegistrationValidator.ValidationError,
                .relayWorkerWorktree(relayRepo.path)
            )
        }
    }

    func testAvailabilitySurfacesStaleMissingOfflineAndMovedStatesWithoutChangingIdentity() throws {
        let root = try makeTempDirectory(named: "availability")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("project", isDirectory: true)
        try makeGitRepo(at: repo)
        let fixture = makeService(root: root, projectID: "project-availability")
        let candidate = try fixture.service.inspect(selectedURL: repo)
        _ = try fixture.service.register(candidate: candidate, displayName: "Project")

        fixture.grants.resolutions["project-availability"] = .requiresRegrant(
            .stale,
            lastKnownURL: repo
        )
        XCTAssertEqual(
            try fixture.service.refreshAvailability(projectID: "project-availability").availability,
            .accessRequiresRegrant
        )
        XCTAssertEqual(fixture.grants.storeCount, 1, "stale grants must not refresh silently")

        let missing = root.appendingPathComponent("deleted-project", isDirectory: true)
        fixture.grants.resolutions["project-availability"] = .available(missing)
        XCTAssertEqual(
            try fixture.service.refreshAvailability(projectID: "project-availability").availability,
            .missing
        )

        let offline = URL(fileURLWithPath: "/Volumes/RelayRunnerMissing/project", isDirectory: true)
        fixture.grants.resolutions["project-availability"] = .available(offline)
        XCTAssertEqual(
            try fixture.service.refreshAvailability(projectID: "project-availability").availability,
            .offline
        )

        let moved = root.appendingPathComponent("renamed-project", isDirectory: true)
        try FileManager.default.moveItem(at: repo, to: moved)
        fixture.grants.resolutions["project-availability"] = .available(moved)
        let recovered = try fixture.service.refreshAvailability(projectID: "project-availability")
        XCTAssertEqual(recovered.availability, .available)
        XCTAssertEqual(recovered.projectID, "project-availability")
        XCTAssertEqual(recovered.lastResolvedPath, moved.path)
        XCTAssertEqual(recovered.selectedPath, repo.path)
    }

    func testLocateRequiresMatchingIdentityBeforeReplacingGrant() throws {
        let root = try makeTempDirectory(named: "locate")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try makeGitRepo(at: original)
        try makeGitRepo(at: replacement)
        let store = makeStore(root: root)
        let grants = FakeAccessGrantManager()
        let validator = ProjectRegistrationValidator(
            relayWorktreeRoots: [],
            committedProjectIDReader: { url in
                url.lastPathComponent == "replacement" ? "different-project" : nil
            }
        )
        let service = ProjectRegistryV2Service(
            store: store,
            validator: validator,
            accessGrants: grants,
            appSupportRoot: root.appendingPathComponent("app-support"),
            makeProjectID: { "expected-project" }
        )
        _ = try service.register(
            candidate: service.inspect(selectedURL: original),
            displayName: "Expected"
        )

        XCTAssertThrowsError(try service.locate(
            projectID: "expected-project",
            selectedURL: replacement
        )) {
            XCTAssertEqual(
                $0 as? ProjectRegistryV2Service.ServiceError,
                .identityMismatch(expected: "expected-project", found: "different-project")
            )
        }
        XCTAssertEqual(grants.storeCount, 1)
        XCTAssertEqual(try service.load().document.projects.first?.lastResolvedPath, original.path)
    }

    func testRemoveClearsOnlyRelayOwnedStateAndReleasesAccessAfterConfirmation() throws {
        let root = try makeTempDirectory(named: "remove")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("project", isDirectory: true)
        try makeCommittedGitRepo(at: repo)
        let fixture = makeService(root: root, projectID: "project-remove")
        _ = try fixture.service.register(
            candidate: fixture.service.inspect(selectedURL: repo),
            displayName: "Project"
        )
        let cache = fixture.appSupportRoot.appendingPathComponent("caches/project-remove")
        let index = fixture.appSupportRoot.appendingPathComponent("indexes/project-remove")
        let unrelated = fixture.appSupportRoot.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelated)
        let before = try repositorySnapshot(repo)

        XCTAssertThrowsError(try fixture.service.removeProject(
            projectID: "project-remove",
            confirmed: false
        )) {
            XCTAssertEqual($0 as? ProjectRegistryV2Service.ServiceError, .confirmationRequired)
        }
        XCTAssertEqual(try fixture.service.load().document.projects.count, 1)

        try fixture.service.removeProject(projectID: "project-remove", confirmed: true)

        XCTAssertTrue(try fixture.service.load().document.projects.isEmpty)
        XCTAssertEqual(fixture.grants.released, [.project("project-remove")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try repositorySnapshot(repo), before)
    }

    func testRolloutGateIsExplicitReversibleAndKeepsLegacyRegistrySeparate() throws {
        XCTAssertFalse(ProjectRegistryV2Rollout.isEnabled(environment: [:]))
        XCTAssertFalse(ProjectRegistryV2Rollout.isEnabled(environment: [
            ProjectRegistryV2Rollout.environmentKey: "0",
        ]))
        XCTAssertTrue(ProjectRegistryV2Rollout.isEnabled(environment: [
            ProjectRegistryV2Rollout.environmentKey: "true",
        ]))

        let root = try makeTempDirectory(named: "gate")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(ProjectRegistryV2Service.makeIfEnabled(environment: [:], appSupportRoot: root))
        XCTAssertNotNil(ProjectRegistryV2Service.makeIfEnabled(
            environment: [ProjectRegistryV2Rollout.environmentKey: "1"],
            appSupportRoot: root
        ))
        XCTAssertEqual(
            ProjectRegistry(fileURL: root.appendingPathComponent("program/projects.json")).fileURL,
            root.appendingPathComponent("program/projects.json")
        )
        XCTAssertEqual(
            ProjectRegistryV2Store(appSupportRoot: root).primaryURL,
            root.appendingPathComponent("projects/registry-v2.json")
        )
    }

    func testAccessGrantManagerSurfacesStaleAndRevokedBookmarksWithoutSilentRefresh() throws {
        let store = MemoryBookmarkStore()
        let codec = FakeBookmarkCodec()
        let manager = ProjectAccessGrantManager(store: store, codec: codec)
        let reference = try manager.storeGrant(
            for: URL(fileURLWithPath: "/tmp/project"),
            projectID: "project-grant"
        )
        XCTAssertEqual(reference.serviceName, "com.relayrunner.project-bookmark")
        XCTAssertEqual(reference.account, "project-grant")
        XCTAssertEqual(store.storeCount, 1)

        codec.resolvedURL = URL(fileURLWithPath: "/tmp/moved-project")
        codec.isStale = true
        XCTAssertEqual(
            manager.resolveGrant(reference: reference),
            .requiresRegrant(.stale, lastKnownURL: codec.resolvedURL)
        )
        XCTAssertEqual(store.storeCount, 1)

        codec.error = TestError.expected
        XCTAssertEqual(
            manager.resolveGrant(reference: reference),
            .requiresRegrant(.revokedOrUnreadable, lastKnownURL: nil)
        )
    }

    private func makeService(
        root: URL,
        projectID: String
    ) -> (
        service: ProjectRegistryV2Service,
        store: ProjectRegistryV2Store,
        grants: FakeAccessGrantManager,
        appSupportRoot: URL
    ) {
        let appSupportRoot = root.appendingPathComponent("app-support", isDirectory: true)
        let store = makeStore(root: root)
        let grants = FakeAccessGrantManager()
        return (
            ProjectRegistryV2Service(
                store: store,
                validator: ProjectRegistrationValidator(relayWorktreeRoots: []),
                accessGrants: grants,
                appSupportRoot: appSupportRoot,
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                makeProjectID: { projectID }
            ),
            store,
            grants,
            appSupportRoot
        )
    }

    private func makeStore(root: URL) -> ProjectRegistryV2Store {
        let state = root.appendingPathComponent("registry-state", isDirectory: true)
        return ProjectRegistryV2Store(
            primaryURL: state.appendingPathComponent("registry-v2.json"),
            backupURL: state.appendingPathComponent("registry-v2.backup.json"),
            quarantineDirectoryURL: state.appendingPathComponent("quarantine", isDirectory: true),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func document(projectID: String) -> ProjectRegistryV2Document {
        ProjectRegistryV2Document(
            schemaVersion: 2,
            activeProjectID: projectID,
            projects: [RegisteredProjectV2(
                projectID: projectID,
                displayName: projectID,
                selectedPath: "/tmp/\(projectID)",
                lastResolvedPath: "/tmp/\(projectID)",
                fileResourceIdentifier: nil,
                gitCommonDirectoryFingerprint: "fingerprint-\(projectID)",
                worktreeKind: .primary,
                remote: .localOnly,
                availability: .available,
                bookmarkReference: .project(projectID),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastResolvedAt: Date(timeIntervalSince1970: 1_700_000_000),
                legacyRecordID: nil
            )]
        )
    }

    private func record(
        projectID: String,
        candidate: ProjectRegistrationCandidate
    ) -> RegisteredProjectV2 {
        RegisteredProjectV2(
            projectID: projectID,
            displayName: projectID,
            selectedPath: candidate.selectedPath.path,
            lastResolvedPath: candidate.repoPath.path,
            fileResourceIdentifier: candidate.fileResourceIdentifier,
            gitCommonDirectoryFingerprint: candidate.gitCommonDirectoryFingerprint,
            worktreeKind: candidate.isUserWorktree ? .userManaged : .primary,
            remote: .localOnly,
            availability: .available,
            bookmarkReference: .project(projectID),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastResolvedAt: Date(timeIntervalSince1970: 1_700_000_000),
            legacyRecordID: nil
        )
    }

    private struct RepositorySnapshot: Equatable {
        let status: String
        let refs: String
        let remotes: String
        let index: Data?
        let head: Data?
        let config: Data?
        let files: [String: Data]
    }

    private func repositorySnapshot(_ repo: URL) throws -> RepositorySnapshot {
        var files: [String: Data] = [:]
        if let enumerator = FileManager.default.enumerator(
            at: repo,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) {
            for case let url as URL in enumerator {
                let relative = String(url.path.dropFirst(repo.path.count + 1))
                if relative == ".git" {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                files[relative] = try Data(contentsOf: url)
            }
        }
        return RepositorySnapshot(
            status: try runGitOutput(["status", "--porcelain=v1", "--untracked-files=all"], in: repo),
            refs: try runGitOutput(["show-ref"], in: repo, allowedStatuses: [0, 1]),
            remotes: try runGitOutput(["remote", "-v"], in: repo),
            index: try? Data(contentsOf: repo.appendingPathComponent(".git/index")),
            head: try? Data(contentsOf: repo.appendingPathComponent(".git/HEAD")),
            config: try? Data(contentsOf: repo.appendingPathComponent(".git/config")),
            files: files
        )
    }

    private func makeGitRepo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], in: url)
    }

    private func makeCommittedGitRepo(at url: URL) throws {
        try makeGitRepo(at: url)
        try Data("fixture\n".utf8).write(to: url.appendingPathComponent("fixture.txt"))
        try runGit(["add", "fixture.txt"], in: url)
        try runGit([
            "-c", "user.name=Relay Runner Tests",
            "-c", "user.email=relay-runner-tests@example.invalid",
            "commit", "-q", "-m", "fixture",
        ], in: url)
    }

    private func makeTempDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectRegistryV2Tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        _ = try runGitOutput(arguments, in: directory)
    }

    private func runGitOutput(
        _ arguments: [String],
        in directory: URL,
        allowedStatuses: Set<Int32> = [0]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertTrue(allowedStatuses.contains(process.terminationStatus))
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

private final class FakeAccessGrantManager: ProjectAccessGrantManaging {
    var storedURLs: [String: URL] = [:]
    var resolutions: [String: ProjectAccessGrantResolution] = [:]
    var released: [ProjectBookmarkReference] = []
    var storeCount = 0

    func storeGrant(for url: URL, projectID: String) throws -> ProjectBookmarkReference {
        storeCount += 1
        storedURLs[projectID] = url
        resolutions[projectID] = .available(url)
        return .project(projectID)
    }

    func resolveGrant(reference: ProjectBookmarkReference) -> ProjectAccessGrantResolution {
        resolutions[reference.account] ?? .requiresRegrant(.missing, lastKnownURL: nil)
    }

    func releaseGrant(reference: ProjectBookmarkReference) throws {
        released.append(reference)
        storedURLs.removeValue(forKey: reference.account)
        resolutions.removeValue(forKey: reference.account)
    }
}

private final class MemoryBookmarkStore: ProjectBookmarkStoring {
    var values: [ProjectBookmarkReference: Data] = [:]
    var storeCount = 0

    func store(_ data: Data, reference: ProjectBookmarkReference) throws {
        storeCount += 1
        values[reference] = data
    }

    func load(reference: ProjectBookmarkReference) throws -> Data? {
        values[reference]
    }

    func remove(reference: ProjectBookmarkReference) throws {
        values.removeValue(forKey: reference)
    }
}

private final class FakeBookmarkCodec: ProjectBookmarkCoding {
    var resolvedURL = URL(fileURLWithPath: "/tmp/project")
    var isStale = false
    var error: Error?

    func makeBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        if let error { throw error }
        return (resolvedURL, isStale)
    }
}

private enum TestError: Error {
    case expected
}

private extension JSONDecoder {
    static var registryV2: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
