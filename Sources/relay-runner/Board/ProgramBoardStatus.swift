import Foundation
import SwiftUI

struct ProgramDashboardSnapshot: Equatable {
    let summary: ProgramStatusResponse
    let discoveryWork: ProgramStatusResponse
    let activeWork: ProgramStatusResponse
    let blockedWork: ProgramStatusResponse
    let doneWork: ProgramStatusResponse
    let awaitingMerge: ProgramStatusResponse

    var projects: [ProgramStatusItem] { summary.items }
    var projectCount: Int { summary.counts.projects }
    var inProgressItems: [ProgramStatusItem] {
        var seen = Set<String>()
        return (activeWork.items + awaitingMerge.items).filter { item in
            seen.insert(item.id).inserted
        }
    }
    var hasRegisteredProjects: Bool { projectCount > 0 }
    var hasActiveWork: Bool {
        !discoveryWork.items.isEmpty ||
            !inProgressItems.isEmpty ||
            !blockedWork.items.isEmpty ||
            !doneWork.items.isEmpty
    }
}

struct ProgramStatusResponse: Decodable, Equatable {
    let query: String
    let provider: String?
    let message: String
    let items: [ProgramStatusItem]
    let counts: ProgramStatusCounts
}

struct ProgramStatusCounts: Decodable, Equatable {
    let projects: Int
    let items: Int
}

struct ProgramStatusProject: Decodable, Equatable {
    let name: String
    let path: String
}

struct ProgramStatusItem: Decodable, Equatable, Identifiable {
    let project: ProgramStatusProject?
    let ticketID: String?
    let title: String?
    let status: String?
    let ticketState: String?
    let runID: String?
    let runState: String?
    let provider: String?
    let branch: String?
    let activity: String?
    let lastError: String?
    let blockedBy: [String]
    let openTickets: Int?
    let activeRuns: Int?
    let blocked: Int?
    let awaitingMerge: Int?
    let staleRuns: Int?
    let providers: [String]
    let providerHealth: [String]

    var id: String {
        [
            project?.path,
            ticketID,
            runID,
            title,
            status,
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }

    private enum CodingKeys: String, CodingKey {
        case project
        case ticketID = "ticket_id"
        case title
        case status
        case ticketState = "ticket_state"
        case runID = "run_id"
        case runState = "run_state"
        case provider
        case branch
        case activity
        case lastError = "last_error"
        case blockedBy = "blocked_by"
        case openTickets = "open_tickets"
        case activeRuns = "active_runs"
        case blocked
        case awaitingMerge = "awaiting_merge"
        case staleRuns = "stale_runs"
        case providers
        case providerHealth = "provider_health"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        project = try values.decodeIfPresent(ProgramStatusProject.self, forKey: .project)
        ticketID = try values.decodeIfPresent(String.self, forKey: .ticketID)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        ticketState = try values.decodeIfPresent(String.self, forKey: .ticketState)
        runID = Self.lossyString(values, forKey: .runID)
        runState = try values.decodeIfPresent(String.self, forKey: .runState)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        activity = try values.decodeIfPresent(String.self, forKey: .activity)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        blockedBy = try values.decodeIfPresent([String].self, forKey: .blockedBy) ?? []
        openTickets = try values.decodeIfPresent(Int.self, forKey: .openTickets)
        activeRuns = try values.decodeIfPresent(Int.self, forKey: .activeRuns)
        blocked = try values.decodeIfPresent(Int.self, forKey: .blocked)
        awaitingMerge = try values.decodeIfPresent(Int.self, forKey: .awaitingMerge)
        staleRuns = try values.decodeIfPresent(Int.self, forKey: .staleRuns)
        providers = try values.decodeIfPresent([String].self, forKey: .providers) ?? []
        providerHealth = try values.decodeIfPresent([String].self, forKey: .providerHealth) ?? []
    }

    private static func lossyString(
        _ values: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let string = try? values.decodeIfPresent(String.self, forKey: key) {
            return string
        }
        if let int = try? values.decodeIfPresent(Int.self, forKey: key) {
            return "\(int)"
        }
        if let double = try? values.decodeIfPresent(Double.self, forKey: key) {
            return "\(Int(double))"
        }
        return nil
    }
}

@Observable
final class ProgramBoardViewModel {
    var snapshot: ProgramDashboardSnapshot?
    var isLoading = false
    var errorMessage: String?
    var theme: ParticleFieldRenderer.Theme?

    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    deinit {
        reloadTask?.cancel()
    }

    func reload() {
        reloadTask?.cancel()
        isLoading = true
        errorMessage = nil
        reloadTask = Task { [weak self] in
            do {
                let snapshot = try await OrchestratorClient.fetchProgramDashboard()
                guard !Task.isCancelled else { return }
                await self?.finishReload(snapshot: snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.finishReload(errorMessage: message)
            }
        }
    }

    @MainActor
    private func finishReload(snapshot: ProgramDashboardSnapshot) {
        self.snapshot = snapshot
        isLoading = false
    }

    @MainActor
    private func finishReload(errorMessage: String) {
        self.errorMessage = errorMessage
        isLoading = false
    }
}
