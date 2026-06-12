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
        let filtered = selectedProjectPath.map { path in
            items.filter { $0.project?.path == path }
        } ?? items
        return filtered.sorted(by: ProgramStatusItem.newestTicketFileFirst)
    }

    func ticketItem(matching id: String) -> ProgramStatusItem? {
        allTicketItems.first { $0.id == id }
    }

    func containsProject(path: String) -> Bool {
        projects.contains { $0.project?.path == path }
    }

    func projectName(for path: String) -> String? {
        projects.first { $0.project?.path == path }?.project?.name
    }

    private var allTicketItems: [ProgramStatusItem] {
        backlogWork.items + readyWork.items + inProgressWork.items + doneWork.items
    }
}

enum ProgramBoardLane: CaseIterable, Identifiable, Equatable, Hashable {
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

    var ticketStatus: Ticket.Status {
        switch self {
        case .backlog: .backlog
        case .ready: .ready
        case .inProgress: .inProgress
        case .done: .done
        }
    }
}

struct ProgramBoardDropRequest: Equatable {
    let ticketID: String
    let repoPath: String
    let targetStatus: Ticket.Status
    let shouldDispatch: Bool
}

struct ProgramBoardDropTarget: Equatable {
    let lane: ProgramBoardLane
    let isValid: Bool
}

struct ProgramBoardDragState: Equatable {
    let item: ProgramStatusItem
    let sourceLane: ProgramBoardLane
    var location: CGPoint
    var target: ProgramBoardDropTarget?
}

struct ProgramBoardProjectTarget: Equatable, Identifiable {
    let name: String
    let path: String

    var id: String { path }
}

struct ProgramBoardCreateDraft: Equatable {
    let lane: ProgramBoardLane
    let selectedProjectPath: String?

    var status: Ticket.Status { lane.ticketStatus }
}

struct ProgramBoardCreateRequest: Equatable {
    let repoPath: String
    let status: Ticket.Status
    let title: String
    let description: String

    var shouldDispatch: Bool { status == .ready }
}

struct ProgramBoardCreateResult: Equatable {
    let ticket: Ticket
    let shouldDispatch: Bool
}

enum ProgramBoardDropPolicy {
    static func request(
        for item: ProgramStatusItem,
        sourceLane: ProgramBoardLane,
        targetLane: ProgramBoardLane
    ) -> ProgramBoardDropRequest? {
        guard sourceLane != targetLane,
              item.isProgramBoardDraggable,
              let ticketID = cleaned(item.ticketID),
              let repoPath = cleaned(item.project?.path) else {
            return nil
        }
        if targetLane == .ready && !item.blockedBy.isEmpty {
            return nil
        }
        return ProgramBoardDropRequest(
            ticketID: ticketID,
            repoPath: repoPath,
            targetStatus: targetLane.ticketStatus,
            shouldDispatch: sourceLane != .ready && targetLane == .ready
        )
    }

    static func validateResolvedDrop(
        request: ProgramBoardDropRequest,
        ticket: Ticket,
        allTickets: [Ticket]
    ) -> ProgramBoardDropRequest? {
        guard ticket.id == request.ticketID,
              !ticket.canceled,
              ticket.runId == nil,
              ticket.status != request.targetStatus else {
            return nil
        }
        if request.targetStatus == .ready,
           !allDependenciesDone(for: ticket, in: allTickets) {
            return nil
        }
        return ProgramBoardDropRequest(
            ticketID: request.ticketID,
            repoPath: request.repoPath,
            targetStatus: request.targetStatus,
            shouldDispatch: ticket.status != .ready && request.targetStatus == .ready
        )
    }

    private static func allDependenciesDone(for ticket: Ticket, in allTickets: [Ticket]) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: allTickets.map { ($0.id, $0) })
        for dependencyID in ticket.dependsOn {
            guard byID[dependencyID]?.status == .done else {
                return false
            }
        }
        return true
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == "unknown" ? nil : trimmed
    }
}

enum ProgramBoardCreatePolicy {
    static func request(
        draft: ProgramBoardCreateDraft,
        selectedProjectPath: String?,
        title: String,
        description: String,
        projects: [ProgramBoardProjectTarget]
    ) -> ProgramBoardCreateRequest? {
        guard let selectedProjectPath,
              projects.contains(where: { $0.path == selectedProjectPath }) else {
            return nil
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProgramBoardCreateRequest(
            repoPath: selectedProjectPath,
            status: draft.status,
            title: trimmedTitle.isEmpty ? "Untitled" : trimmedTitle,
            description: description
        )
    }
}

enum ProgramBoardTicketCreator {
    static func create(_ request: ProgramBoardCreateRequest) throws -> ProgramBoardCreateResult {
        let repoURL = URL(fileURLWithPath: request.repoPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let project = ProjectResolver.LinkedProject(repoPath: repoURL)
        let draft = try TicketWriter.mintDraft(
            in: project,
            status: request.status,
            existingTickets: ProjectResolver.scanTickets(in: project),
            title: "Untitled"
        )
        let withDescription = TicketWriter.ticket(
            draft,
            withDescription: request.description
        )
        let updated = Ticket(
            id: withDescription.id,
            title: request.title,
            status: withDescription.status,
            priority: withDescription.priority,
            dependsOn: withDescription.dependsOn,
            runId: withDescription.runId,
            canceled: withDescription.canceled,
            draft: false,
            order: withDescription.order,
            description: withDescription.description,
            body: withDescription.body
        )
        try TicketWriter.save(updated, in: project)
        return ProgramBoardCreateResult(
            ticket: updated,
            shouldDispatch: request.shouldDispatch
        )
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

struct ProgramTicketIdentity: Equatable {
    let projectName: String?
    let projectPath: String
    let ticketID: String

    var ticketURL: URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".orchestrator", isDirectory: true)
            .appendingPathComponent("\(ticketID).md")
    }

    var ticketPath: String { ticketURL.path }

    init?(item: ProgramStatusItem) {
        guard let projectPath = Self.clean(item.project?.path),
              let ticketID = Self.clean(item.ticketID) else {
            return nil
        }
        self.projectName = Self.clean(item.project?.name)
        self.projectPath = projectPath
        self.ticketID = ticketID
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ProgramTicketDetail: Equatable, Identifiable {
    let item: ProgramStatusItem
    let identity: ProgramTicketIdentity?
    let ticket: Ticket?
    let ticketPath: String?
    let description: String?
    let acceptanceCriteria: String?
    let unavailableMessage: String?

    var id: String { item.id }

    var title: String {
        Self.clean(ticket?.title) ?? Self.clean(item.title) ?? "Untitled work"
    }

    var projectName: String {
        Self.clean(identity?.projectName) ?? Self.clean(item.project?.name) ?? "Unknown project"
    }

    static func load(
        item: ProgramStatusItem,
        fileManager: FileManager = .default
    ) -> ProgramTicketDetail {
        guard let identity = ProgramTicketIdentity(item: item) else {
            return ProgramTicketDetail(
                item: item,
                identity: nil,
                ticket: nil,
                ticketPath: nil,
                description: nil,
                acceptanceCriteria: nil,
                unavailableMessage: "Ticket identity is unavailable for this Program Board item."
            )
        }

        let ticketPath = identity.ticketPath
        guard fileManager.fileExists(atPath: ticketPath) else {
            return ProgramTicketDetail(
                item: item,
                identity: identity,
                ticket: nil,
                ticketPath: ticketPath,
                description: nil,
                acceptanceCriteria: nil,
                unavailableMessage: "Ticket file was not found at \(ticketPath)."
            )
        }

        do {
            let contents = try String(contentsOfFile: ticketPath, encoding: .utf8)
            let ticket = try TicketParser.parse(contents: contents)
            return ProgramTicketDetail(
                item: item,
                identity: identity,
                ticket: ticket,
                ticketPath: ticketPath,
                description: TicketParser.extractFullDescription(ticket.body),
                acceptanceCriteria: Self.section(named: "Acceptance criteria", in: ticket.body),
                unavailableMessage: nil
            )
        } catch {
            return ProgramTicketDetail(
                item: item,
                identity: identity,
                ticket: nil,
                ticketPath: ticketPath,
                description: nil,
                acceptanceCriteria: nil,
                unavailableMessage: "Ticket file could not be read: \(error)."
            )
        }
    }

    private static func section(named heading: String, in body: String) -> String? {
        let target = heading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = body.components(separatedBy: "\n")
        guard let headingIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            return trimmed == "## \(target)" || trimmed.hasPrefix("## \(target) ")
        }) else {
            return nil
        }

        var collected: [String] = []
        for line in lines[(headingIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { break }
            collected.append(line)
        }

        let joined = collected.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@Observable
final class ProgramBoardViewModel {
    var snapshot: ProgramDashboardSnapshot?
    var reloadState: ProgramBoardReloadState = .idle
    var errorMessage: String?
    var theme: ParticleFieldRenderer.Theme?
    var selectedProjectPath: String?
    var selectedTicketDetail: ProgramTicketDetail?
    var creating: ProgramBoardCreateDraft?
    var dragState: ProgramBoardDragState?
    var columnFrames: [ProgramBoardLane: CGRect] = [:]
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

    var projectTargets: [ProgramBoardProjectTarget] {
        snapshot?.projects.compactMap { item in
            guard let path = clean(item.project?.path) else { return nil }
            return ProgramBoardProjectTarget(
                name: clean(item.project?.name) ?? path,
                path: path
            )
        } ?? []
    }

    func selectAllProjects() {
        selectedProjectPath = nil
    }

    func selectProject(path: String) {
        selectedProjectPath = path
        if selectedTicketDetail?.identity?.projectPath != path {
            selectedTicketDetail = nil
        }
    }

    func ticketItems(in lane: ProgramBoardLane) -> [ProgramStatusItem] {
        snapshot?.ticketItems(in: lane, selectedProjectPath: selectedProjectPath) ?? []
    }

    func selectTicket(_ item: ProgramStatusItem) {
        selectedTicketDetail = ProgramTicketDetail.load(item: item)
    }

    func clearSelectedTicket() {
        selectedTicketDetail = nil
    }

    func beginCreate(in lane: ProgramBoardLane) {
        guard !projectTargets.isEmpty else { return }
        creating = ProgramBoardCreateDraft(
            lane: lane,
            selectedProjectPath: selectedProjectPath
        )
        selectedTicketDetail = nil
    }

    func cancelCreate() {
        creating = nil
    }

    func createRequest(
        selectedProjectPath: String?,
        title: String,
        description: String
    ) -> ProgramBoardCreateRequest? {
        guard let creating else { return nil }
        return ProgramBoardCreatePolicy.request(
            draft: creating,
            selectedProjectPath: selectedProjectPath,
            title: title,
            description: description,
            projects: projectTargets
        )
    }

    func dropRequest(
        for item: ProgramStatusItem,
        sourceLane: ProgramBoardLane,
        targetLane: ProgramBoardLane
    ) -> ProgramBoardDropRequest? {
        ProgramBoardDropPolicy.request(for: item, sourceLane: sourceLane, targetLane: targetLane)
    }

    func dropTarget(
        at location: CGPoint,
        for item: ProgramStatusItem,
        sourceLane: ProgramBoardLane
    ) -> ProgramBoardDropTarget? {
        guard let (lane, _) = columnFrames.first(where: { $0.value.contains(location) }) else {
            return nil
        }
        return ProgramBoardDropTarget(
            lane: lane,
            isValid: dropRequest(for: item, sourceLane: sourceLane, targetLane: lane) != nil
        )
    }

    @MainActor
    private func finishReload(snapshot: ProgramDashboardSnapshot) {
        self.snapshot = snapshot
        if let selectedProjectPath, !snapshot.containsProject(path: selectedProjectPath) {
            self.selectedProjectPath = nil
        }
        if let creating {
            if projectTargets.isEmpty {
                self.creating = nil
            } else if let path = creating.selectedProjectPath, !snapshot.containsProject(path: path) {
                self.creating = nil
            }
        }
        if let selectedTicketDetail {
            if let refreshedItem = snapshot.ticketItem(matching: selectedTicketDetail.id) {
                self.selectedTicketDetail = ProgramTicketDetail.load(item: refreshedItem)
            } else {
                self.selectedTicketDetail = nil
            }
        }
        reloadState = .succeeded
    }

    @MainActor
    private func finishReload(errorMessage: String) {
        self.errorMessage = errorMessage
        reloadState = .failed(errorMessage)
    }
}

extension String {
    var displayLabel: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    var programStateKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}

private func clean(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

extension ProgramStatusItem {
    static func newestTicketFileFirst(_ lhs: ProgramStatusItem, _ rhs: ProgramStatusItem) -> Bool {
        Ticket.newestFirst(
            lhsModifiedAt: lhs.ticketFileModifiedAt,
            lhsID: lhs.ticketID,
            lhsTitle: lhs.title,
            rhsModifiedAt: rhs.ticketFileModifiedAt,
            rhsID: rhs.ticketID,
            rhsTitle: rhs.title
        )
    }

    var isAwaitingMerge: Bool {
        programStateKeys.contains("awaiting_merge")
    }

    var hasActiveWorker: Bool {
        programStateKeys.contains("active")
    }

    var isProgramBoardDraggable: Bool {
        project?.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            ticketID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            !hasActiveWorker &&
            !isAwaitingMerge
    }

    private var programStateKeys: [String] {
        [status, runState, ticketState].compactMap { $0?.programStateKey }
    }

    private var ticketFileModifiedAt: Date? {
        guard let identity = ProgramTicketIdentity(item: self) else { return nil }
        return (try? identity.ticketURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
