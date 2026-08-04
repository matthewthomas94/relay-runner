import Foundation
import Security

enum ProjectRegistryV2Rollout {
    static let environmentKey = "RELAY_RUNNER_REGISTRY_V2"

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let value = environment[environmentKey]?.lowercased() else { return false }
        return ["1", "true", "yes", "enabled"].contains(value)
    }
}

enum ProjectRemoteSyncMode: String, Codable, Equatable {
    case enabled
    case localOnly = "local_only"
    case paused
}

struct ProjectRemoteMetadata: Codable, Equatable {
    var mode: ProjectRemoteSyncMode
    var remoteName: String?
    var artifactRef: String

    static let localOnly = ProjectRemoteMetadata(
        mode: .localOnly,
        remoteName: nil,
        artifactRef: "refs/heads/relay/artifacts"
    )
}

enum RegisteredProjectAvailability: String, Codable, Equatable {
    case available
    case missing
    case offline
    case accessRequiresRegrant = "access_requires_regrant"
    case identityMismatch = "identity_mismatch"
}

enum RegisteredProjectWorktreeKind: String, Codable, Equatable {
    case primary
    case userManaged = "user_managed"
}

struct ProjectBookmarkReference: Codable, Equatable, Hashable {
    static let service = "com.relayrunner.project-bookmark"

    let serviceName: String
    let account: String

    static func project(_ projectID: String) -> ProjectBookmarkReference {
        ProjectBookmarkReference(serviceName: service, account: projectID)
    }
}

struct RegisteredProjectV2: Codable, Equatable {
    let projectID: String
    var displayName: String
    var selectedPath: String
    var lastResolvedPath: String
    var fileResourceIdentifier: String?
    var gitCommonDirectoryFingerprint: String
    var worktreeKind: RegisteredProjectWorktreeKind
    var remote: ProjectRemoteMetadata
    var availability: RegisteredProjectAvailability
    let bookmarkReference: ProjectBookmarkReference
    let createdAt: Date
    var updatedAt: Date
    var lastResolvedAt: Date?
    var legacyRecordID: String?

    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case displayName = "display_name"
        case selectedPath = "selected_path"
        case lastResolvedPath = "last_resolved_path"
        case fileResourceIdentifier = "file_resource_identifier"
        case gitCommonDirectoryFingerprint = "git_common_directory_fingerprint"
        case worktreeKind = "worktree_kind"
        case remote
        case availability
        case bookmarkReference = "bookmark_reference"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastResolvedAt = "last_resolved_at"
        case legacyRecordID = "legacy_record_id"
    }
}

struct ProjectRegistryV2Document: Codable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var activeProjectID: String?
    var projects: [RegisteredProjectV2]

    static let empty = ProjectRegistryV2Document(
        schemaVersion: currentSchemaVersion,
        activeProjectID: nil,
        projects: []
    )

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case activeProjectID = "active_project_id"
        case projects
    }
}

enum ProjectRegistryV2Identity {
    static func isValid(_ projectID: String) -> Bool {
        guard !projectID.isEmpty,
              projectID.count <= 128,
              projectID != ".",
              projectID != ".." else {
            return false
        }
        return projectID.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        }
    }
}

struct ProjectRegistryV2Store {
    enum LoadSource: Equatable {
        case primary
        case recoveredFromBackup
        case emptyAfterTotalLoss
        case emptyAfterQuarantine
    }

    struct LoadResult: Equatable {
        let document: ProjectRegistryV2Document
        let source: LoadSource
        let quarantinedFiles: [URL]
    }

    enum StoreError: Error, CustomStringConvertible, Equatable {
        case unsupportedSchema(Int)
        case duplicateProjectID(String)
        case invalidBookmarkReference(projectID: String)
        case invalidProjectID(String)
        case invalidActiveProjectID(String)

        var description: String {
            switch self {
            case .unsupportedSchema(let version):
                return "unsupported registry-v2 schema version: \(version)"
            case .duplicateProjectID(let projectID):
                return "registry-v2 contains duplicate project ID: \(projectID)"
            case .invalidBookmarkReference(let projectID):
                return "registry-v2 bookmark reference does not match project ID: \(projectID)"
            case .invalidProjectID(let projectID):
                return "registry-v2 contains invalid project ID: \(projectID)"
            case .invalidActiveProjectID(let projectID):
                return "registry-v2 active project does not exist: \(projectID)"
            }
        }
    }

    let primaryURL: URL
    let backupURL: URL
    let quarantineDirectoryURL: URL
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        appSupportRoot: URL = ProjectRegistryV2Store.defaultAppSupportRoot(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        let projectsDirectory = appSupportRoot.appendingPathComponent("projects", isDirectory: true)
        self.init(
            primaryURL: projectsDirectory.appendingPathComponent("registry-v2.json"),
            backupURL: projectsDirectory.appendingPathComponent("registry-v2.backup.json"),
            quarantineDirectoryURL: appSupportRoot.appendingPathComponent("backups", isDirectory: true),
            fileManager: fileManager,
            now: now
        )
    }

    init(
        primaryURL: URL,
        backupURL: URL,
        quarantineDirectoryURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.primaryURL = primaryURL
        self.backupURL = backupURL
        self.quarantineDirectoryURL = quarantineDirectoryURL
        self.fileManager = fileManager
        self.now = now
    }

    func load() throws -> LoadResult {
        let primaryExists = fileManager.fileExists(atPath: primaryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        if primaryExists, let document = try? decodeAndValidate(Data(contentsOf: primaryURL)) {
            return LoadResult(document: document, source: .primary, quarantinedFiles: [])
        }

        if backupExists, let backupDocument = try? decodeAndValidate(Data(contentsOf: backupURL)) {
            var quarantined: [URL] = []
            if primaryExists {
                quarantined.append(try quarantine(primaryURL, label: "primary"))
            }
            let data = try Self.encoder.encode(backupDocument)
            try writeAtomically(data, to: primaryURL)
            return LoadResult(
                document: backupDocument,
                source: .recoveredFromBackup,
                quarantinedFiles: quarantined
            )
        }

        guard primaryExists || backupExists else {
            return LoadResult(document: .empty, source: .emptyAfterTotalLoss, quarantinedFiles: [])
        }

        var quarantined: [URL] = []
        if primaryExists {
            quarantined.append(try quarantine(primaryURL, label: "primary"))
        }
        if backupExists {
            quarantined.append(try quarantine(backupURL, label: "backup"))
        }
        try save(.empty)
        return LoadResult(
            document: .empty,
            source: .emptyAfterQuarantine,
            quarantinedFiles: quarantined
        )
    }

    func save(_ document: ProjectRegistryV2Document) throws {
        try validate(document)
        let directory = primaryURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(document)

        if fileManager.fileExists(atPath: primaryURL.path),
           let currentData = try? Data(contentsOf: primaryURL),
           (try? decodeAndValidate(currentData)) != nil {
            try writeAtomically(currentData, to: backupURL)
        } else if !fileManager.fileExists(atPath: backupURL.path) {
            try writeAtomically(data, to: backupURL)
        }

        try writeAtomically(data, to: primaryURL)
    }

    static func defaultAppSupportRoot() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
        return appSupport.appendingPathComponent("relay-runner", isDirectory: true)
    }

    private func decodeAndValidate(_ data: Data) throws -> ProjectRegistryV2Document {
        let document = try Self.decoder.decode(ProjectRegistryV2Document.self, from: data)
        try validate(document)
        return document
    }

    private func validate(_ document: ProjectRegistryV2Document) throws {
        guard document.schemaVersion == ProjectRegistryV2Document.currentSchemaVersion else {
            throw StoreError.unsupportedSchema(document.schemaVersion)
        }
        var projectIDs = Set<String>()
        for project in document.projects {
            guard ProjectRegistryV2Identity.isValid(project.projectID) else {
                throw StoreError.invalidProjectID(project.projectID)
            }
            guard projectIDs.insert(project.projectID).inserted else {
                throw StoreError.duplicateProjectID(project.projectID)
            }
            guard project.bookmarkReference == .project(project.projectID) else {
                throw StoreError.invalidBookmarkReference(projectID: project.projectID)
            }
        }
        if let activeProjectID = document.activeProjectID,
           !projectIDs.contains(activeProjectID) {
            throw StoreError.invalidActiveProjectID(activeProjectID)
        }
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func quarantine(_ url: URL, label: String) throws -> URL {
        try fileManager.createDirectory(at: quarantineDirectoryURL, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now())
            .replacingOccurrences(of: ":", with: "-")
        let destination = quarantineDirectoryURL.appendingPathComponent(
            "registry-v2-\(label)-\(timestamp)-\(UUID().uuidString).corrupt.json"
        )
        try fileManager.moveItem(at: url, to: destination)
        return destination
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
}

protocol ProjectBookmarkStoring {
    func store(_ data: Data, reference: ProjectBookmarkReference) throws
    func load(reference: ProjectBookmarkReference) throws -> Data?
    func remove(reference: ProjectBookmarkReference) throws
}

struct KeychainProjectBookmarkStore: ProjectBookmarkStoring {
    enum KeychainError: Error, CustomStringConvertible {
        case status(OSStatus)

        var description: String {
            switch self {
            case .status(let status):
                return SecCopyErrorMessageString(status, nil) as String?
                    ?? "Keychain operation failed with status \(status)"
            }
        }
    }

    func store(_ data: Data, reference: ProjectBookmarkReference) throws {
        let query = baseQuery(reference)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }

    func load(reference: ProjectBookmarkReference) throws -> Data? {
        var query = baseQuery(reference)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return item as? Data
    }

    func remove(reference: ProjectBookmarkReference) throws {
        let status = SecItemDelete(baseQuery(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private func baseQuery(_ reference: ProjectBookmarkReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.serviceName,
            kSecAttrAccount as String: reference.account,
        ]
    }
}

protocol ProjectBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)
}

struct SecurityScopedProjectBookmarkCodec: ProjectBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

enum ProjectAccessGrantIssue: Equatable {
    case missing
    case stale
    case revokedOrUnreadable
}

enum ProjectAccessGrantResolution: Equatable {
    case available(URL)
    case requiresRegrant(ProjectAccessGrantIssue, lastKnownURL: URL?)
}

protocol ProjectAccessGrantManaging: AnyObject {
    func storeGrant(for url: URL, projectID: String) throws -> ProjectBookmarkReference
    func resolveGrant(reference: ProjectBookmarkReference) -> ProjectAccessGrantResolution
    func releaseGrant(reference: ProjectBookmarkReference) throws
}

final class ProjectAccessGrantManager: ProjectAccessGrantManaging {
    private let store: ProjectBookmarkStoring
    private let codec: ProjectBookmarkCoding
    private var accessedURLs: [String: URL] = [:]

    init(
        store: ProjectBookmarkStoring = KeychainProjectBookmarkStore(),
        codec: ProjectBookmarkCoding = SecurityScopedProjectBookmarkCodec()
    ) {
        self.store = store
        self.codec = codec
    }

    func storeGrant(for url: URL, projectID: String) throws -> ProjectBookmarkReference {
        let reference = ProjectBookmarkReference.project(projectID)
        if let accessedURL = accessedURLs.removeValue(forKey: projectID) {
            accessedURL.stopAccessingSecurityScopedResource()
        }
        try store.store(try codec.makeBookmark(for: url), reference: reference)
        return reference
    }

    func resolveGrant(reference: ProjectBookmarkReference) -> ProjectAccessGrantResolution {
        let data: Data
        do {
            guard let stored = try store.load(reference: reference) else {
                stopAccessing(reference: reference)
                return .requiresRegrant(.missing, lastKnownURL: nil)
            }
            data = stored
        } catch {
            stopAccessing(reference: reference)
            return .requiresRegrant(.revokedOrUnreadable, lastKnownURL: nil)
        }

        do {
            let result = try codec.resolveBookmark(data)
            guard !result.isStale else {
                stopAccessing(reference: reference)
                return .requiresRegrant(.stale, lastKnownURL: result.url)
            }
            if accessedURLs[reference.account] != result.url {
                if let previousURL = accessedURLs.removeValue(forKey: reference.account) {
                    previousURL.stopAccessingSecurityScopedResource()
                }
                _ = result.url.startAccessingSecurityScopedResource()
                accessedURLs[reference.account] = result.url
            }
            return .available(result.url)
        } catch {
            stopAccessing(reference: reference)
            return .requiresRegrant(.revokedOrUnreadable, lastKnownURL: nil)
        }
    }

    func releaseGrant(reference: ProjectBookmarkReference) throws {
        stopAccessing(reference: reference)
        try store.remove(reference: reference)
    }

    private func stopAccessing(reference: ProjectBookmarkReference) {
        if let url = accessedURLs.removeValue(forKey: reference.account) {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
