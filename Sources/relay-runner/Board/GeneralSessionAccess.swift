import Foundation

/// RR-442: a session started from the built-in general-tasks project reaches
/// every registered project. Registry membership is the authority: the launch
/// grants each registered path to the provider and exports one confirmed scope
/// token per registered project. Nothing outside the registry is granted, and
/// the daemon still validates every token per call, unchanged.
struct GeneralSessionAccess: Equatable {
    /// Registered project paths other than the session's own working folder.
    let additionalDirectories: [String]
    /// Confirmed tokens for every registered project, general-tasks included.
    let scopeTokens: [ConfirmedProjectScopeToken]

    static let none = GeneralSessionAccess(additionalDirectories: [], scopeTokens: [])

    var isEmpty: Bool { scopeTokens.isEmpty }

    /// Access for a session bound to `sessionProject`: `.none` unless that is
    /// the general-tasks project, and `.none` when the registry can't be read.
    static func make(registry: ProjectRegistryV2Service, sessionProject: RegisteredProjectV2) -> GeneralSessionAccess {
        guard registry.isGeneralTasksProject(sessionProject),
              let tokens = try? registry.registeredScopeTokens() else { return .none }
        return GeneralSessionAccess(
            additionalDirectories: tokens.map(\.repositoryPath).filter { $0 != sessionProject.lastResolvedPath },
            scopeTokens: tokens
        )
    }

    /// `RELAY_PROJECT_SCOPE_TOKENS`: a JSON object from each registered
    /// repository path to its encoded token.
    var tokensEnvironmentValue: String? {
        var map: [String: String] = [:]
        for token in scopeTokens {
            if let encoded = token.encodedValue { map[token.repositoryPath] = encoded }
        }
        guard !map.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    enum IssueError: Error, CustomStringConvertible, Equatable {
        case notGeneralSession

        var description: String {
            "Project scope tokens are issued only to the general session. Other sessions stay bound to their own project."
        }
    }

    /// Issue a token for one registered project to the general session, for a
    /// project registered after it launched. `reference` is a registered path,
    /// project ID or name; anything outside the registry is refused.
    static func issueToken(
        for reference: String,
        requestingContextID: String?,
        registry: ProjectRegistryV2Service
    ) throws -> ConfirmedProjectScopeToken {
        guard let general = try registry.projects().first(where: registry.isGeneralTasksProject),
              // RR-469: every PM tab of the general session qualifies.
              requestingContextID.map(AssistantSessionContext.baseID) == AssistantSessionContext(
                kind: .project, projectID: general.projectID, repositoryPath: general.lastResolvedPath
              ).id
        else { throw IssueError.notGeneralSession }
        let token = try registry.scopeToken(matching: reference)
        guard registry.validateScopeToken(token).isValid else {
            throw ProjectRegistryV2Service.ServiceError.staleScope(token.projectID)
        }
        return token
    }

    /// Bring the general-tasks project's Claude settings in line with the
    /// registry. No-op when general-tasks is not registered.
    static func syncClaudeSettings(registry: ProjectRegistryV2Service) throws {
        guard let general = try registry.projects().first(where: registry.isGeneralTasksProject) else { return }
        try ClaudeGeneralSettings.sync(
            directories: make(registry: registry, sessionProject: general).additionalDirectories,
            projectRoot: URL(fileURLWithPath: general.lastResolvedPath, isDirectory: true),
            manifest: registry.generalTasksDirectory.deletingLastPathComponent()
                .appendingPathComponent("projects/general-claude-directories.json")
        )
    }
}

/// Claude Code reloads project-local settings while a session runs, including
/// `permissions.additionalDirectories`, so a project registered mid-session
/// becomes readable without a restart. (`--settings` files are not reloaded.)
/// Relay Runner owns only the entries it recorded in `manifest`; the user's own
/// keys and directories in the file are kept.
enum ClaudeGeneralSettings {
    enum SyncError: Error, CustomStringConvertible, Equatable {
        case unreadableSettings(String)

        var description: String {
            switch self {
            case .unreadableSettings(let path):
                return "Claude settings at \(path) are not a JSON object; left unchanged."
            }
        }
    }

    static let excludePattern = "/.claude/settings.local.json"

    static func settingsURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".claude/settings.local.json")
    }

    static func sync(
        directories: [String],
        projectRoot: URL,
        manifest: URL,
        fileManager: FileManager = .default
    ) throws {
        let settingsURL = settingsURL(projectRoot: projectRoot)
        var settings: [String: Any] = [:]
        if fileManager.fileExists(atPath: settingsURL.path) {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] else {
                throw SyncError.unreadableSettings(settingsURL.path)
            }
            settings = object
        }
        let previous = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))) ?? []
        guard settings["permissions"] == nil || settings["permissions"] is [String: Any] else {
            throw SyncError.unreadableSettings(settingsURL.path)
        }
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        guard permissions["additionalDirectories"] == nil || permissions["additionalDirectories"] is [String] else {
            throw SyncError.unreadableSettings(settingsURL.path)
        }
        let existing = permissions["additionalDirectories"] as? [String] ?? []
        var updated = existing.filter { !previous.contains($0) && !directories.contains($0) }
        for directory in directories where !updated.contains(directory) { updated.append(directory) }
        guard updated != existing || previous != directories else { return }

        // Record the union first: an interrupted sync can then only forget
        // entries Relay Runner wrote, never adopt them as the user's.
        try writeManifest(Array(Set(previous).union(directories)).sorted(), to: manifest, fileManager: fileManager)
        if updated != existing {
            if updated.isEmpty {
                permissions.removeValue(forKey: "additionalDirectories")
            } else {
                permissions["additionalDirectories"] = updated
            }
            if permissions.isEmpty {
                settings.removeValue(forKey: "permissions")
            } else {
                settings["permissions"] = permissions
            }
            try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: settingsURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            excludeFromGit(projectRoot: projectRoot, fileManager: fileManager)
        }
        try writeManifest(directories, to: manifest, fileManager: fileManager)
    }

    private static func writeManifest(_ directories: [String], to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(directories).write(to: url, options: .atomic)
    }

    /// Keep the managed file out of the general-tasks repository's commits, so
    /// it stays the user's own untracked local settings.
    private static func excludeFromGit(projectRoot: URL, fileManager: FileManager) {
        let gitDirectory = projectRoot.appendingPathComponent(".git", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let exclude = gitDirectory.appendingPathComponent("info/exclude")
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(where: { $0 == Substring(excludePattern) }) else { return }
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try? fileManager.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((current + separator + excludePattern + "\n").utf8).write(to: exclude, options: .atomic)
    }
}
