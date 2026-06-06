import Foundation

enum ProjectActivationSource: String, Codable, Equatable {
    case bridgeCwd = "bridge_cwd"
    case discovery
    case programmatic
}

struct ProjectProviderMetadata: Codable, Equatable {
    var lastActivatedAt: Date
    var lastActivationSource: ProjectActivationSource
}

struct RegisteredProject: Codable, Equatable {
    var id: String
    var repoPath: String
    var alias: String
    var displayName: String
    var lastSeenAt: Date
    var lastActivationSource: ProjectActivationSource
    var providers: [String: ProjectProviderMetadata]
}

struct RegisteredWorkspaceRoot: Codable, Equatable {
    var id: String
    var rootPath: String
    var displayName: String
    var lastSeenAt: Date
    var discoveredProjectIDs: [String]
    var providers: [String: ProjectProviderMetadata]
}

struct ProjectRegistryDocument: Codable, Equatable {
    var activeProjectID: String?
    var activeWorkspaceRootID: String?
    var workspaceRoots: [RegisteredWorkspaceRoot]
    var projects: [RegisteredProject]

    static let empty = ProjectRegistryDocument(
        activeProjectID: nil,
        activeWorkspaceRootID: nil,
        workspaceRoots: [],
        projects: []
    )

    private enum CodingKeys: String, CodingKey {
        case activeProjectID
        case activeWorkspaceRootID
        case workspaceRoots
        case projects
    }

    init(
        activeProjectID: String?,
        activeWorkspaceRootID: String?,
        workspaceRoots: [RegisteredWorkspaceRoot],
        projects: [RegisteredProject]
    ) {
        self.activeProjectID = activeProjectID
        self.activeWorkspaceRootID = activeWorkspaceRootID
        self.workspaceRoots = workspaceRoots
        self.projects = projects
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activeProjectID = try values.decodeIfPresent(String.self, forKey: .activeProjectID)
        activeWorkspaceRootID = try values.decodeIfPresent(String.self, forKey: .activeWorkspaceRootID)
        workspaceRoots = try values.decodeIfPresent([RegisteredWorkspaceRoot].self, forKey: .workspaceRoots) ?? []
        projects = try values.decodeIfPresent([RegisteredProject].self, forKey: .projects) ?? []
    }
}

enum ProjectDiscoveryClassification: Equatable {
    case workspaceRoot(rootPath: URL, childRepoPaths: [URL])
    case singleProject(repoPath: URL)
}

struct ProjectRegistry {
    let fileURL: URL
    private let now: () -> Date

    init(fileURL: URL = ProjectRegistry.defaultFileURL(), now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
    }

    @discardableResult
    func activateProject(
        at path: URL,
        alias: String? = nil,
        provider: String? = nil,
        source: ProjectActivationSource = .programmatic
    ) throws -> ProjectResolver.LinkedProject {
        let repoURL = try resolveGitRepo(containing: path)
        try BoardProjectConfig.ensureExists(forRepoAt: repoURL)
        try registerResolvedProject(repoURL: repoURL, alias: alias, provider: provider, source: source)
        return ProjectResolver.LinkedProject(repoPath: repoURL)
    }

    @discardableResult
    func registerDiscovery(at path: URL, provider: String? = nil) throws -> ProjectDiscoveryClassification {
        let classification = try classifyDiscoveryRoot(at: path)
        switch classification {
        case .workspaceRoot(let rootURL, let childRepoURLs):
            try registerWorkspaceRoot(rootURL: rootURL, childRepoURLs: childRepoURLs, provider: provider)
        case .singleProject(let repoURL):
            try BoardProjectConfig.ensureExists(forRepoAt: repoURL)
            try registerResolvedProject(
                repoURL: repoURL,
                alias: nil,
                provider: provider,
                source: .programmatic
            )
        }
        return classification
    }

    func classifyDiscoveryRoot(at path: URL) throws -> ProjectDiscoveryClassification {
        let directory = try existingDirectory(path)
        let childRepoURLs = try childGitRepos(under: directory)
        if !childRepoURLs.isEmpty {
            return .workspaceRoot(rootPath: directory, childRepoPaths: childRepoURLs)
        }

        if let repoURL = try gitRepoRoot(containing: directory) {
            return .singleProject(repoPath: repoURL)
        }

        throw ActivationError.noProjectsFound(path: directory.path)
    }

    @discardableResult
    func activateProject(
        matching pathOrAlias: String,
        provider: String? = nil,
        source: ProjectActivationSource = .programmatic
    ) throws -> ProjectResolver.LinkedProject {
        let query = pathOrAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ActivationError.emptyProjectReference }

        let document = try load()
        if let existing = document.projects.first(where: { matchesAlias($0, query: query) }) {
            return try activateProject(
                at: URL(fileURLWithPath: existing.repoPath),
                alias: existing.alias,
                provider: provider,
                source: source
            )
        }

        return try activateProject(
            at: Self.fileURL(fromProjectReference: query),
            provider: provider,
            source: source
        )
    }

    func load() throws -> ProjectRegistryDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: fileURL)
        return try Self.decoder.decode(ProjectRegistryDocument.self, from: data)
    }

    func activeProject(allowBridgeCwdActivation: Bool = false) throws -> ProjectResolver.LinkedProject? {
        let document = try load()
        guard let activeProjectID = document.activeProjectID,
              let record = document.projects.first(where: { $0.id == activeProjectID }) else {
            return nil
        }
        guard allowBridgeCwdActivation || record.lastActivationSource == .programmatic else {
            return nil
        }

        let repoURL = try resolveGitRepo(containing: URL(fileURLWithPath: record.repoPath))
        try BoardProjectConfig.ensureExists(forRepoAt: repoURL)
        return ProjectResolver.LinkedProject(repoPath: repoURL)
    }

    static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )

        return appSupport
            .appendingPathComponent("relay-runner", isDirectory: true)
            .appendingPathComponent("program", isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    private func registerResolvedProject(
        repoURL: URL,
        alias: String?,
        provider: String?,
        source: ProjectActivationSource
    ) throws {
        var document = try load()
        let timestamp = now()
        upsertProject(
            in: &document,
            repoURL: repoURL,
            alias: alias,
            provider: provider,
            source: source,
            activate: true,
            preserveActivationSource: false,
            timestamp: timestamp
        )
        try save(document)
    }

    private func registerWorkspaceRoot(
        rootURL: URL,
        childRepoURLs: [URL],
        provider: String?
    ) throws {
        var document = try load()
        let timestamp = now()
        let childProjectIDs = childRepoURLs.map(\.path).sorted()

        for childRepoURL in childRepoURLs {
            upsertProject(
                in: &document,
                repoURL: childRepoURL,
                alias: nil,
                provider: nil,
                source: .discovery,
                activate: false,
                preserveActivationSource: true,
                timestamp: timestamp
            )
        }

        let id = rootURL.path
        let existing = document.workspaceRoots.first(where: { $0.id == id })
        var record = existing ?? RegisteredWorkspaceRoot(
            id: id,
            rootPath: rootURL.path,
            displayName: rootURL.lastPathComponent,
            lastSeenAt: timestamp,
            discoveredProjectIDs: childProjectIDs,
            providers: [:]
        )
        record.rootPath = rootURL.path
        record.displayName = rootURL.lastPathComponent
        record.lastSeenAt = timestamp
        record.discoveredProjectIDs = childProjectIDs

        if let providerKey = normalizedProvider(provider) {
            // Workspace roots and projects share provider-neutral metadata so
            // Codex and Claude resolve the same registry state.
            record.providers[providerKey] = ProjectProviderMetadata(
                lastActivatedAt: timestamp,
                lastActivationSource: .discovery
            )
        }

        document.workspaceRoots.removeAll { $0.id == id }
        document.workspaceRoots.append(record)
        document.workspaceRoots.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        document.activeWorkspaceRootID = id
        document.activeProjectID = nil
        try save(document)
    }

    private func upsertProject(
        in document: inout ProjectRegistryDocument,
        repoURL: URL,
        alias: String?,
        provider: String?,
        source: ProjectActivationSource,
        activate: Bool,
        preserveActivationSource: Bool,
        timestamp: Date
    ) {
        let id = repoURL.path
        let providerKey = normalizedProvider(provider)
        let existing = document.projects.first(where: { $0.id == id })
        let normalizedAlias = normalizedProjectAlias(alias) ?? existing?.alias ?? repoURL.lastPathComponent

        var record = existing ?? RegisteredProject(
            id: id,
            repoPath: repoURL.path,
            alias: normalizedAlias,
            displayName: normalizedAlias,
            lastSeenAt: timestamp,
            lastActivationSource: source,
            providers: [:]
        )

        record.repoPath = repoURL.path
        record.alias = normalizedAlias
        record.displayName = normalizedAlias
        record.lastSeenAt = timestamp
        if !preserveActivationSource || existing == nil {
            record.lastActivationSource = source
        }
        if let providerKey {
            // Codex and Claude both use this provider-neutral shape; callers
            // pass the provider label when known instead of using separate
            // activation models for each agent runtime.
            record.providers[providerKey] = ProjectProviderMetadata(
                lastActivatedAt: timestamp,
                lastActivationSource: source
            )
        }

        document.projects.removeAll { $0.id == id }
        document.projects.append(record)
        document.projects.sort { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
        if activate {
            document.activeProjectID = id
            document.activeWorkspaceRootID = nil
        }
    }

    private func save(_ document: ProjectRegistryDocument) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }

    private func resolveGitRepo(containing url: URL) throws -> URL {
        let directory = try existingDirectory(url)
        guard let repoURL = try gitRepoRoot(containing: directory) else {
            throw ActivationError.notGitRepository(path: directory.path)
        }
        return repoURL
    }

    private func existingDirectory(_ url: URL) throws -> URL {
        let directory = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ActivationError.notDirectory(path: directory.path)
        }
        return directory
    }

    private func gitRepoRoot(containing url: URL) throws -> URL? {
        let directory = try existingDirectory(url)
        let result = try runGit(["rev-parse", "--show-toplevel"], in: directory)
        guard result.status == 0 else { return nil }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func childGitRepos(under url: URL) throws -> [URL] {
        let directory = try existingDirectory(url)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var seen = Set<String>()
        var repos: [URL] = []

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let repoURL = try gitRepoRoot(containing: entry),
                  repoURL.path == entry.standardizedFileURL.resolvingSymlinksInPath().path,
                  seen.insert(repoURL.path).inserted else {
                continue
            }
            repos.append(repoURL)
        }

        return repos.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func runGit(_ arguments: [String], in directory: URL) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func normalizedProjectAlias(_ alias: String?) -> String? {
        guard let value = alias?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func normalizedProvider(_ provider: String?) -> String? {
        guard let value = provider?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private func matchesAlias(_ project: RegisteredProject, query: String) -> Bool {
        project.alias.caseInsensitiveCompare(query) == .orderedSame ||
            project.displayName.caseInsensitiveCompare(query) == .orderedSame
    }

    private static func fileURL(fromProjectReference value: String) -> URL {
        if value == "~" {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        if value.hasPrefix("~/") {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(String(value.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    enum ActivationError: Error, CustomStringConvertible, Equatable {
        case emptyProjectReference
        case notDirectory(path: String)
        case notGitRepository(path: String)
        case noProjectsFound(path: String)

        var description: String {
            switch self {
            case .emptyProjectReference:
                return "project activation requires a repo path or known alias"
            case .notDirectory(let path):
                return "project activation path is not a directory: \(path)"
            case .notGitRepository(let path):
                return "project activation refused for non-git directory: \(path). Initialize git explicitly before activating it."
            case .noProjectsFound(let path):
                return "workspace discovery found no child git repositories at \(path). Select a git repo, choose a workspace folder containing git repos, or initialize git explicitly."
            }
        }
    }
}
