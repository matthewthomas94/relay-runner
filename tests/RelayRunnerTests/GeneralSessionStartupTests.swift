import XCTest
@testable import relay_runner

final class GeneralSessionStartupTests: XCTestCase {
    func testFreshStartUsesBuiltInProjectForBothProvidersWithoutGitHub() throws {
        for provider in GeneralConfig.AgentProvider.allCases {
            let root = try temporaryDirectory()
            let registry = makeRegistry(root: root)
            var config = AppConfig()
            config.general.provider = provider
            config.general.working_directory = "/stale/unrelated-repository"

            let first = try AppState.prepareSessionContext(workingDirectory: nil, registry: registry)
            let second = try AppState.prepareSessionContext(workingDirectory: nil, registry: registry)
            let launch = AppState.sessionLaunchRequest(from: config, workingDirectory: first.workingDirectory)

            XCTAssertFalse(first.context.isGeneral)
            XCTAssertEqual(first.context, second.context)
            XCTAssertEqual(first.context.displayName, "general-tasks")
            XCTAssertEqual(first.workingDirectory, registry.generalTasksDirectory.resolvingSymlinksInPath().path)
            XCTAssertTrue(registry.validateScopeToken(try XCTUnwrap(first.projectScopeToken)).isValid)
            XCTAssertEqual(try registry.projects().count, 1)
            XCTAssertEqual(try registry.projects().first?.remote.mode, .localOnly)
            XCTAssertEqual(launch.config.general.provider, provider)
            XCTAssertEqual(launch.config.general.working_directory, first.workingDirectory)
            XCTAssertEqual(config.general.working_directory, "/stale/unrelated-repository")
            let permissions = try FileManager.default.attributesOfItem(atPath: first.workingDirectory)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o700)
        }
    }

    func testDefaultStartPreservesFilesAndExplicitProjectSelection() throws {
        let root = try temporaryDirectory()
        let registry = makeRegistry(root: root)
        let otherURL = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
        let other = try registry.registerExistingProject(at: otherURL)
        _ = try registry.confirmProject(projectID: other.projectID)
        let first = try AppState.prepareSessionContext(workingDirectory: nil, registry: registry)
        let draft = URL(fileURLWithPath: first.workingDirectory).appendingPathComponent("draft.txt")
        try Data("keep my draft\n".utf8).write(to: draft)

        let selected = try AppState.prepareSessionContext(workingDirectory: other.lastResolvedPath, registry: registry)
        let repeated = try AppState.prepareSessionContext(workingDirectory: nil, registry: registry)

        XCTAssertEqual(selected.context.projectID, other.projectID)
        XCTAssertEqual(selected.workingDirectory, other.lastResolvedPath)
        XCTAssertEqual(repeated.context, first.context)
        XCTAssertEqual(try registry.load().document.activeProjectID, other.projectID)
        XCTAssertEqual(try Data(contentsOf: draft), Data("keep my draft\n".utf8))
        XCTAssertEqual(try registry.projects().count, 2)
    }

    func testUnavailableBuiltInFolderFailsWithoutFallingBackToAnotherProject() throws {
        let root = try temporaryDirectory()
        let registry = makeRegistry(root: root)
        let folder = registry.generalTasksDirectory
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = Data("preserve this file\n".utf8)
        try content.write(to: folder)

        XCTAssertThrowsError(try AppState.prepareSessionContext(workingDirectory: nil, registry: registry))
        XCTAssertEqual(try Data(contentsOf: folder), content)
        XCTAssertTrue(try registry.projects().isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-general-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeRegistry(root: URL) -> ProjectRegistryV2Service {
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        return ProjectRegistryV2Service(
            store: ProjectRegistryV2Store(appSupportRoot: appSupport),
            validator: ProjectRegistrationValidator(relayWorktreeRoots: []),
            accessGrants: StartupAccessGrantStore(),
            appSupportRoot: appSupport
        )
    }
}

private final class StartupAccessGrantStore: ProjectAccessGrantManaging {
    private var urls: [String: URL] = [:]
    func storeGrant(for url: URL, projectID: String) throws -> ProjectBookmarkReference {
        urls[projectID] = url
        return .project(projectID)
    }
    func resolveGrant(reference: ProjectBookmarkReference) -> ProjectAccessGrantResolution {
        urls[reference.account].map(ProjectAccessGrantResolution.available)
            ?? .requiresRegrant(.missing, lastKnownURL: nil)
    }
    func releaseGrant(reference: ProjectBookmarkReference) throws { urls.removeValue(forKey: reference.account) }
}
