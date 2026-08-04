import Foundation

enum ProjectRegistrationDuplicate: Equatable {
    case exactPath(existingProjectID: String)
    case fileResource(existingProjectID: String)
    case gitCommonDirectory(existingProjectID: String)
    case projectID(existingProjectID: String)

    var existingProjectID: String {
        switch self {
        case .exactPath(let projectID),
             .fileResource(let projectID),
             .gitCommonDirectory(let projectID),
             .projectID(let projectID):
            return projectID
        }
    }
}

struct ProjectRegistrationCandidate: Equatable {
    let selectedPath: URL
    let repoPath: URL
    let fileResourceIdentifier: String?
    let gitCommonDirectoryFingerprint: String
    let committedProjectID: String?
    let isUserWorktree: Bool
    let duplicates: [ProjectRegistrationDuplicate]
}

struct ProjectRegistrationValidator {
    enum ValidationError: Error, CustomStringConvertible, Equatable {
        case pathUnavailable(String)
        case notGitRepository(String)
        case bareRepository(String)
        case relayWorkerWorktree(String)

        var description: String {
            switch self {
            case .pathUnavailable(let path):
                return "project path is unavailable: \(path)"
            case .notGitRepository(let path):
                return "project path is not a Git worktree: \(path)"
            case .bareRepository(let path):
                return "bare repositories cannot be registered as active projects: \(path)"
            case .relayWorkerWorktree(let path):
                return "Relay-created worker worktrees cannot be registered: \(path)"
            }
        }
    }

    private let relayWorktreeRoots: [URL]
    private let committedProjectIDReader: ((URL) -> String?)?

    init(
        relayWorktreeRoots: [URL] = ProjectRegistrationValidator.defaultRelayWorktreeRoots(),
        committedProjectIDReader: ((URL) -> String?)? = nil
    ) {
        self.relayWorktreeRoots = relayWorktreeRoots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        self.committedProjectIDReader = committedProjectIDReader
    }

    func validate(
        selectedURL: URL,
        existingProjects: [RegisteredProjectV2]
    ) throws -> ProjectRegistrationCandidate {
        let selectedPath = selectedURL.standardizedFileURL
        let canonicalSelection = selectedPath.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonicalSelection.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ValidationError.pathUnavailable(selectedPath.path)
        }

        let bareResult = try runGit(["rev-parse", "--is-bare-repository"], in: canonicalSelection)
        guard bareResult.status == 0 else {
            throw ValidationError.notGitRepository(selectedPath.path)
        }
        guard bareResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != "true" else {
            throw ValidationError.bareRepository(selectedPath.path)
        }

        let topLevelResult = try runGit(["rev-parse", "--show-toplevel"], in: canonicalSelection)
        guard topLevelResult.status == 0 else {
            throw ValidationError.notGitRepository(selectedPath.path)
        }
        let topLevelPath = topLevelResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topLevelPath.isEmpty else {
            throw ValidationError.notGitRepository(selectedPath.path)
        }
        let repoURL = URL(fileURLWithPath: topLevelPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        if relayWorktreeRoots.contains(where: { Self.isDescendant(repoURL, of: $0) }) {
            throw ValidationError.relayWorkerWorktree(repoURL.path)
        }

        let commonDirectory = try gitDirectory(
            arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            fallbackArguments: ["rev-parse", "--git-common-dir"],
            repoURL: repoURL
        )
        let gitDirectory = try gitDirectory(
            arguments: ["rev-parse", "--path-format=absolute", "--git-dir"],
            fallbackArguments: ["rev-parse", "--git-dir"],
            repoURL: repoURL
        )
        let commonFingerprint = Self.fingerprint(for: commonDirectory)
        let resourceIdentifier = Self.fileResourceIdentifier(for: repoURL)
        let committedProjectID = committedProjectIDReader?(repoURL)
            ?? readCommittedProjectID(repoURL: repoURL)

        var duplicates: [ProjectRegistrationDuplicate] = []
        for project in existingProjects {
            let existingSelected = URL(fileURLWithPath: project.selectedPath).standardizedFileURL
            let existingResolved = URL(fileURLWithPath: project.lastResolvedPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            if existingSelected.path == selectedPath.path || existingResolved.path == repoURL.path {
                duplicates.append(.exactPath(existingProjectID: project.projectID))
            } else if let resourceIdentifier,
                      resourceIdentifier == project.fileResourceIdentifier {
                duplicates.append(.fileResource(existingProjectID: project.projectID))
            }
            if commonFingerprint == project.gitCommonDirectoryFingerprint {
                duplicates.append(.gitCommonDirectory(existingProjectID: project.projectID))
            }
            if let committedProjectID, committedProjectID == project.projectID {
                duplicates.append(.projectID(existingProjectID: project.projectID))
            }
        }

        return ProjectRegistrationCandidate(
            selectedPath: selectedPath,
            repoPath: repoURL,
            fileResourceIdentifier: resourceIdentifier,
            gitCommonDirectoryFingerprint: commonFingerprint,
            committedProjectID: committedProjectID,
            isUserWorktree: commonDirectory.path != gitDirectory.path,
            duplicates: duplicates
        )
    }

    static func defaultRelayWorktreeRoots(
        appSupportRoot: URL = ProjectRegistryV2Store.defaultAppSupportRoot()
    ) -> [URL] {
        [
            appSupportRoot.appendingPathComponent("workspaces", isDirectory: true),
            appSupportRoot
                .appendingPathComponent("orchestrator", isDirectory: true)
                .appendingPathComponent("workspaces", isDirectory: true),
        ]
    }

    static func fingerprint(for url: URL) -> String {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resourceID = fileResourceIdentifier(for: canonicalURL) ?? canonicalURL.path
        return "git-common-v1:\(stableDigest(resourceID))"
    }

    static func stableDigest(_ value: String) -> String {
        func fnv1a(seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            return hash
        }
        return String(format: "%016llx%016llx", fnv1a(seed: 14_695_981_039_346_656_037), fnv1a(seed: 7_803_984_711_994_572_071))
    }

    private func gitDirectory(
        arguments: [String],
        fallbackArguments: [String],
        repoURL: URL
    ) throws -> URL {
        var result = try runGit(arguments, in: repoURL)
        if result.status != 0 {
            result = try runGit(fallbackArguments, in: repoURL)
        }
        guard result.status == 0 else {
            throw ValidationError.notGitRepository(repoURL.path)
        }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            url = repoURL.appendingPathComponent(path, isDirectory: true)
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func readCommittedProjectID(repoURL: URL) -> String? {
        let candidates = [
            ".orchestrator/config.toml",
            ".orchestrator/project.toml",
        ]
        for path in candidates {
            guard let result = try? runGit(
                ["show", "refs/heads/relay/artifacts:\(path)"],
                in: repoURL
            ), result.status == 0 else {
                continue
            }
            for line in result.stdout.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard parts.count == 2, parts[0] == "project_id" else { continue }
                let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private func runGit(
        _ arguments: [String],
        in directory: URL
    ) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private static func fileResourceIdentifier(for url: URL) -> String? {
        guard let identifier = try? url.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier else {
            return nil
        }
        return String(describing: identifier)
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath == rootPath || candidatePath.hasPrefix(prefix)
    }
}

final class ProjectRegistryV2Service {
    enum ServiceError: Error, CustomStringConvertible, Equatable {
        case duplicate(ProjectRegistrationDuplicate)
        case invalidBookmarkReference(ProjectBookmarkReference)
        case invalidProjectID(String)
        case projectNotFound(String)
        case identityMismatch(expected: String, found: String?)
        case confirmationRequired

        var description: String {
            switch self {
            case .duplicate(let duplicate):
                return "project registration duplicates \(duplicate.existingProjectID)"
            case .invalidBookmarkReference(let reference):
                return "project access grant used an invalid bookmark reference: \(reference.account)"
            case .invalidProjectID(let projectID):
                return "invalid project ID: \(projectID)"
            case .projectNotFound(let projectID):
                return "registered project not found: \(projectID)"
            case .identityMismatch(let expected, let found):
                return "project identity mismatch; expected \(expected), found \(found ?? "none")"
            case .confirmationRequired:
                return "removing a project requires explicit confirmation"
            }
        }
    }

    private let store: ProjectRegistryV2Store
    private let validator: ProjectRegistrationValidator
    private let accessGrants: ProjectAccessGrantManaging
    private let appSupportRoot: URL
    private let now: () -> Date
    private let makeProjectID: () -> String
    private let fileManager: FileManager

    init(
        store: ProjectRegistryV2Store,
        validator: ProjectRegistrationValidator,
        accessGrants: ProjectAccessGrantManaging,
        appSupportRoot: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeProjectID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.validator = validator
        self.accessGrants = accessGrants
        self.appSupportRoot = appSupportRoot
        self.fileManager = fileManager
        self.now = now
        self.makeProjectID = makeProjectID
    }

    static func makeIfEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appSupportRoot: URL = ProjectRegistryV2Store.defaultAppSupportRoot()
    ) -> ProjectRegistryV2Service? {
        guard ProjectRegistryV2Rollout.isEnabled(environment: environment) else { return nil }
        return ProjectRegistryV2Service(
            store: ProjectRegistryV2Store(appSupportRoot: appSupportRoot),
            validator: ProjectRegistrationValidator(
                relayWorktreeRoots: ProjectRegistrationValidator.defaultRelayWorktreeRoots(
                    appSupportRoot: appSupportRoot
                )
            ),
            accessGrants: ProjectAccessGrantManager(),
            appSupportRoot: appSupportRoot
        )
    }

    func load() throws -> ProjectRegistryV2Store.LoadResult {
        try store.load()
    }

    func inspect(selectedURL: URL) throws -> ProjectRegistrationCandidate {
        let document = try store.load().document
        return try validator.validate(selectedURL: selectedURL, existingProjects: document.projects)
    }

    @discardableResult
    func register(
        candidate: ProjectRegistrationCandidate,
        displayName: String,
        remote: ProjectRemoteMetadata = .localOnly
    ) throws -> RegisteredProjectV2 {
        var document = try store.load().document
        let candidate = try validator.validate(
            selectedURL: candidate.selectedPath,
            existingProjects: document.projects
        )
        if let duplicate = candidate.duplicates.first {
            throw ServiceError.duplicate(duplicate)
        }
        let projectID = candidate.committedProjectID ?? makeProjectID()
        guard ProjectRegistryV2Identity.isValid(projectID) else {
            throw ServiceError.invalidProjectID(projectID)
        }

        if document.projects.contains(where: { $0.projectID == projectID }) {
            throw ServiceError.duplicate(.projectID(existingProjectID: projectID))
        }

        let timestamp = now()
        let reference = try accessGrants.storeGrant(
            for: candidate.selectedPath,
            projectID: projectID
        )
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = RegisteredProjectV2(
            projectID: projectID,
            displayName: normalizedDisplayName.isEmpty
                ? candidate.repoPath.lastPathComponent
                : normalizedDisplayName,
            selectedPath: candidate.selectedPath.path,
            lastResolvedPath: candidate.repoPath.path,
            fileResourceIdentifier: candidate.fileResourceIdentifier,
            gitCommonDirectoryFingerprint: candidate.gitCommonDirectoryFingerprint,
            worktreeKind: candidate.isUserWorktree ? .userManaged : .primary,
            remote: remote,
            availability: .available,
            bookmarkReference: reference,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastResolvedAt: timestamp,
            legacyRecordID: nil
        )
        document.projects.append(record)
        document.projects.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        document.activeProjectID = projectID
        do {
            try store.save(document)
        } catch {
            try? accessGrants.releaseGrant(reference: reference)
            throw error
        }
        return record
    }

    @discardableResult
    func locate(projectID: String, selectedURL: URL) throws -> RegisteredProjectV2 {
        var document = try store.load().document
        guard let index = document.projects.firstIndex(where: { $0.projectID == projectID }) else {
            throw ServiceError.projectNotFound(projectID)
        }
        let original = document.projects[index]
        let candidate = try validator.validate(selectedURL: selectedURL, existingProjects: document.projects)
        if let duplicate = candidate.duplicates.first(where: { $0.existingProjectID != projectID }) {
            throw ServiceError.duplicate(duplicate)
        }
        if let committedProjectID = candidate.committedProjectID,
           committedProjectID != projectID {
            throw ServiceError.identityMismatch(expected: projectID, found: committedProjectID)
        }
        if candidate.committedProjectID == nil,
           candidate.gitCommonDirectoryFingerprint != original.gitCommonDirectoryFingerprint {
            throw ServiceError.identityMismatch(expected: projectID, found: nil)
        }

        let reference = try accessGrants.storeGrant(for: candidate.selectedPath, projectID: projectID)
        guard reference == document.projects[index].bookmarkReference else {
            try? accessGrants.releaseGrant(reference: reference)
            throw ServiceError.invalidBookmarkReference(reference)
        }
        let timestamp = now()
        document.projects[index].selectedPath = candidate.selectedPath.path
        document.projects[index].lastResolvedPath = candidate.repoPath.path
        document.projects[index].fileResourceIdentifier = candidate.fileResourceIdentifier
        document.projects[index].gitCommonDirectoryFingerprint = candidate.gitCommonDirectoryFingerprint
        document.projects[index].worktreeKind = candidate.isUserWorktree ? .userManaged : .primary
        document.projects[index].availability = .available
        document.projects[index].updatedAt = timestamp
        document.projects[index].lastResolvedAt = timestamp
        try store.save(document)
        return document.projects[index]
    }

    @discardableResult
    func refreshAvailability(projectID: String) throws -> RegisteredProjectV2 {
        var document = try store.load().document
        guard let index = document.projects.firstIndex(where: { $0.projectID == projectID }) else {
            throw ServiceError.projectNotFound(projectID)
        }
        var project = document.projects[index]
        let resolution = accessGrants.resolveGrant(reference: project.bookmarkReference)
        let newAvailability: RegisteredProjectAvailability

        switch resolution {
        case .requiresRegrant:
            newAvailability = .accessRequiresRegrant
        case .available(let url):
            var isDirectory: ObjCBool = false
            if !fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                newAvailability = Self.isVolumeAvailable(for: url, fileManager: fileManager)
                    ? .missing
                    : .offline
            } else if let candidate = try? validator.validate(
                selectedURL: url,
                existingProjects: document.projects
            ) {
                let committedIDMatches = candidate.committedProjectID == projectID
                let commonDirectoryMatches = candidate.gitCommonDirectoryFingerprint
                    == project.gitCommonDirectoryFingerprint
                if !committedIDMatches && !commonDirectoryMatches {
                    newAvailability = .identityMismatch
                } else {
                    newAvailability = .available
                    project.lastResolvedPath = candidate.repoPath.path
                    project.fileResourceIdentifier = candidate.fileResourceIdentifier
                    project.gitCommonDirectoryFingerprint = candidate.gitCommonDirectoryFingerprint
                    project.lastResolvedAt = now()
                }
            } else {
                newAvailability = .identityMismatch
            }
        }

        if project.availability != newAvailability || project != document.projects[index] {
            project.availability = newAvailability
            project.updatedAt = now()
            document.projects[index] = project
            try store.save(document)
        }
        return project
    }

    @discardableResult
    func migrateLegacy(_ legacy: ProjectRegistryDocument) throws -> ProjectRegistryV2Document {
        var document = try store.load().document
        let original = document
        var activeProjectIDByLegacyID: [String: String] = [:]

        for legacyProject in legacy.projects.sorted(by: { $0.id < $1.id }) {
            if let existing = document.projects.first(where: { $0.legacyRecordID == legacyProject.id }) {
                activeProjectIDByLegacyID[legacyProject.id] = existing.projectID
                continue
            }

            let selectedURL = URL(fileURLWithPath: legacyProject.repoPath, isDirectory: true)
            let candidate = try? validator.validate(
                selectedURL: selectedURL,
                existingProjects: document.projects
            )
            let committedProjectID = candidate?.committedProjectID
            let projectID: String
            if let committedProjectID, ProjectRegistryV2Identity.isValid(committedProjectID) {
                projectID = committedProjectID
            } else {
                projectID = "legacy-\(ProjectRegistrationValidator.stableDigest(legacyProject.id))"
            }
            if let existing = document.projects.first(where: { $0.projectID == projectID }) {
                activeProjectIDByLegacyID[legacyProject.id] = existing.projectID
                continue
            }

            let timestamp = legacyProject.lastSeenAt
            let record = RegisteredProjectV2(
                projectID: projectID,
                displayName: legacyProject.displayName,
                selectedPath: legacyProject.repoPath,
                lastResolvedPath: candidate?.repoPath.path ?? legacyProject.repoPath,
                fileResourceIdentifier: candidate?.fileResourceIdentifier,
                gitCommonDirectoryFingerprint: candidate?.gitCommonDirectoryFingerprint
                    ?? "legacy-path-v1:\(ProjectRegistrationValidator.stableDigest(legacyProject.repoPath))",
                worktreeKind: candidate?.isUserWorktree == true ? .userManaged : .primary,
                remote: .localOnly,
                availability: candidate == nil ? .missing : .accessRequiresRegrant,
                bookmarkReference: .project(projectID),
                createdAt: timestamp,
                updatedAt: timestamp,
                lastResolvedAt: candidate == nil ? nil : timestamp,
                legacyRecordID: legacyProject.id
            )
            document.projects.append(record)
            activeProjectIDByLegacyID[legacyProject.id] = projectID
        }

        document.projects.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        if let legacyActiveID = legacy.activeProjectID {
            document.activeProjectID = activeProjectIDByLegacyID[legacyActiveID]
        }
        if document != original {
            try store.save(document)
        }
        return document
    }

    func removeProject(projectID: String, confirmed: Bool) throws {
        guard confirmed else { throw ServiceError.confirmationRequired }
        guard ProjectRegistryV2Identity.isValid(projectID) else {
            throw ServiceError.invalidProjectID(projectID)
        }
        var document = try store.load().document
        guard let project = document.projects.first(where: { $0.projectID == projectID }) else {
            throw ServiceError.projectNotFound(projectID)
        }
        document.projects.removeAll { $0.projectID == projectID }
        if document.activeProjectID == projectID {
            document.activeProjectID = nil
        }
        try store.save(document)
        try accessGrants.releaseGrant(reference: project.bookmarkReference)

        for directory in ["indexes", "caches"] {
            let target = appSupportRoot
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(projectID, isDirectory: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }
    }

    private static func isVolumeAvailable(for url: URL, fileManager: FileManager) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            let volumeRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
                .appendingPathComponent(components[2], isDirectory: true)
            return fileManager.fileExists(atPath: volumeRoot.path)
        }
        return fileManager.fileExists(atPath: "/")
    }
}
