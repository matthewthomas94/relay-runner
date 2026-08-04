import Foundation

/// A provider-neutral proof that a user selected one registered project for
/// the current mutation scope. Paths and cwd values may suggest a project, but
/// only a token created from a current registry record confirms ownership.
struct ConfirmedProjectScopeToken: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let registrySchemaVersion: Int
    let projectID: String
    let repositoryPath: String
    let gitCommonDirectoryFingerprint: String
    let registryRecordUpdatedAt: Date
    let issuedAt: Date

    init(
        project: RegisteredProjectV2,
        registrySchemaVersion: Int,
        issuedAt: Date = Date()
    ) {
        version = Self.currentVersion
        self.registrySchemaVersion = registrySchemaVersion
        projectID = project.projectID
        repositoryPath = project.lastResolvedPath
        gitCommonDirectoryFingerprint = project.gitCommonDirectoryFingerprint
        registryRecordUpdatedAt = Self.normalizedTimestamp(project.updatedAt)
        self.issuedAt = Self.normalizedTimestamp(issuedAt)
    }

    var encodedValue: String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self).base64EncodedString()
    }

    init?(encodedValue: String) {
        guard let data = Data(base64Encoded: encodedValue) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let token = try? decoder.decode(Self.self, from: data) else { return nil }
        self = token
    }

    private static func normalizedTimestamp(_ date: Date) -> Date {
        let microseconds = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        return Date(timeIntervalSince1970: TimeInterval(microseconds) / 1_000_000)
    }
}

enum ProjectScopeValidation: Equatable {
    case valid(RegisteredProjectV2)
    case invalidVersion
    case missingProject
    case unavailable(RegisteredProjectAvailability)
    case staleRegistry
    case identityMismatch
    case appHomeTarget

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

/// Keeps suggestion and confirmation deliberately separate for one provider
/// thread. Redirect and cancel revoke inheritance without changing registry
/// identity or any repository bytes.
final class ProjectScopeCoordinator {
    private(set) var suggestedProjectID: String?
    private(set) var confirmedToken: ConfirmedProjectScopeToken?

    func suggest(projectID: String?) {
        suggestedProjectID = projectID
    }

    func confirm(_ token: ConfirmedProjectScopeToken) {
        suggestedProjectID = token.projectID
        confirmedToken = token
    }

    func inheritedToken(for projectID: String? = nil) -> ConfirmedProjectScopeToken? {
        guard let confirmedToken else { return nil }
        guard projectID == nil || projectID == confirmedToken.projectID else { return nil }
        return confirmedToken
    }

    func redirect(to token: ConfirmedProjectScopeToken) {
        confirm(token)
    }

    func cancel(projectID: String? = nil) {
        guard projectID == nil || confirmedToken?.projectID == projectID else { return }
        confirmedToken = nil
        if projectID == nil || suggestedProjectID == projectID {
            suggestedProjectID = nil
        }
    }

    func invalidateIfNeeded(
        using validate: (ConfirmedProjectScopeToken) -> ProjectScopeValidation
    ) {
        guard let confirmedToken, !validate(confirmedToken).isValid else { return }
        cancel(projectID: confirmedToken.projectID)
    }
}
