import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

    func ticketItem(ticketID: String, projectPath: String) -> ProgramStatusItem? {
        allTicketItems.first {
            $0.ticketID == ticketID && $0.project?.path == projectPath
        }
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

    func upsertingTicket(
        _ ticket: Ticket,
        projectPath: String,
        projectName: String?
    ) -> ProgramDashboardSnapshot {
        replacingTicketItem(
            ticketID: ticket.id,
            projectPath: projectPath,
            replacement: ProgramStatusItem.ticket(
                ticket,
                projectPath: projectPath,
                projectName: projectName
            ),
            targetLane: ProgramBoardLane(status: ticket.status)
        )
    }

    func removingTicket(ticketID: String, projectPath: String) -> ProgramDashboardSnapshot {
        replacingTicketItem(
            ticketID: ticketID,
            projectPath: projectPath,
            replacement: nil,
            targetLane: nil
        )
    }

    private func replacingTicketItem(
        ticketID: String,
        projectPath: String,
        replacement: ProgramStatusItem?,
        targetLane: ProgramBoardLane?
    ) -> ProgramDashboardSnapshot {
        func items(
            _ source: ProgramStatusResponse,
            lane: ProgramBoardLane
        ) -> [ProgramStatusItem] {
            var items = source.items.filter {
                !($0.ticketID == ticketID && $0.project?.path == projectPath)
            }
            if lane == targetLane, let replacement {
                items.append(replacement)
            }
            return items
        }

        func response(_ source: ProgramStatusResponse, items: [ProgramStatusItem]) -> ProgramStatusResponse {
            ProgramStatusResponse(
                query: source.query,
                provider: source.provider,
                message: source.message,
                items: items,
                counts: ProgramStatusCounts(projects: source.counts.projects, items: items.count)
            )
        }

        let backlogItems = items(backlogWork, lane: .backlog)
        let readyItems = items(readyWork, lane: .ready)
        let inProgressItems = items(inProgressWork, lane: .inProgress)
        let doneItems = items(doneWork, lane: .done)

        return ProgramDashboardSnapshot(
            summary: summary,
            backlogWork: response(backlogWork, items: backlogItems),
            readyWork: response(readyWork, items: readyItems),
            inProgressWork: response(inProgressWork, items: inProgressItems),
            doneWork: response(doneWork, items: doneItems),
            awaitingMerge: awaitingMerge
        )
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
        case .ready: "Queued"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }

    var emptyText: String {
        switch self {
        case .backlog: "No backlog tickets"
        case .ready: "No queued tickets"
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

    init(status: Ticket.Status) {
        switch status {
        case .backlog: self = .backlog
        case .ready: self = .ready
        case .inProgress: self = .inProgress
        case .done: self = .done
        }
    }
}

struct ProgramBoardDropRequest: Equatable {
    let ticketID: String
    let repoPath: String
    let targetStatus: Ticket.Status
    let shouldDispatch: Bool
}

struct ProgramBoardDispatchRequest: Equatable {
    let ticketID: String
    let repoPath: String
    let source: String
}

struct ProgramBoardDropResult: Equatable {
    let ticket: Ticket
    let dispatchRequest: ProgramBoardDispatchRequest?
}

struct ProgramBoardDropTarget: Equatable {
    let lane: ProgramBoardLane
    let isValid: Bool
}

struct ProgramBoardDragState: Equatable {
    let item: ProgramStatusItem
    let sourceLane: ProgramBoardLane
    var location: CGPoint
    var cardCenterOffset: CGSize

    static func cardCenterOffset(cardFrame: CGRect?, startLocation: CGPoint) -> CGSize {
        guard let cardFrame,
              cardFrame.width > 0,
              cardFrame.height > 0 else {
            return .zero
        }
        return CGSize(
            width: cardFrame.midX - startLocation.x,
            height: cardFrame.midY - startLocation.y
        )
    }

    var cardCenter: CGPoint {
        CGPoint(
            x: location.x + cardCenterOffset.width,
            y: location.y + cardCenterOffset.height
        )
    }
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
    let imageURLs: [URL]

    var shouldDispatch: Bool { status == .ready }

    init(
        repoPath: String,
        status: Ticket.Status,
        title: String,
        description: String,
        imageURLs: [URL] = []
    ) {
        self.repoPath = repoPath
        self.status = status
        self.title = title
        self.description = description
        self.imageURLs = imageURLs
    }
}

struct ProgramBoardCreateResult: Equatable {
    let ticket: Ticket
    let shouldDispatch: Bool
}

struct ProgramBoardEditDraft: Equatable, Identifiable {
    let detail: ProgramTicketDetail
    let identity: ProgramTicketIdentity
    let original: Ticket
    var title: String
    var status: Ticket.Status
    var priority: Ticket.Priority
    var description: String
    var acceptanceCriteria: String

    var id: String { identity.ticketPath }
    var imageAttachmentPaths: [String] {
        TicketParser.extractImageAttachmentPaths(original.body)
    }
}

struct ProgramBoardEditRequest: Equatable {
    let repoPath: String
    let ticketID: String
    let title: String
    let status: Ticket.Status
    let priority: Ticket.Priority
    let description: String
    let acceptanceCriteria: String
    let imageURLs: [URL]

    init(
        repoPath: String,
        ticketID: String,
        title: String,
        status: Ticket.Status,
        priority: Ticket.Priority,
        description: String,
        acceptanceCriteria: String,
        imageURLs: [URL] = []
    ) {
        self.repoPath = repoPath
        self.ticketID = ticketID
        self.title = title
        self.status = status
        self.priority = priority
        self.description = description
        self.acceptanceCriteria = acceptanceCriteria
        self.imageURLs = imageURLs
    }
}

struct ProgramBoardEditResult: Equatable {
    let ticket: Ticket
    let shouldDispatch: Bool
}

struct ProgramBoardDeleteRequest: Equatable {
    let repoPath: String
    let ticketID: String
}

struct ProgramBoardDeleteResult: Equatable {
    let ticketID: String
    let repoPath: String
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
        let dependenciesDone = allDependenciesDone(for: ticket, in: allTickets)
        return ProgramBoardDropRequest(
            ticketID: request.ticketID,
            repoPath: request.repoPath,
            targetStatus: request.targetStatus,
            shouldDispatch: ticket.status != .ready && request.targetStatus == .ready && dependenciesDone
        )
    }

    static func allDependenciesDone(for ticket: Ticket, in allTickets: [Ticket]) -> Bool {
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

enum ProgramBoardDropError: LocalizedError {
    case missingTicket(ticketID: String, repoPath: String)
    case rejected(ticketID: String)
    case saveFailed(ticketID: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingTicket(let ticketID, let repoPath):
            return "\(ticketID) was not found in \(repoPath)."
        case .rejected(let ticketID):
            return "\(ticketID) cannot be moved to that lane."
        case .saveFailed(let ticketID, let underlying):
            return "\(ticketID) could not be saved: \(underlying.localizedDescription)"
        }
    }
}

enum ProgramBoardTicketMover {
    static func move(
        _ request: ProgramBoardDropRequest,
        dispatchSource: String = "board-drop",
        workerSizingDefaults: TicketWriter.WorkerSizingDefaults? = nil
    ) throws -> ProgramBoardDropResult {
        let repoURL = URL(fileURLWithPath: request.repoPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let project = ProjectResolver.LinkedProject(repoPath: repoURL)
        let allTickets = ProjectResolver.scanTickets(in: project)
        guard let current = allTickets.first(where: { $0.id == request.ticketID }) else {
            throw ProgramBoardDropError.missingTicket(ticketID: request.ticketID, repoPath: request.repoPath)
        }
        guard let resolved = ProgramBoardDropPolicy.validateResolvedDrop(
            request: request,
            ticket: current,
            allTickets: allTickets
        ) else {
            throw ProgramBoardDropError.rejected(ticketID: request.ticketID)
        }

        let updated = Ticket(
            id: current.id,
            title: current.title,
            status: resolved.targetStatus,
            priority: current.priority,
            dependsOn: current.dependsOn,
            runId: current.runId,
            canceled: current.canceled,
            workerModel: current.workerModel,
            workerEffort: current.workerEffort,
            workerSizingRationale: current.workerSizingRationale,
            workerProviderNotes: current.workerProviderNotes,
            draft: current.draft,
            order: current.order,
            description: current.description,
            body: current.body
        )
        let ticketToSave = resolved.targetStatus == .ready
            ? TicketWriter.applyingWorkerSizingDefaults(workerSizingDefaults, to: updated)
            : updated
        do {
            try TicketWriter.save(ticketToSave, in: project)
        } catch {
            throw ProgramBoardDropError.saveFailed(ticketID: current.id, underlying: error)
        }

        let dispatchRequest: ProgramBoardDispatchRequest?
        if resolved.shouldDispatch && !ticketToSave.draft {
            dispatchRequest = ProgramBoardDispatchRequest(
                ticketID: resolved.ticketID,
                repoPath: project.repoPath.path,
                source: dispatchSource
            )
        } else {
            dispatchRequest = nil
        }
        return ProgramBoardDropResult(ticket: ticketToSave, dispatchRequest: dispatchRequest)
    }
}

enum ProgramBoardCreatePolicy {
    static func request(
        draft: ProgramBoardCreateDraft,
        selectedProjectPath: String?,
        title: String,
        description: String,
        imageURLs: [URL] = [],
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
            description: description,
            imageURLs: imageURLs
        )
    }
}

enum ProgramBoardTicketCreator {
    static func create(
        _ request: ProgramBoardCreateRequest,
        workerSizingDefaults: TicketWriter.WorkerSizingDefaults? = nil
    ) throws -> ProgramBoardCreateResult {
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
            workerModel: withDescription.workerModel,
            workerEffort: withDescription.workerEffort,
            workerSizingRationale: withDescription.workerSizingRationale,
            workerProviderNotes: withDescription.workerProviderNotes,
            draft: false,
            order: withDescription.order,
            description: withDescription.description,
            body: withDescription.body
        )
        let sizedTicket = TicketWriter.applyingWorkerSizingDefaults(workerSizingDefaults, to: updated)
        let ticketToSave = try TicketImageStore.ingest(
            request.imageURLs,
            into: sizedTicket,
            in: project
        )
        try TicketWriter.save(ticketToSave, in: project)
        return ProgramBoardCreateResult(
            ticket: ticketToSave,
            shouldDispatch: request.shouldDispatch
        )
    }
}

enum ProgramBoardEditPolicy {
    static func draft(from detail: ProgramTicketDetail) -> ProgramBoardEditDraft? {
        guard let identity = detail.identity,
              let ticket = detail.ticket else {
            return nil
        }
        return ProgramBoardEditDraft(
            detail: detail,
            identity: identity,
            original: ticket,
            title: ticket.title,
            status: ticket.status,
            priority: ticket.priority,
            description: TicketParser.extractFullDescription(ticket.body) ?? "",
            acceptanceCriteria: TicketParser.extractAcceptanceCriteria(ticket.body) ?? ""
        )
    }

    static func request(
        draft: ProgramBoardEditDraft,
        title: String,
        status: Ticket.Status,
        priority: Ticket.Priority,
        description: String,
        acceptanceCriteria: String,
        imageURLs: [URL] = []
    ) -> ProgramBoardEditRequest {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProgramBoardEditRequest(
            repoPath: draft.identity.projectPath,
            ticketID: draft.identity.ticketID,
            title: trimmedTitle.isEmpty ? "Untitled" : trimmedTitle,
            status: status,
            priority: priority,
            description: description,
            acceptanceCriteria: acceptanceCriteria,
            imageURLs: imageURLs
        )
    }
}

enum ProgramBoardEditError: Error, Equatable {
    case missingTicketFile(String)
    case ticketIDMismatch(expected: String, found: String)
}

enum ProgramBoardTicketEditor {
    static func save(
        _ request: ProgramBoardEditRequest,
        fileManager: FileManager = .default,
        workerSizingDefaults: TicketWriter.WorkerSizingDefaults? = nil
    ) throws -> ProgramBoardEditResult {
        let repoURL = URL(fileURLWithPath: request.repoPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let project = ProjectResolver.LinkedProject(repoPath: repoURL)
        let ticketURL = ProjectResolver.ticketsDirectory(in: project)
            .appendingPathComponent("\(request.ticketID).md")

        guard fileManager.fileExists(atPath: ticketURL.path) else {
            throw ProgramBoardEditError.missingTicketFile(ticketURL.path)
        }

        let contents = try String(contentsOf: ticketURL, encoding: .utf8)
        let current = try TicketParser.parse(contents: contents)
        guard current.id == request.ticketID else {
            throw ProgramBoardEditError.ticketIDMismatch(expected: request.ticketID, found: current.id)
        }

        let withBody = TicketWriter.ticket(
            current,
            withDescription: request.description,
            acceptanceCriteria: request.acceptanceCriteria
        )
        let updated = Ticket(
            id: withBody.id,
            title: request.title,
            status: request.status,
            priority: request.priority,
            dependsOn: withBody.dependsOn,
            runId: withBody.runId,
            canceled: withBody.canceled,
            workerModel: withBody.workerModel,
            workerEffort: withBody.workerEffort,
            workerSizingRationale: withBody.workerSizingRationale,
            workerProviderNotes: withBody.workerProviderNotes,
            draft: withBody.draft,
            order: withBody.order,
            description: withBody.description,
            body: withBody.body
        )
        let sizedTicket = updated.status == .ready
            ? TicketWriter.applyingWorkerSizingDefaults(workerSizingDefaults, to: updated)
            : updated
        let ticketToSave = try TicketImageStore.ingest(
            request.imageURLs,
            into: sizedTicket,
            in: project,
            fileManager: fileManager
        )

        try TicketWriter.save(ticketToSave, in: project)
        let refreshed = [ticketToSave] + ProjectResolver.scanTickets(in: project).filter { $0.id != ticketToSave.id }
        return ProgramBoardEditResult(
            ticket: ticketToSave,
            shouldDispatch: current.status != .ready
                && ticketToSave.status == .ready
                && !ticketToSave.draft
                && ProgramBoardDropPolicy.allDependenciesDone(for: ticketToSave, in: refreshed)
        )
    }
}

enum ProgramBoardTicketDeleter {
    static func delete(_ request: ProgramBoardDeleteRequest) throws -> ProgramBoardDeleteResult {
        let repoURL = URL(fileURLWithPath: request.repoPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let project = ProjectResolver.LinkedProject(repoPath: repoURL)
        try TicketWriter.delete(request.ticketID, in: project)
        return ProgramBoardDeleteResult(
            ticketID: request.ticketID,
            repoPath: project.repoPath.path
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
                body: "No active workers or tickets awaiting review."
            )
        }

        var lines: [String] = []
        append(items: activeItems, label: "Active", fallbackState: "active", to: &lines)
        append(items: awaitingItems, label: "Awaiting review", fallbackState: "awaiting review", to: &lines)
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
        if state == "awaiting_merge" || state == "awaiting merge" {
            return "awaiting review"
        }
        return state.replacingOccurrences(of: "_", with: " ")
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
    let attempt: String?
    let runState: String?
    let provider: String?
    let branch: String?
    let activity: String?
    let lastError: String?
    let workerModel: String?
    let workerEffort: String?
    let workerSizingRationale: String?
    let workerProviderNotes: String?
    let workerSizingError: String?
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

    init(
        project: ProgramStatusProject?,
        ticketID: String?,
        title: String?,
        status: String?,
        priority: String?,
        ticketState: String? = nil,
        runID: String? = nil,
        attempt: String? = nil,
        runState: String? = nil,
        provider: String? = nil,
        branch: String? = nil,
        activity: String? = nil,
        lastError: String? = nil,
        workerModel: String? = nil,
        workerEffort: String? = nil,
        workerSizingRationale: String? = nil,
        workerProviderNotes: String? = nil,
        workerSizingError: String? = nil,
        dependsOn: [String] = [],
        blockedBy: [String] = [],
        openTickets: Int? = nil,
        activeRuns: Int? = nil,
        blocked: Int? = nil,
        awaitingMerge: Int? = nil,
        staleRuns: Int? = nil,
        backlogTickets: Int? = nil,
        readyTickets: Int? = nil,
        inProgressTickets: Int? = nil,
        doneTickets: Int? = nil,
        providers: [String] = [],
        providerHealth: [String] = []
    ) {
        self.project = project
        self.ticketID = ticketID
        self.title = title
        self.status = status
        self.priority = priority
        self.ticketState = ticketState
        self.runID = runID
        self.attempt = attempt
        self.runState = runState
        self.provider = provider
        self.branch = branch
        self.activity = activity
        self.lastError = lastError
        self.workerModel = workerModel
        self.workerEffort = workerEffort
        self.workerSizingRationale = workerSizingRationale
        self.workerProviderNotes = workerProviderNotes
        self.workerSizingError = workerSizingError
        self.dependsOn = dependsOn
        self.blockedBy = blockedBy
        self.openTickets = openTickets
        self.activeRuns = activeRuns
        self.blocked = blocked
        self.awaitingMerge = awaitingMerge
        self.staleRuns = staleRuns
        self.backlogTickets = backlogTickets
        self.readyTickets = readyTickets
        self.inProgressTickets = inProgressTickets
        self.doneTickets = doneTickets
        self.providers = providers
        self.providerHealth = providerHealth
    }

    static func ticket(
        _ ticket: Ticket,
        projectPath: String,
        projectName: String?
    ) -> ProgramStatusItem {
        let name = clean(projectName) ?? URL(fileURLWithPath: projectPath).lastPathComponent
        return ProgramStatusItem(
            project: ProgramStatusProject(name: name, path: projectPath),
            ticketID: ticket.id,
            title: ticket.title,
            status: ticket.status.rawValue,
            priority: ticket.priority.rawValue,
            dependsOn: ticket.dependsOn
        )
    }

    private enum CodingKeys: String, CodingKey {
        case project
        case ticketID = "ticket_id"
        case title
        case status
        case priority
        case ticketState = "ticket_state"
        case runID = "run_id"
        case attempt
        case runState = "run_state"
        case provider
        case branch
        case activity
        case lastError = "last_error"
        case workerModel = "worker_model"
        case workerEffort = "worker_effort"
        case workerSizingRationale = "worker_sizing_rationale"
        case workerProviderNotes = "worker_provider_notes"
        case workerSizingError = "worker_sizing_error"
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
        attempt = Self.lossyString(values, forKey: .attempt)
        runState = try values.decodeIfPresent(String.self, forKey: .runState)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        activity = try values.decodeIfPresent(String.self, forKey: .activity)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        workerModel = try values.decodeIfPresent(String.self, forKey: .workerModel)
        workerEffort = try values.decodeIfPresent(String.self, forKey: .workerEffort)
        workerSizingRationale = try values.decodeIfPresent(String.self, forKey: .workerSizingRationale)
        workerProviderNotes = try values.decodeIfPresent(String.self, forKey: .workerProviderNotes)
        workerSizingError = try values.decodeIfPresent(String.self, forKey: .workerSizingError)
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

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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

struct ProgramTicketImageAttachment: Equatable, Identifiable {
    enum State: Equatable {
        case preview(URL)
        case failure(String)
    }

    let relativePath: String
    let filename: String
    let accessibilityLabel: String
    let state: State

    var id: String { relativePath }
}

struct ProgramTicketDetail: Equatable, Identifiable {
    let item: ProgramStatusItem
    let identity: ProgramTicketIdentity?
    let ticket: Ticket?
    let ticketPath: String?
    let description: String?
    let acceptanceCriteria: String?
    let imageAttachments: [ProgramTicketImageAttachment]
    let unavailableMessage: String?

    var id: String { item.id }

    var title: String {
        Self.clean(ticket?.title) ?? Self.clean(item.title) ?? "Untitled work"
    }

    var projectName: String {
        Self.clean(identity?.projectName) ?? Self.clean(item.project?.name) ?? "Unknown project"
    }

    var imageAttachmentPaths: [String] {
        ticket.map { TicketParser.extractImageAttachmentPaths($0.body) } ?? []
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
                imageAttachments: [],
                unavailableMessage: "Ticket identity is unavailable for this Program Workspace item."
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
                imageAttachments: [],
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
                acceptanceCriteria: TicketParser.extractAcceptanceCriteria(ticket.body),
                imageAttachments: resolveImageAttachments(
                    ticket: ticket,
                    projectPath: identity.projectPath,
                    fileManager: fileManager
                ),
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
                imageAttachments: [],
                unavailableMessage: "Ticket file could not be read: \(error)."
            )
        }
    }

    private static func resolveImageAttachments(
        ticket: Ticket,
        projectPath: String,
        fileManager: FileManager
    ) -> [ProgramTicketImageAttachment] {
        let orchestratorDirectory = URL(fileURLWithPath: projectPath, isDirectory: true)
            .appendingPathComponent(".orchestrator", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let allowedDirectory = orchestratorDirectory
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(ticket.id, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        return TicketParser.extractImageAttachmentPaths(ticket.body).map { relativePath in
            resolveImageAttachment(
                relativePath: relativePath,
                ticketID: ticket.id,
                orchestratorDirectory: orchestratorDirectory,
                allowedDirectory: allowedDirectory,
                fileManager: fileManager
            )
        }
    }

    private static func resolveImageAttachment(
        relativePath: String,
        ticketID: String,
        orchestratorDirectory: URL,
        allowedDirectory: URL,
        fileManager: FileManager
    ) -> ProgramTicketImageAttachment {
        let filename = URL(fileURLWithPath: relativePath).lastPathComponent
        let fallbackName = filename.isEmpty ? relativePath : filename

        func failure(_ reason: String) -> ProgramTicketImageAttachment {
            ProgramTicketImageAttachment(
                relativePath: relativePath,
                filename: fallbackName,
                accessibilityLabel: "Ticket attachment \(fallbackName)",
                state: .failure(reason)
            )
        }

        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~"),
              URL(string: relativePath)?.scheme == nil,
              relativePath.hasPrefix("attachments/\(ticketID)/") else {
            return failure("Image preview unavailable.")
        }

        let candidate = orchestratorDirectory
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard isDescendantOrFile(resolved, in: allowedDirectory) else {
            return failure("Image preview unavailable.")
        }
        guard fileManager.fileExists(atPath: resolved.path),
              fileManager.isReadableFile(atPath: resolved.path),
              (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return failure("Image file is missing.")
        }
        guard let contentType = UTType(filenameExtension: resolved.pathExtension),
              contentType.conforms(to: .image) else {
            return failure("Image format is unsupported.")
        }
        guard NSImage(contentsOf: resolved) != nil else {
            return failure("Image file could not be opened.")
        }
        return ProgramTicketImageAttachment(
            relativePath: relativePath,
            filename: fallbackName,
            accessibilityLabel: "Ticket attachment \(fallbackName)",
            state: .preview(resolved)
        )
    }

    private static func isDescendantOrFile(_ file: URL, in directory: URL) -> Bool {
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath.hasPrefix(prefix)
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@Observable
final class ProgramBoardViewModel {
    var snapshot: ProgramDashboardSnapshot?
    var projectPaths: [String] = []
    var reloadState: ProgramBoardReloadState = .idle
    var errorMessage: String?
    var theme: ParticleFieldRenderer.Theme?
    var hasActiveSession = false
    var selectedProjectPath: String?
    var selectedTicketDetail: ProgramTicketDetail?
    var creating: ProgramBoardCreateDraft?
    var editing: ProgramBoardEditDraft?
    var dragItemID: String?
    var dragTarget: ProgramBoardDropTarget?
    var dragPreview: ProgramBoardDragState?
    var boardFrameInWindow: CGRect?
    var columnFrames: [ProgramBoardLane: CGRect] = [:]
    var cardFrames: [String: CGRect] = [:]
    var isLoading: Bool { reloadState.isLoading }

    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var fetchDashboard: ([String]) async throws -> ProgramDashboardSnapshot

    init(fetchDashboard: @escaping ([String]) async throws -> ProgramDashboardSnapshot = { repoPaths in
        try await OrchestratorClient.fetchProgramDashboard(repoPaths: repoPaths)
    }) {
        self.fetchDashboard = fetchDashboard
    }

    convenience init(fetchDashboard: @escaping () async throws -> ProgramDashboardSnapshot) {
        self.init(fetchDashboard: { _ in try await fetchDashboard() })
    }

    deinit {
        reloadTask?.cancel()
    }

    func prepareForOpening() {
        reloadTask?.cancel()
        reloadState = .idle
        errorMessage = nil
        selectedTicketDetail = nil
        creating = nil
        editing = nil
        endDrag()
    }

    func setProjectScope(_ paths: [String], selectedProjectPath: String? = nil) {
        var seen = Set<String>()
        let paths = paths.filter { seen.insert($0).inserted }
        let selectedProjectPath = selectedProjectPath.flatMap { paths.contains($0) ? $0 : nil }
        guard paths != projectPaths || selectedProjectPath != self.selectedProjectPath else { return }
        projectPaths = paths
        snapshot = nil
        self.selectedProjectPath = selectedProjectPath
        selectedTicketDetail = nil
    }

    @discardableResult
    func reload() -> Task<Void, Never> {
        reloadTask?.cancel()
        reloadState = .loading
        errorMessage = nil
        let fetchDashboard = fetchDashboard
        let projectPaths = projectPaths
        let task = Task { [weak self] in
            do {
                let snapshot = try await fetchDashboard(projectPaths)
                guard !Task.isCancelled else { return }
                await self?.finishReload(snapshot: snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                let message = Self.reloadErrorMessage(for: error)
                await self?.finishReload(errorMessage: message)
            }
        }
        reloadTask = task
        return task
    }

    @discardableResult
    func refreshInBackground() -> Task<Void, Never> {
        reloadTask?.cancel()
        errorMessage = nil
        let fetchDashboard = fetchDashboard
        let projectPaths = projectPaths
        let task = Task { [weak self] in
            do {
                let snapshot = try await fetchDashboard(projectPaths)
                guard !Task.isCancelled else { return }
                await self?.finishReload(snapshot: snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                let message = Self.reloadErrorMessage(for: error)
                await self?.finishReload(errorMessage: message)
            }
        }
        reloadTask = task
        return task
    }

    static func reloadErrorMessage(for error: Error) -> String {
        if OrchestratorClient.isTransientDaemonConnectionError(error) {
            return (
                "Relay Runner couldn’t reconnect to its local workspace service. "
                + "Try again, or reopen the app if the problem continues."
            )
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    var isAllSelected: Bool {
        selectedProjectPath == nil
    }

    var selectedScopeTitle: String {
        guard let selectedProjectPath else { return "All projects" }
        return snapshot?.projectName(for: selectedProjectPath) ?? "Selected project"
    }

    var selectedSessionProjectPath: String? {
        guard let selectedProjectPath,
              snapshot?.containsProject(path: selectedProjectPath) == true else {
            return nil
        }
        return selectedProjectPath
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
        if editing?.identity.projectPath != path {
            editing = nil
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
        editing = nil
    }

    func cancelCreate() {
        creating = nil
    }

    func beginEdit(item: ProgramStatusItem) {
        beginEdit(detail: ProgramTicketDetail.load(item: item))
    }

    func beginEdit(detail: ProgramTicketDetail) {
        selectedTicketDetail = detail
        creating = nil
        editing = ProgramBoardEditPolicy.draft(from: detail)
    }

    func cancelEdit() {
        editing = nil
    }

    func createRequest(
        selectedProjectPath: String?,
        title: String,
        description: String,
        imageURLs: [URL] = []
    ) -> ProgramBoardCreateRequest? {
        guard let creating else { return nil }
        return ProgramBoardCreatePolicy.request(
            draft: creating,
            selectedProjectPath: selectedProjectPath,
            title: title,
            description: description,
            imageURLs: imageURLs,
            projects: projectTargets
        )
    }

    func editRequest(
        title: String,
        status: Ticket.Status,
        priority: Ticket.Priority,
        description: String,
        acceptanceCriteria: String,
        imageURLs: [URL] = []
    ) -> ProgramBoardEditRequest? {
        guard let editing else { return nil }
        return ProgramBoardEditPolicy.request(
            draft: editing,
            title: title,
            status: status,
            priority: priority,
            description: description,
            acceptanceCriteria: acceptanceCriteria,
            imageURLs: imageURLs
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

    func updateBoardFrameInWindow(_ frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        boardFrameInWindow = frame
    }

    func boardLocation(fromWindowLocation location: CGPoint) -> CGPoint? {
        guard let boardFrameInWindow,
              boardFrameInWindow.width > 0,
              boardFrameInWindow.height > 0 else {
            return nil
        }
        return CGPoint(
            x: location.x - boardFrameInWindow.minX,
            y: boardFrameInWindow.maxY - location.y
        )
    }

    func updateCardFrame(id: String, windowFrame: CGRect) {
        guard let boardFrameInWindow,
              windowFrame.width > 0,
              windowFrame.height > 0 else {
            return
        }
        cardFrames[id] = CGRect(
            x: windowFrame.minX - boardFrameInWindow.minX,
            y: boardFrameInWindow.maxY - windowFrame.maxY,
            width: windowFrame.width,
            height: windowFrame.height
        )
    }

    func beginDrag(
        item: ProgramStatusItem,
        sourceLane: ProgramBoardLane,
        location: CGPoint,
        cardCenterOffset: CGSize,
        target: ProgramBoardDropTarget?
    ) {
        dragItemID = item.id
        dragTarget = target
        dragPreview = ProgramBoardDragState(
            item: item,
            sourceLane: sourceLane,
            location: location,
            cardCenterOffset: cardCenterOffset
        )
    }

    func updateDrag(location: CGPoint, target: ProgramBoardDropTarget?) {
        dragPreview?.location = location
        if dragTarget != target {
            dragTarget = target
        }
    }

    func endDrag() {
        dragItemID = nil
        dragTarget = nil
        dragPreview = nil
    }

    func reportDropFailure(_ message: String) {
        errorMessage = message
    }

    func applyTicket(_ ticket: Ticket, projectPath: String) {
        let projectName = snapshot?.projectName(for: projectPath)
        snapshot = snapshot?.upsertingTicket(
            ticket,
            projectPath: projectPath,
            projectName: projectName
        )
        if selectedTicketDetail?.identity?.ticketID == ticket.id,
           selectedTicketDetail?.identity?.projectPath == projectPath,
           let refreshedItem = snapshot?.ticketItem(ticketID: ticket.id, projectPath: projectPath) {
            selectedTicketDetail = ProgramTicketDetail.load(item: refreshedItem)
        }
    }

    func removeTicket(ticketID: String, projectPath: String) {
        snapshot = snapshot?.removingTicket(ticketID: ticketID, projectPath: projectPath)
        if selectedTicketDetail?.identity?.ticketID == ticketID,
           selectedTicketDetail?.identity?.projectPath == projectPath {
            selectedTicketDetail = nil
        }
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

private func cleanedProgramValue(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

private func clean(_ value: String?) -> String? {
    cleanedProgramValue(value)
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

    var activeWorkerBadgeLabel: String? {
        guard hasActiveWorker else { return nil }
        if let activity = cleanedProgramValue(activity) {
            return activity
        }
        for state in [runState, status, ticketState] {
            guard let state = cleanedProgramValue(state) else { continue }
            return state.programStateKey == "active" ? "Running" : state.displayLabel
        }
        return "Running"
    }

    var programCardMetadataParts: [String] {
        [
            cleanedProgramValue(ticketID) ?? "No ticket",
            cleanedProgramValue(project?.name) ?? "Unknown project",
        ]
    }

    var programAgentActivityLine: String? {
        if let activity = cleanedProgramValue(activity),
           hasActiveWorker || isAwaitingMerge {
            return activity
        }
        return hasActiveWorker ? "Running" : nil
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
