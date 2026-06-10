import Foundation
import SwiftUI

struct ProgramDashboardSnapshot: Equatable {
    let summary: ProgramStatusResponse
    let backlogWork: ProgramStatusResponse
    let readyWork: ProgramStatusResponse
    let inProgressWork: ProgramStatusResponse
    let doneWork: ProgramStatusResponse
    let awaitingMerge: ProgramStatusResponse

    var projects: [ProgramStatusItem] { summary.items }
    var projectCount: Int { summary.counts.projects }
    var hasRegisteredProjects: Bool { projectCount > 0 }
    var hasActiveWork: Bool {
        !backlogWork.items.isEmpty ||
            !readyWork.items.isEmpty ||
            !inProgressWork.items.isEmpty ||
            !doneWork.items.isEmpty
    }

    func ticketItems(in lane: ProgramBoardLane, selectedProjectPath: String?) -> [ProgramStatusItem] {
        let items: [ProgramStatusItem]
        switch lane {
        case .backlog:
            items = backlogWork.items
        case .ready:
            items = readyWork.items
        case .inProgress:
            items = inProgressWork.items
        case .done:
            items = doneWork.items
        }
        guard let selectedProjectPath else { return items }
        return items.filter { $0.project?.path == selectedProjectPath }
    }

    func containsProject(path: String) -> Bool {
        projects.contains { $0.project?.path == path }
    }

    func projectName(for path: String) -> String? {
        projects.first { $0.project?.path == path }?.project?.name
    }
}

enum ProgramBoardLane: CaseIterable, Identifiable, Equatable {
    case backlog
    case ready
    case inProgress
    case done

    var id: String { title }

    var title: String {
        switch self {
        case .backlog: "Backlog"
        case .ready: "Ready"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }

    var emptyText: String {
        switch self {
        case .backlog: "No backlog tickets"
        case .ready: "No ready tickets"
        case .inProgress: "No active tickets"
        case .done: "No done tickets"
        }
    }
}

enum ProgramBoardReloadState: Equatable {
    case idle
    case loading
    case succeeded
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

struct ProgramStatusOverlayMessage: Equatable {
    let title: String
    let body: String
}

enum ProgramStatusOverlayFormatter {
    static func message(
        active: ProgramStatusResponse,
        awaitingMerge: ProgramStatusResponse
    ) -> ProgramStatusOverlayMessage {
        let activeItems = active.items
        let awaitingItems = awaitingMerge.items

        guard !activeItems.isEmpty || !awaitingItems.isEmpty else {
            return ProgramStatusOverlayMessage(
                title: "Program Status",
                body: "No active workers or tickets awaiting merge."
            )
        }

        var lines: [String] = []
        append(items: activeItems, label: "Active", fallbackState: "active", to: &lines)
        append(items: awaitingItems, label: "Awaiting merge", fallbackState: "awaiting merge", to: &lines)
        return ProgramStatusOverlayMessage(title: "Program Status", body: lines.joined(separator: "\n"))
    }

    static func errorMessage(for error: Error) -> ProgramStatusOverlayMessage {
        if let urlError = error as? URLError, isDaemonUnavailable(urlError) {
            return ProgramStatusOverlayMessage(
                title: "Program status unavailable",
                body: "Relay Runner orchestrator is not reachable."
            )
        }

        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return ProgramStatusOverlayMessage(
            title: "Program status error",
            body: detail.isEmpty ? "Could not load program status." : detail
        )
    }

    private static func append(
        items: [ProgramStatusItem],
        label: String,
        fallbackState: String,
        to lines: inout [String]
    ) {
        guard !items.isEmpty else { return }
        lines.append("\(label):")
        lines.append(contentsOf: items.map { line(for: $0, fallbackState: fallbackState) })
    }

    private static func line(for item: ProgramStatusItem, fallbackState: String) -> String {
        let project = cleaned(item.project?.name) ?? "Unknown project"
        let ticketID = cleaned(item.ticketID) ?? "No ticket"
        let title = cleaned(item.title).map(compactTitle) ?? "Untitled"
        let provider = cleaned(item.provider) ?? "provider unknown"
        let state = humanState(cleaned(item.runState) ?? cleaned(item.status) ?? fallbackState)
        let run = cleaned(item.runID).map { ", run \($0)" } ?? ""
        return "\(project) \(ticketID) - \(title) (\(provider), \(state)\(run))"
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func compactTitle(_ title: String) -> String {
        let limit = 80
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 3)) + "..."
    }

    private static func humanState(_ state: String) -> String {
        state.replacingOccurrences(of: "_", with: " ")
    }

    private static func isDaemonUnavailable(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
            return true
        default:
            return false
        }
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
    let priority: String?
    let ticketState: String?
    let runID: String?
    let runState: String?
    let provider: String?
    let branch: String?
    let activity: String?
    let lastError: String?
    let dependsOn: [String]
    let blockedBy: [String]
    let openTickets: Int?
    let activeRuns: Int?
    let blocked: Int?
    let awaitingMerge: Int?
    let staleRuns: Int?
    let backlogTickets: Int?
    let readyTickets: Int?
    let inProgressTickets: Int?
    let doneTickets: Int?
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
        case priority
        case ticketState = "ticket_state"
        case runID = "run_id"
        case runState = "run_state"
        case provider
        case branch
        case activity
        case lastError = "last_error"
        case dependsOn = "depends_on"
        case blockedBy = "blocked_by"
        case openTickets = "open_tickets"
        case activeRuns = "active_runs"
        case blocked
        case awaitingMerge = "awaiting_merge"
        case staleRuns = "stale_runs"
        case backlogTickets = "backlog_tickets"
        case readyTickets = "ready_tickets"
        case inProgressTickets = "in_progress_tickets"
        case doneTickets = "done_tickets"
        case providers
        case providerHealth = "provider_health"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        project = try values.decodeIfPresent(ProgramStatusProject.self, forKey: .project)
        ticketID = try values.decodeIfPresent(String.self, forKey: .ticketID)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        priority = try values.decodeIfPresent(String.self, forKey: .priority)
        ticketState = try values.decodeIfPresent(String.self, forKey: .ticketState)
        runID = Self.lossyString(values, forKey: .runID)
        runState = try values.decodeIfPresent(String.self, forKey: .runState)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        activity = try values.decodeIfPresent(String.self, forKey: .activity)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        dependsOn = try values.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        blockedBy = try values.decodeIfPresent([String].self, forKey: .blockedBy) ?? []
        openTickets = try values.decodeIfPresent(Int.self, forKey: .openTickets)
        activeRuns = try values.decodeIfPresent(Int.self, forKey: .activeRuns)
        blocked = try values.decodeIfPresent(Int.self, forKey: .blocked)
        awaitingMerge = try values.decodeIfPresent(Int.self, forKey: .awaitingMerge)
        staleRuns = try values.decodeIfPresent(Int.self, forKey: .staleRuns)
        backlogTickets = try values.decodeIfPresent(Int.self, forKey: .backlogTickets)
        readyTickets = try values.decodeIfPresent(Int.self, forKey: .readyTickets)
        inProgressTickets = try values.decodeIfPresent(Int.self, forKey: .inProgressTickets)
        doneTickets = try values.decodeIfPresent(Int.self, forKey: .doneTickets)
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
    var reloadState: ProgramBoardReloadState = .idle
    var errorMessage: String?
    var theme: ParticleFieldRenderer.Theme?
    var selectedProjectPath: String?

    var isLoading: Bool { reloadState.isLoading }

    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var fetchDashboard: () async throws -> ProgramDashboardSnapshot

    init(fetchDashboard: @escaping () async throws -> ProgramDashboardSnapshot = {
        try await OrchestratorClient.fetchProgramDashboard()
    }) {
        self.fetchDashboard = fetchDashboard
    }

    deinit {
        reloadTask?.cancel()
    }

    @discardableResult
    func reload() -> Task<Void, Never> {
        reloadTask?.cancel()
        reloadState = .loading
        errorMessage = nil
        let fetchDashboard = fetchDashboard
        let task = Task { [weak self] in
            do {
                let snapshot = try await fetchDashboard()
                guard !Task.isCancelled else { return }
                await self?.finishReload(snapshot: snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.finishReload(errorMessage: message)
            }
        }
        reloadTask = task
        return task
    }

    var isAllSelected: Bool {
        selectedProjectPath == nil
    }

    var selectedScopeTitle: String {
        guard let selectedProjectPath else { return "All tickets" }
        return snapshot?.projectName(for: selectedProjectPath) ?? "Selected project"
    }

    func selectAllProjects() {
        selectedProjectPath = nil
    }

    func selectProject(path: String) {
        selectedProjectPath = path
    }

    func ticketItems(in lane: ProgramBoardLane) -> [ProgramStatusItem] {
        snapshot?.ticketItems(in: lane, selectedProjectPath: selectedProjectPath) ?? []
    }

    @MainActor
    private func finishReload(snapshot: ProgramDashboardSnapshot) {
        self.snapshot = snapshot
        if let selectedProjectPath, !snapshot.containsProject(path: selectedProjectPath) {
            self.selectedProjectPath = nil
        }
        reloadState = .succeeded
    }

    @MainActor
    private func finishReload(errorMessage: String) {
        self.errorMessage = errorMessage
        reloadState = .failed(errorMessage)
    }
}
