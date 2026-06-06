import Foundation

enum WorkspaceFolder {
    static func url(
        from configuredPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "~" {
            return homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        }
        if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            let path = (homeDirectory.path as NSString).appendingPathComponent(suffix)
            return URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    @discardableResult
    static func refreshDiscovery(
        for general: GeneralConfig,
        registry: ProjectRegistry = ProjectRegistry()
    ) throws -> ProjectDiscoveryClassification {
        try registry.registerDiscovery(
            at: url(from: general.working_directory),
            provider: general.provider.displayName
        )
    }
}
