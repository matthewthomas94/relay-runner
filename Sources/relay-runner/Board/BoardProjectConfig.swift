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
        try ensureExists(forRepoAt: repoURL)

        if usesArtifactWriter(forRepoAt: repoURL) {
            return try OrchestratorClient.claimArtifactTicketID(
                repoPath: repoURL.path,
                projectScopeToken: projectScopeToken
            )
        }

        let configURL = configURL(forRepoAt: repoURL)
        let config = try readConfig(at: configURL)
        try writeConfig(prefix: config.prefix, nextId: config.nextId + 1, to: configURL)
        return (config.prefix, config.nextId)
    }

    static func usesArtifactWriter(forRepoAt repoURL: URL) -> Bool {
        let configURL = configURL(forRepoAt: repoURL)
        guard let raw = try? String(contentsOf: configURL, encoding: .utf8),
              let table = try? TOMLTable(string: raw) else {
            return false
        }
        return table["schema_version"]?.tomlValue.int == 2
            && table["artifact_lifecycle"]?.tomlValue.string == "enabled"
            && table["artifact_ref"]?.tomlValue.string == "refs/heads/relay/artifacts"
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
