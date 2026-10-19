import Foundation
import TOMLKit

enum BoardProjectConfig {

    enum ConfigError: Error, CustomStringConvertible {
        case invalid(path: String)
        case writeFailed(path: String, underlying: Error)

        var description: String {
            switch self {
            case .invalid(let path):
                return "invalid board config at \(path): expected non-empty alphanumeric prefix and positive next_id"
            case .writeFailed(let path, let underlying):
                return "failed to write board config at \(path): \(underlying)"
            }
        }
    }

    static func ensureExists(forRepoAt repoURL: URL) throws {
        let dir = ticketsDirectory(forRepoAt: repoURL)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ConfigError.writeFailed(path: dir.path, underlying: error)
        }

        let configURL = configURL(forRepoAt: repoURL)
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }

        let prefix = derivedPrefix(forRepoNamed: repoURL.lastPathComponent)
        try writeConfig(prefix: prefix, nextId: 1, to: configURL)
    }

    static func claimNextId(
        forRepoAt repoURL: URL,
        projectScopeToken: String? = nil
    ) throws -> (prefix: String, id: Int) {
        if usesArtifactWriter(forRepoAt: repoURL) {
            return try OrchestratorClient.claimArtifactTicketID(
                repoPath: repoURL.path,
                projectScopeToken: projectScopeToken
            )
        }

        try ensureExists(forRepoAt: repoURL)

        let configURL = configURL(forRepoAt: repoURL)
        let config = try readConfig(at: configURL)
        try writeConfig(prefix: config.prefix, nextId: config.nextId + 1, to: configURL)
        return (config.prefix, config.nextId)
    }

    /// Repos observed as artifact-managed this process. The daemon swaps the
    /// projected `.orchestrator/` folder in two renames, so `config.toml` can
    /// be briefly absent; a sticky decision keeps that window fail-closed.
    private static let artifactManagedRepos = LockedSet()

    private final class LockedSet: @unchecked Sendable {
        private let lock = NSLock()
        private var values = Set<String>()
        func contains(_ value: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values.contains(value) }
        func insert(_ value: String) { lock.lock(); defer { lock.unlock() }; values.insert(value) }
    }

    /// Readable config decides. When it can't be read or parsed (swap window,
    /// partial write), fall back to durable state: an earlier artifact-managed
    /// observation, or the `relay/artifacts` ref in the repo's git storage.
    static func usesArtifactWriter(forRepoAt repoURL: URL) -> Bool {
        let key = repoURL.standardizedFileURL.path
        let configURL = configURL(forRepoAt: repoURL)
        guard let raw = try? String(contentsOf: configURL, encoding: .utf8),
              let table = try? TOMLTable(string: raw) else {
            return artifactManagedRepos.contains(key) || hasArtifactRef(forRepoAt: repoURL)
        }
        let enabled = table["schema_version"]?.tomlValue.int == 2
            && table["artifact_lifecycle"]?.tomlValue.string == "enabled"
            && table["artifact_ref"]?.tomlValue.string == "refs/heads/relay/artifacts"
        if enabled { artifactManagedRepos.insert(key) }
        return enabled
    }

    private static func hasArtifactRef(forRepoAt repoURL: URL) -> Bool {
        let fm = FileManager.default
        var gitDir = repoURL.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitDir.path, isDirectory: &isDir) else { return false }
        if !isDir.boolValue {
            guard let pointer = try? String(contentsOf: gitDir, encoding: .utf8),
                  pointer.hasPrefix("gitdir:") else { return false }
            let path = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = URL(fileURLWithPath: path, relativeTo: repoURL)
        }
        if let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
            gitDir = URL(
                fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines),
                relativeTo: gitDir
            )
        }
        let ref = "refs/heads/relay/artifacts"
        if fm.fileExists(atPath: gitDir.appendingPathComponent(ref).path) { return true }
        guard let packed = try? String(contentsOf: gitDir.appendingPathComponent("packed-refs"), encoding: .utf8) else {
            return false
        }
        return packed.split(separator: "\n").contains { $0.hasSuffix(" \(ref)") }
    }

    static func derivedPrefix(forRepoNamed repoName: String) -> String {
        let words = repoName
            .split { $0 == "-" || $0 == "_" }
            .map { alphanumericString(from: $0) }
            .filter { !$0.isEmpty }

        if words.count > 1 {
            let initials = words.compactMap(\.first).map(String.init).joined()
            if !initials.isEmpty { return initials.uppercased() }
        }

        let compact = alphanumericString(from: Substring(repoName))
        guard !compact.isEmpty else { return "T" }
        return String(compact.prefix(2)).uppercased()
    }

    private static func ticketsDirectory(forRepoAt repoURL: URL) -> URL {
        repoURL.appendingPathComponent(".orchestrator", isDirectory: true)
    }

    private static func configURL(forRepoAt repoURL: URL) -> URL {
        ticketsDirectory(forRepoAt: repoURL).appendingPathComponent("config.toml")
    }

    private static func readConfig(at configURL: URL) throws -> (prefix: String, nextId: Int) {
        guard let raw = try? String(contentsOf: configURL, encoding: .utf8),
              let table = try? TOMLTable(string: raw),
              let prefix = table["prefix"]?.tomlValue.string,
              let rawNextId = table["next_id"]?.tomlValue.int else {
            throw ConfigError.invalid(path: configURL.path)
        }

        let nextId = Int(rawNextId)
        guard isValidPrefix(prefix), nextId > 0 else {
            throw ConfigError.invalid(path: configURL.path)
        }
        return (prefix, nextId)
    }

    private static func writeConfig(prefix: String, nextId: Int, to configURL: URL) throws {
        let rendered = "prefix = \"\(tomlEscaped(prefix))\"\nnext_id = \(nextId)\n"
        do {
            try Data(rendered.utf8).write(to: configURL, options: .atomic)
        } catch {
            throw ConfigError.writeFailed(path: configURL.path, underlying: error)
        }
    }

    private static func isValidPrefix(_ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        return prefix.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func alphanumericString(from value: Substring) -> String {
        String(value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }).uppercased()
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
