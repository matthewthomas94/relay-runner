import AppKit
import SwiftUI

struct ProgramBoardOverlayView: View {
    @Bindable var model: ProgramBoardViewModel
    let onDismiss: () -> Void
    let onRefresh: () -> Void
    let onOpenProject: (String) -> Void

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                ProgramBoardContent(
                    model: model,
                    onRefresh: onRefresh,
                    onDismiss: onDismiss,
                    onOpenProject: onOpenProject
                )
                .padding(.top, 89)

                Spacer(minLength: 0)
            }
        }
        .ignoresSafeArea()
    }
}

private struct ProgramBoardContent: View {
    @Bindable var model: ProgramBoardViewModel
    let onRefresh: () -> Void
    let onDismiss: () -> Void
    let onOpenProject: (String) -> Void

    var body: some View {
        if let snapshot = model.snapshot {
            if snapshot.hasRegisteredProjects {
                ZStack(alignment: .top) {
                    HStack(alignment: .top, spacing: 12) {
                        ProgramOverviewColumn(
                            snapshot: snapshot,
                            selectedProjectPath: model.selectedProjectPath,
                            selectedScopeTitle: model.selectedScopeTitle,
                            errorMessage: model.errorMessage,
                            reloadState: model.reloadState,
                            theme: model.theme,
                            onSelectAll: model.selectAllProjects,
                            onSelectProject: model.selectProject,
                            onRefresh: onRefresh,
                            onDismiss: onDismiss
                        )
                        ForEach(ProgramBoardLane.allCases) { lane in
                            ProgramWorkColumnPanel(
                                lane: lane,
                                items: model.ticketItems(in: lane),
                                selectedTicketID: model.selectedTicketDetail?.id,
                                showsProjectContext: model.isAllSelected,
                                theme: model.theme,
                                onSelectTicket: model.selectTicket
                            )
                        }
                    }

                    if let detail = model.selectedTicketDetail {
                        ProgramTicketDetailPanel(
                            detail: detail,
                            theme: model.theme,
                            onClose: model.clearSelectedTicket,
                            onOpenProject: onOpenProject
                        )
                        .padding(.top, 18)
                        .zIndex(1)
                    }
                }
            } else {
                ProgramStatePanel(
                    title: "No registered projects",
                    detail: model.errorMessage ?? snapshot.summary.message,
                    reloadState: model.reloadState,
                    theme: model.theme,
                    onRefresh: onRefresh,
                    onDismiss: onDismiss
                )
            }
        } else if model.isLoading {
            ProgramStatePanel(
                title: "Loading program status",
                detail: nil,
                reloadState: model.reloadState,
                theme: model.theme,
                onRefresh: onRefresh,
                onDismiss: onDismiss
            )
        } else {
            ProgramStatePanel(
                title: "Program status unavailable",
                detail: model.errorMessage,
                reloadState: model.reloadState,
                theme: model.theme,
                onRefresh: onRefresh,
                onDismiss: onDismiss
            )
        }
    }
}

private struct ProgramOverviewColumn: View {
    let snapshot: ProgramDashboardSnapshot
    let selectedProjectPath: String?
    let selectedScopeTitle: String
    let errorMessage: String?
    let reloadState: ProgramBoardReloadState
    let theme: ParticleFieldRenderer.Theme?
    let onSelectAll: () -> Void
    let onSelectProject: (String) -> Void
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgramBoardTitleBar(
                reloadState: reloadState,
                onRefresh: onRefresh,
                onDismiss: onDismiss
            )

            if let errorMessage {
                ProgramErrorStrip(message: errorMessage)
            }

            ProgramMetricGrid(snapshot: snapshot)

            ProgramProjectFilterHeader(
                count: snapshot.projects.count,
                selectedScopeTitle: selectedScopeTitle,
                isAllSelected: selectedProjectPath == nil,
                onSelectAll: onSelectAll
            )

            BoardOverlayScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.projects) { item in
                        ProgramProjectCard(
                            item: item,
                            isSelected: selectedProjectPath == item.project?.path,
                            onSelect: {
                                if let path = item.project?.path {
                                    onSelectProject(path)
                                }
                            }
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .programColumnChrome(width: 304, theme: theme)
    }
}

private struct ProgramBoardTitleBar: View {
    let reloadState: ProgramBoardReloadState
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Program Board")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                    ProgramReloadButton(state: reloadState, action: onRefresh)
                }
                Text(reloadState.statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(reloadState.isFailure ? ProgramBoardStyle.red : ProgramBoardStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ProgramIconButton(systemName: "xmark", help: "Close Program Board", action: onDismiss)
        }
    }
}

private struct ProgramMetricGrid: View {
    let snapshot: ProgramDashboardSnapshot

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ProgramMetricTile(label: "Projects", value: "\(snapshot.projectCount)")
            ProgramMetricTile(label: "Backlog", value: "\(snapshot.backlogWork.items.count)")
            ProgramMetricTile(label: "Ready", value: "\(snapshot.readyWork.items.count)")
            ProgramMetricTile(label: "Progress", value: "\(snapshot.inProgressWork.items.count)")
            ProgramMetricTile(label: "Done", value: "\(snapshot.doneWork.items.count)")
            ProgramMetricTile(
                label: "Awaiting merge",
                value: "\(snapshot.awaitingMerge.items.count)",
                help: "Agent work that has finished and is waiting to be merged back into its project."
            )
        }
    }
}

private struct ProgramMetricTile: View {
    let label: String
    let value: String
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.primaryText)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ProgramCardBackground(cornerRadius: 12))
        .help(help ?? label)
    }
}

private struct ProgramProjectFilterHeader: View {
    let count: Int
    let selectedScopeTitle: String
    let isAllSelected: Bool
    let onSelectAll: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Projects")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                        .monospacedDigit()
                }
                Text(selectedScopeTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onSelectAll) {
                Text("All")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isAllSelected ? ProgramBoardStyle.primaryText : ProgramBoardStyle.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(isAllSelected ? 0.16 : 0.07))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(isAllSelected ? 0.25 : 0.10), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("Show tickets from all projects")
        }
    }
}

private struct ProgramProjectCard: View {
    let item: ProgramStatusItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.project?.name ?? "Unknown project")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !item.providers.isEmpty {
                        Text(item.providers.joined(separator: ", "))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                            .lineLimit(1)
                    }
                }

                Text(item.project?.path ?? "unknown")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                ProjectBoardOverview(item: item)

                if let stale = item.staleRuns, stale > 0 {
                    Text("\(stale) stale")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.red)
                        .lineLimit(1)
                }

                if !item.providerHealth.isEmpty {
                    Text(item.providerHealth.joined(separator: "  "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ProgramBoardStyle.red)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProgramCardBackground(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(isSelected ? 0.28 : 0), lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.40), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(item.project?.path == nil)
        .help("Show tickets for \(item.project?.name ?? "this project")")
    }
}

private struct ProjectBoardOverview: View {
    let item: ProgramStatusItem

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ProjectCount(label: "Backlog", value: item.backlogTickets ?? item.openTickets)
            ProjectCount(label: "Ready", value: item.readyTickets)
            ProjectCount(label: "In progress", value: item.inProgressTickets ?? item.activeRuns)
            ProjectCount(label: "Done", value: item.doneTickets)
        }
        .help("Project board overview")
    }
}

private struct ProjectCount: View {
    let label: String
    let value: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .lineLimit(1)
            Text("\(value ?? 0)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .minimumScaleFactor(0.8)
    }
}

private struct ProgramWorkColumnPanel: View {
    let lane: ProgramBoardLane
    let items: [ProgramStatusItem]
    let selectedTicketID: String?
    let showsProjectContext: Bool
    let theme: ParticleFieldRenderer.Theme?
    let onSelectTicket: (ProgramStatusItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 8) {
                Text(lane.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Text("\(items.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                    .monospacedDigit()
            }
            .padding(.bottom, 4)

            BoardOverlayScrollView {
                if items.isEmpty {
                    ProgramColumnEmpty(text: lane.emptyText)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            ProgramWorkCard(
                                item: item,
                                lane: lane,
                                isSelected: selectedTicketID == item.id,
                                showsProjectContext: showsProjectContext,
                                onSelect: { onSelectTicket(item) }
                            )
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .programColumnChrome(width: 270, theme: theme)
    }
}

private struct ProgramWorkCard: View {
    let item: ProgramStatusItem
    let lane: ProgramBoardLane
    let isSelected: Bool
    let showsProjectContext: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(projectName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(showsProjectContext ? ProgramBoardStyle.secondaryText : ProgramBoardStyle.mutedText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(ticketID)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 0)

                    if let priority = cleaned(item.priority) {
                        ProgramInlineBadge(label: priority.displayLabel)
                    }
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                let badges = stateBadges
                if !badges.isEmpty {
                    HStack(alignment: .center, spacing: 6) {
                        ForEach(badges, id: \.self) { label in
                            ProgramInlineBadge(label: label)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if let dependencyText {
                    Text(dependencyText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(item.blockedBy.isEmpty ? ProgramBoardStyle.secondaryText : ProgramBoardStyle.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if let statusText {
                    Text(statusText)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if let lastError = item.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ProgramBoardStyle.red)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProgramCardBackground(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(isSelected ? 0.28 : 0), lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.40), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .help(cardHelp)
    }

    private var projectName: String {
        cleaned(item.project?.name) ?? "Unknown project"
    }

    private var ticketID: String {
        cleaned(item.ticketID) ?? "No ticket"
    }

    private var title: String {
        cleaned(item.title) ?? "Untitled work"
    }

    private var stateBadges: [String] {
        var labels: [String] = []
        if item.isAwaitingMerge {
            labels.append("Awaiting merge")
        } else if item.hasActiveWorker {
            labels.append("Active worker")
        }
        if !item.blockedBy.isEmpty {
            labels.append("Blocked")
        }
        return labels
    }

    private var dependencyText: String? {
        var parts: [String] = []
        if !item.blockedBy.isEmpty {
            parts.append("blocked by \(item.blockedBy.joined(separator: ", "))")
        }
        if !item.dependsOn.isEmpty {
            parts.append("depends on \(item.dependsOn.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private var statusText: String? {
        var parts: [String] = []
        if let state = visibleStateLabel {
            parts.append(state)
        }
        if let runID = cleaned(item.runID) {
            parts.append("run \(runID)")
        }
        if let branch = cleaned(item.branch) {
            parts.append(branch)
        }
        if let provider = cleaned(item.provider) {
            parts.append(provider)
        }
        if let activity = cleaned(item.activity) {
            parts.append(activity)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private var visibleStateLabel: String? {
        for state in [item.runState, item.ticketState, item.status] {
            guard let state = cleaned(state) else { continue }
            let key = state.programStateKey
            guard !lane.redundantStateKeys.contains(key) else { continue }
            guard key != "active", key != "awaiting_merge" else { continue }
            return state.displayLabel
        }
        return nil
    }

    private var cardHelp: String {
        var parts = [projectName, ticketID, title]
        if let path = cleaned(item.project?.path) {
            parts.append(path)
        }
        return parts.joined(separator: " - ")
    }

    private func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ProgramTicketDetailPanel: View {
    let detail: ProgramTicketDetail
    let theme: ParticleFieldRenderer.Theme?
    let onClose: () -> Void
    let onOpenProject: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(detail.identity?.ticketID ?? "No ticket")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                            .lineLimit(1)
                        if detail.item.isAwaitingMerge {
                            ProgramInlineBadge(label: "Awaiting merge")
                        }
                    }
                    Text(detail.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                        .lineLimit(2)
                    Text(detail.projectName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                        .lineLimit(1)
                    if let projectPath = detail.identity?.projectPath {
                        Text(projectPath)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                ProgramIconButton(systemName: "xmark", help: "Close ticket details", action: onClose)
            }

            HStack(alignment: .center, spacing: 8) {
                ProgramDetailActionButton(
                    systemName: "rectangle.stack",
                    title: "Copy ID",
                    disabled: detail.identity == nil,
                    help: "Copy child ticket id"
                ) {
                    copyToPasteboard(detail.identity?.ticketID)
                }
                ProgramDetailActionButton(
                    systemName: "doc.on.doc",
                    title: "Copy Path",
                    disabled: detail.ticketPath == nil,
                    help: "Copy child ticket path"
                ) {
                    copyToPasteboard(detail.ticketPath)
                }
                ProgramDetailActionButton(
                    systemName: "folder",
                    title: "Reveal",
                    disabled: detail.ticket == nil,
                    help: detail.ticket == nil ? "Ticket file is unavailable" : "Reveal child ticket file"
                ) {
                    revealTicket()
                }
                ProgramDetailActionButton(
                    systemName: "rectangle.grid.2x2",
                    title: "Open Board",
                    disabled: detail.identity?.projectPath == nil,
                    help: "Open the owning project board"
                ) {
                    if let projectPath = detail.identity?.projectPath {
                        onOpenProject(projectPath)
                    }
                }
            }

            if let unavailableMessage = detail.unavailableMessage {
                ProgramDetailNotice(message: unavailableMessage)
            }

            BoardOverlayScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ProgramDetailMetadata(rows: metadataRows)
                    ProgramDetailSection(
                        title: "Description",
                        text: detail.description ?? "No description in the ticket file."
                    )
                    ProgramDetailSection(
                        title: "Acceptance criteria",
                        text: detail.acceptanceCriteria ?? "No acceptance criteria in the ticket file."
                    )
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(width: 560, height: 633, alignment: .topLeading)
        .background(BoardGlassBackground(cornerRadius: 16))
        .shadow(color: ProgramBoardColumnChrome.shadowColor(for: theme), radius: 22, x: 0, y: -6)
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    private var metadataRows: [ProgramDetailRow] {
        var rows: [ProgramDetailRow] = []
        append("Status", detail.item.status ?? detail.ticket?.status.rawValue, to: &rows)
        append("Priority", detail.item.priority ?? detail.ticket?.priority.rawValue, to: &rows)
        append("Ticket state", detail.item.ticketState, to: &rows)
        append("Run state", detail.item.runState, to: &rows)
        append("Run ID", detail.item.runID.map { "run \($0)" }, to: &rows, prettify: false)
        append("Branch", detail.item.branch, to: &rows, prettify: false)
        append("Provider", detail.item.provider, to: &rows, prettify: false)
        if !detail.item.dependsOn.isEmpty {
            rows.append(ProgramDetailRow(label: "Depends on", value: detail.item.dependsOn.joined(separator: ", ")))
        } else if let ticket = detail.ticket, !ticket.dependsOn.isEmpty {
            rows.append(ProgramDetailRow(label: "Depends on", value: ticket.dependsOn.joined(separator: ", ")))
        }
        if !detail.item.blockedBy.isEmpty {
            rows.append(ProgramDetailRow(label: "Blocked by", value: detail.item.blockedBy.joined(separator: ", ")))
        }
        append("Activity", detail.item.activity, to: &rows, prettify: false)
        append("Last error", detail.item.lastError, to: &rows, prettify: false)
        if detail.ticket?.canceled == true {
            rows.append(ProgramDetailRow(label: "Canceled", value: "Yes"))
        }
        return rows
    }

    private func append(
        _ label: String,
        _ value: String?,
        to rows: inout [ProgramDetailRow],
        prettify: Bool = true
    ) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        rows.append(ProgramDetailRow(label: label, value: prettify ? value.displayLabel : value))
    }

    private func copyToPasteboard(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func revealTicket() {
        guard let ticketPath = detail.ticketPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ticketPath)])
    }
}

private struct ProgramDetailRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

private struct ProgramDetailMetadata: View {
    let rows: [ProgramDetailRow]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        if !rows.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                            .lineLimit(1)
                        Text(row.value)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct ProgramDetailSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.primaryText)
                .lineLimit(1)
            Text(text)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProgramDetailNotice: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProgramBoardStyle.red)
            .lineLimit(3)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProgramCardBackground(cornerRadius: 12))
    }
}

private struct ProgramDetailActionButton: View {
    let systemName: String
    let title: String
    let disabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(ProgramBoardStyle.primaryText.opacity(disabled ? 0.45 : 0.95))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(disabled ? 0.04 : 0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(disabled ? 0.06 : 0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

private struct ProgramColumnEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProgramBoardStyle.mutedText)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .padding(.horizontal, 10)
            .background(ProgramCardBackground(cornerRadius: 14))
    }
}

private struct ProgramStatePanel: View {
    let title: String
    let detail: String?
    let reloadState: ProgramBoardReloadState
    let theme: ParticleFieldRenderer.Theme?
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgramBoardTitleBar(
                reloadState: reloadState,
                onRefresh: onRefresh,
                onDismiss: onDismiss
            )
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 560)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(width: 640, height: 360, alignment: .topLeading)
        .background(BoardGlassBackground(cornerRadius: 16))
        .shadow(color: ProgramBoardColumnChrome.shadowColor(for: theme), radius: 20, x: 0, y: -6)
        .contentShape(Rectangle())
        .onTapGesture { }
    }
}

private struct ProgramErrorStrip: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProgramBoardStyle.red)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProgramCardBackground(cornerRadius: 12))
    }
}

private struct ProgramIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.primaryText)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.10)))
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ProgramReloadButton: View {
    let state: ProgramBoardReloadState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if state.isLoading {
                    ProgressView()
                        .scaleEffect(0.58)
                        .controlSize(.small)
                } else {
                    Image(systemName: state.iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state.iconColor)
                }
            }
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.white.opacity(0.10)))
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state.isLoading)
        .help(state.helpText)
    }
}

private struct ProgramCardBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.black.opacity(0.35))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

private struct ProgramInlineBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(ProgramBoardStyle.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
            .fixedSize()
    }
}

private struct ProgramBoardColumnChrome: ViewModifier {
    let width: CGFloat
    let theme: ParticleFieldRenderer.Theme?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(width: width, height: 633, alignment: .topLeading)
            .background(BoardGlassBackground(cornerRadius: 16))
            .shadow(color: Self.shadowColor(for: theme), radius: 20, x: 0, y: -6)
            .animation(.easeInOut(duration: 0.4), value: theme)
            .contentShape(Rectangle())
            .onTapGesture { }
    }

    static func shadowColor(for theme: ParticleFieldRenderer.Theme?) -> Color {
        switch theme {
        case .stt:
            return Color(.sRGB, red: 244 / 255, green: 60 / 255, blue: 9 / 255, opacity: 0.15)
        case .tts:
            return Color(.sRGB, red: 40 / 255, green: 17 / 255, blue: 208 / 255, opacity: 0.15)
        case nil:
            return Color.black.opacity(0.45)
        }
    }
}

private extension View {
    func programColumnChrome(width: CGFloat, theme: ParticleFieldRenderer.Theme?) -> some View {
        modifier(ProgramBoardColumnChrome(width: width, theme: theme))
    }
}

private extension ProgramBoardLane {
    var redundantStateKeys: Set<String> {
        switch self {
        case .backlog:
            return ["backlog"]
        case .ready:
            return ["ready"]
        case .inProgress:
            return ["in_progress"]
        case .done:
            return ["done"]
        }
    }
}

private extension ProgramBoardReloadState {
    var statusText: String {
        switch self {
        case .idle:
            return "Workspace status"
        case .loading:
            return "Refreshing..."
        case .succeeded:
            return "Updated"
        case .failed:
            return "Refresh failed"
        }
    }

    var iconName: String {
        switch self {
        case .idle, .loading:
            return "arrow.clockwise"
        case .succeeded:
            return "checkmark"
        case .failed:
            return "exclamationmark"
        }
    }

    var iconColor: Color {
        switch self {
        case .succeeded:
            return ProgramBoardStyle.green
        case .failed:
            return ProgramBoardStyle.red
        case .idle, .loading:
            return ProgramBoardStyle.primaryText
        }
    }

    var helpText: String {
        switch self {
        case .idle:
            return "Refresh program status"
        case .loading:
            return "Refreshing program status"
        case .succeeded:
            return "Program status updated"
        case .failed(let message):
            return "Refresh failed: \(message)"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private enum ProgramBoardStyle {
    static let primaryText = Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 1.0)
    static let secondaryText = Color(.sRGB, red: 203 / 255, green: 213 / 255, blue: 225 / 255, opacity: 0.78)
    static let mutedText = Color(.sRGB, red: 148 / 255, green: 163 / 255, blue: 184 / 255, opacity: 0.82)
    static let red = Color(.sRGB, red: 244 / 255, green: 60 / 255, blue: 9 / 255, opacity: 1.0)
    static let green = Color(.sRGB, red: 52 / 255, green: 211 / 255, blue: 153 / 255, opacity: 1.0)
}
