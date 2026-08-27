import Foundation
import Observation

struct ArtifactHistorySearchResponse: Decodable, Equatable {
    let history: [ArtifactHistoryCard]
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

struct ArtifactRetentionTicket: Decodable, Equatable, Identifiable {
    let ticketID: String
    let artifactID: String
    let title: String
    let status: String
    let activityAt: String
    let dependencies: [String]
    let attachmentPaths: [String]
    let exemptions: [String]
    let materialized: Bool

    var id: String { ticketID }

    private enum CodingKeys: String, CodingKey {
        case title, status, dependencies, exemptions, materialized
        case ticketID = "ticket_id"
        case artifactID = "artifact_id"
        case activityAt = "activity_at"
        case attachmentPaths = "attachment_paths"
    }
}

struct ArtifactRetentionPlan: Decodable, Equatable {
    let schemaVersion: Int
    let policy: String
    let limit: Int
    let projectID: String
    let artifactHead: String
    let evaluatedAt: String
    let retainedTerminalIDs: [String]
    let nonterminalIDs: [String]
    let evictionCandidateIDs: [String]
    let materializeIDs: [String]
    let temporaryOverage: [String: [String]]
    let retainedTerminal: [ArtifactRetentionTicket]
    let evictionCandidates: [ArtifactRetentionTicket]

    var estimatedRemovedFileCount: Int {
        evictionCandidates.reduce(0) { $0 + 1 + $1.attachmentPaths.count }
    }

    private enum CodingKeys: String, CodingKey {
        case policy, limit
        case schemaVersion = "schema_version"
        case projectID = "project_id"
        case artifactHead = "artifact_head"
        case evaluatedAt = "evaluated_at"
        case retainedTerminalIDs = "retained_terminal_ids"
        case nonterminalIDs = "nonterminal_ids"
        case evictionCandidateIDs = "eviction_candidate_ids"
        case materializeIDs = "materialize_ids"
        case temporaryOverage = "temporary_overage"
        case retainedTerminal = "retained_terminal"
        case evictionCandidates = "eviction_candidates"
    }
}

struct ArtifactRetentionStatus: Decodable, Equatable {
    let state: String
    let remoteMode: String
    let remoteName: String?
    let exposureConfirmationRequired: Bool
    let plan: ArtifactRetentionPlan
    let transaction: ArtifactRetentionTransaction
    let remote: ArtifactRetentionRemote?
    let blockedReasons: [String]
    let retryActions: [String]

    private enum CodingKeys: String, CodingKey {
        case state, plan, transaction, remote
        case remoteMode = "remote_mode"
        case remoteName = "remote_name"
        case exposureConfirmationRequired = "exposure_confirmation_required"
        case blockedReasons = "blocked_reasons"
        case retryActions = "retry_actions"
    }

    func canSubmit(exposureConfirmed: Bool, retry: Bool) -> Bool {
        guard remoteMode == "enabled" else { return false }
        guard !exposureConfirmationRequired || exposureConfirmed else { return false }
        return retry ? transaction.retryAvailable : state == "ready"
    }

    func recoveryMessages(excluding globalError: String?) -> [String] {
        let candidates = blockedReasons + [remote?.recovery, transaction.lastError].compactMap { $0 }
        return candidates.reduce(into: []) { messages, candidate in
            let message = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty, message != globalError, !messages.contains(message) else { return }
            messages.append(message)
        }
    }
}

struct ArtifactRetentionTransaction: Decodable, Equatable {
    let state: String
    let phase: String?
    let retryAvailable: Bool
    let lastError: String?

    private enum CodingKeys: String, CodingKey {
        case state, phase
        case retryAvailable = "retry_available"
        case lastError = "last_error"
    }
}

struct ArtifactRetentionRemote: Decodable, Equatable {
    let state: String
    let recovery: String?
}

struct ArtifactStorageMetrics: Decodable, Equatable {
    let materialized: ArtifactMaterializedStorage
    let retention: ArtifactRetentionStorage
    let reachableGitObjectsBytes: Int
    let databasesBytes: Int
    let runLogsBytes: Int
    let indexesBytes: Int
    let cachesBytes: Int
    let reclaimableEstimateBytes: Int

    private enum CodingKeys: String, CodingKey {
        case materialized, retention
        case reachableGitObjectsBytes = "reachable_git_objects_bytes"
        case databasesBytes = "databases_bytes"
        case runLogsBytes = "run_logs_bytes"
        case indexesBytes = "indexes_bytes"
        case cachesBytes = "caches_bytes"
        case reclaimableEstimateBytes = "reclaimable_estimate_bytes"
    }
}

struct ArtifactMaterializedStorage: Decodable, Equatable {
    let bytes: Int
    let files: Int
    let tickets: ArtifactStorageCategory
    let attachments: ArtifactStorageCategory
}

struct ArtifactStorageCategory: Decodable, Equatable {
    let bytes: Int
    let files: Int
}

struct ArtifactRetentionStorage: Decodable, Equatable {
    let retainedTerminalCount: Int
    let nonterminalCount: Int
    let temporaryOverageCount: Int
    let remotelyBackedHistoryCount: Int

    private enum CodingKeys: String, CodingKey {
        case retainedTerminalCount = "retained_terminal_count"
        case nonterminalCount = "nonterminal_count"
        case temporaryOverageCount = "temporary_overage_count"
        case remotelyBackedHistoryCount = "remotely_backed_history_count"
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

enum WorkspaceHistorySection: String, CaseIterable, Identifiable {
    case history = "History"
    case migration = "Storage"

    var id: String { rawValue }
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
        "All unfinished tickets stay materialized without a cap. Done and Canceled share one "
        + "pool; the 25 most recently active terminal tickets stay materialized."
    )
    static let materializationDisclaimer = (
        "Cleanup removes only materialized ticket Markdown and Relay-owned attachments. "
        + "Archive catalog metadata, reachable Git objects, indexes, caches, databases, and run logs remain."
    )

    let repoPath: String
    let projectName: String
    let projectScopeToken: String?
    var section: WorkspaceHistorySection = .history
    var query = ""
    var cards: [ArtifactHistoryCard] = []
    var selectedCard: ArtifactHistoryCard?
    var detail: ArtifactHistoryDetailResponse?
    var dependencies: ArtifactDependencySummary?
    var retentionStatus: ArtifactRetentionStatus?
    var storage: ArtifactStorageMetrics?
    var exposureConfirmed = false
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
            async let history = OrchestratorClient.fetchArtifactHistory(
                repoPath: repoPath,
                query: query,
                projectScopeToken: projectScopeToken
            )
            async let status = OrchestratorClient.fetchArtifactRetentionStatus(
                repoPath: repoPath,
                projectScopeToken: projectScopeToken
            )
            async let metrics = OrchestratorClient.fetchArtifactStorageMetrics(
                repoPath: repoPath,
                projectScopeToken: projectScopeToken
            )
            let values = try await (history, status, metrics)
            cards = values.0.history
            retentionStatus = values.1
            storage = values.2
        } catch {
            errorMessage = Self.message(for: error)
        }
        isLoading = false
    }

    func search() async {
        isLoading = true
        errorMessage = nil
        do {
            cards = try await OrchestratorClient.fetchArtifactHistory(
                repoPath: repoPath,
                query: query,
                projectScopeToken: projectScopeToken
            ).history
        } catch {
            errorMessage = Self.message(for: error)
        }
        isLoading = false
    }

    func select(_ card: ArtifactHistoryCard, online: Bool = false) async {
        selectedCard = card
        detail = nil
        dependencies = nil
        isLoading = true
        errorMessage = nil
        let confirmsExposure = online && exposureConfirmed
        do {
            async let fetchedDetail = OrchestratorClient.fetchArtifactHistoryDetail(
                repoPath: repoPath,
                artifactID: card.artifactID,
                online: online,
                confirmGitHubExposure: confirmsExposure,
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
                confirmGitHubExposure: exposureConfirmed,
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

    func applyRetention(retry: Bool = false) async {
        guard !isLoading else { return }
        guard retentionStatus?.remoteMode == "enabled" else {
            errorMessage = "Select and enable an existing GitHub remote before applying cleanup."
            return
        }
        guard exposureConfirmed || retentionStatus?.exposureConfirmationRequired != true else {
            errorMessage = "Confirm the selected GitHub exposure before applying cleanup."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await OrchestratorClient.applyArtifactRetention(
                repoPath: repoPath,
                retry: retry,
                confirmGitHubExposure: exposureConfirmed,
                projectScopeToken: projectScopeToken
            )
            notice = result.recovery ?? (
                retry ? "Retention recovery completed." : "Verified retention cleanup completed."
            )
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
