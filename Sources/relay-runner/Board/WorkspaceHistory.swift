import Foundation
import Observation

struct ArtifactHistorySearchResponse: Decodable, Equatable {
    let history: [ArtifactHistoryCard]
    let recovery: String?
}

struct ArtifactHistoryCard: Decodable, Equatable, Identifiable {
    let artifactID: String
    let ticketID: String
    let title: String
    let status: String
    let activityAt: String
    let state: String
    let attachmentCount: Int
    let attachmentBytes: Int

    var id: String { artifactID }

    private enum CodingKeys: String, CodingKey {
        case title, status, state
        case artifactID = "artifact_id"
        case ticketID = "ticket_id"
        case activityAt = "activity_at"
        case attachmentCount = "attachment_count"
        case attachmentBytes = "attachment_bytes"
    }
}

struct ArtifactHistoryDetailResponse: Decodable, Equatable {
    let availability: String
    let card: ArtifactHistoryDetailCard?
    let markdownBase64: String?
    let attachments: [ArtifactHistoryAttachment]
    let recovery: String?
    let materialized: Bool

    var markdown: String? {
        guard let markdownBase64,
              let data = Data(base64Encoded: markdownBase64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private enum CodingKeys: String, CodingKey {
        case availability, card, attachments, recovery, materialized
        case markdownBase64 = "markdown_base64"
    }
}

struct ArtifactHistoryDetailCard: Decodable, Equatable {
    let artifactID: String
    let ticketID: String
    let title: String
    let status: String
    let state: String
    let activityAt: String

    private enum CodingKeys: String, CodingKey {
        case title, status, state
        case artifactID = "artifact_id"
        case ticketID = "ticket_id"
        case activityAt = "activity_at"
    }
}

struct ArtifactHistoryAttachment: Decodable, Equatable, Identifiable {
    let path: String?
    let filename: String?
    let mimeType: String?
    let size: Int?

    var id: String { path ?? filename ?? "attachment-\(mimeType ?? "unknown")-\(size ?? 0)" }
    var displayName: String { filename ?? path ?? "Attachment" }

    private enum CodingKeys: String, CodingKey {
        case path, filename, size
        case mimeType = "mime_type"
    }
}

struct ArtifactDependencySummary: Decodable, Equatable {
    let ticketID: String
    let satisfied: Bool
    let dependencies: [ArtifactDependencyItem]

    private enum CodingKeys: String, CodingKey {
        case satisfied, dependencies
        case ticketID = "ticket_id"
    }
}

struct ArtifactDependencyItem: Decodable, Equatable, Identifiable {
    let ticketID: String
    let satisfied: Bool
    let availability: String
    let recovery: String?

    var id: String { ticketID }

    private enum CodingKeys: String, CodingKey {
        case satisfied, availability, recovery
        case ticketID = "ticket_id"
    }
}

struct ArtifactOperationResponse: Decodable, Equatable {
    let state: String
    let ticketIDs: [String]
    let warnings: [String]?
    let recovery: String?

    private enum CodingKeys: String, CodingKey {
        case state, warnings, recovery
        case ticketIDs = "ticket_ids"
    }
}

struct WorkspaceHistoryBadge: Equatable {
    let label: String
    let isWarning: Bool

    static func resolve(state: String, availability: String? = nil) -> WorkspaceHistoryBadge {
        switch availability?.lowercased() {
        case "needs_network":
            return WorkspaceHistoryBadge(label: "Needs Network", isWarning: true)
        case "tampered":
            return WorkspaceHistoryBadge(label: "Tampered", isWarning: true)
        case "not_found":
            return WorkspaceHistoryBadge(label: "Missing", isWarning: true)
        default:
            break
        }
        switch state.lowercased() {
        case "materialized_recent":
            return WorkspaceHistoryBadge(label: "Materialized", isWarning: false)
        case "materialized_exempt":
            return WorkspaceHistoryBadge(label: "Temporary Safety Overage", isWarning: true)
        case "archive_pending_sync", "restore_pending_sync":
            return WorkspaceHistoryBadge(label: "Local Archive Only", isWarning: true)
        case "archived", "deleted_tombstone":
            return WorkspaceHistoryBadge(
                label: "GitHub-backed • Locally Reachable Through Git",
                isWarning: false
            )
        case "restore_pending_fetch":
            return WorkspaceHistoryBadge(label: "Needs Network", isWarning: true)
        case "conflict":
            return WorkspaceHistoryBadge(label: "Tampered", isWarning: true)
        default:
            return WorkspaceHistoryBadge(label: "Archive State Unavailable", isWarning: true)
        }
    }
}

@Observable
final class WorkspaceHistoryViewModel {
    static let policySummary = (
        "All unfinished tickets stay local without a cap. The newest 25 Done and Canceled "
        + "tickets stay local; older tickets are archived automatically."
    )
    let repoPath: String
    let projectName: String
    let projectScopeToken: String?
    var query = ""
    var cards: [ArtifactHistoryCard] = []
    var selectedCard: ArtifactHistoryCard?
    var detail: ArtifactHistoryDetailResponse?
    var dependencies: ArtifactDependencySummary?
    var isLoading = false
    var errorMessage: String?
    var notice: String?

    init(repoPath: String, projectName: String, projectScopeToken: String?) {
        self.repoPath = repoPath
        self.projectName = projectName
        self.projectScopeToken = projectScopeToken
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await OrchestratorClient.fetchArtifactHistory(
                repoPath: repoPath,
                query: query,
                projectScopeToken: projectScopeToken
            )
            cards = response.history
            notice = response.recovery
        } catch {
            errorMessage = Self.message(for: error)
        }
        isLoading = false
    }

    func search() async {
        await refresh()
    }

    func select(_ card: ArtifactHistoryCard, online: Bool = false) async {
        selectedCard = card
        detail = nil
        dependencies = nil
        isLoading = true
        errorMessage = nil
        do {
            async let fetchedDetail = OrchestratorClient.fetchArtifactHistoryDetail(
                repoPath: repoPath,
                artifactID: card.artifactID,
                online: online,
                confirmGitHubExposure: false,
                projectScopeToken: projectScopeToken
            )
            async let fetchedDependencies = OrchestratorClient.fetchArtifactDependencySummary(
                repoPath: repoPath,
                ticketID: card.ticketID,
                projectScopeToken: projectScopeToken
            )
            let values = try await (fetchedDetail, fetchedDependencies)
            detail = values.0
            dependencies = values.1
        } catch {
            errorMessage = Self.message(for: error)
        }
        isLoading = false
    }

    func restore(reopen: Bool) async {
        guard let card = selectedCard else { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await OrchestratorClient.restoreArtifactHistory(
                repoPath: repoPath,
                artifactID: card.artifactID,
                reopen: reopen,
                online: detail?.availability == "needs_network",
                confirmGitHubExposure: false,
                projectScopeToken: projectScopeToken
            )
            notice = reopen
                ? "\(card.ticketID) reopened in Backlog and joined the uncapped unfinished set."
                : "\(card.ticketID) detail was explicitly restored."
            if let recovery = result.recovery, !recovery.isEmpty { notice = recovery }
            selectedCard = nil
            detail = nil
            dependencies = nil
            await refresh()
        } catch {
            errorMessage = Self.message(for: error)
        }
        isLoading = false
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
