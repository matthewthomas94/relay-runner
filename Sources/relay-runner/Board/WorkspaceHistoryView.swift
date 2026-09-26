import SwiftUI

struct WorkspaceHistoryView: View {
    @Bindable var model: WorkspaceHistoryViewModel
    let onClose: () -> Void
    var onWorkspaceChanged: () -> Void = {}
    @State private var hoveredCardID: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(BoardDarkSurfaceStyle.border).frame(height: 1)
            if let error = model.errorMessage {
                messageStrip(error, warning: true)
            }
            if let notice = model.notice {
                messageStrip(notice, warning: false)
            }
            historySurface
            .opacity(model.isLoading ? 0.65 : 1)
            .overlay {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Loading Workspace history")
                }
            }
        }
        .frame(width: 940, height: 640)
        .background(BoardDarkSurfaceBackground(cornerRadius: BoardDarkSurfaceStyle.floatingPanelCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: BoardDarkSurfaceStyle.floatingPanelCornerRadius, style: .continuous))
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Workspace History")
                    .font(AppTypography.font(.sectionHeading))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                Text(model.projectName)
                    .font(AppTypography.font(.metadata))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(1)
            }
            Spacer()
            ProgramIconButton(systemName: "xmark", help: "Close history", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .frame(height: 70)
    }

    private var historySurface: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("Search archived tickets", text: $model.query, prompt: Text(""))
                        .appPlaceholder("Search archived tickets", when: model.query.isEmpty)
                        .textFieldStyle(.plain)
                        .font(AppTypography.font(.supporting))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                        .padding(.horizontal, 10)
                        .frame(height: SharedActionButtonMetrics.controlHeight)
                        .background(BoardDarkSurfaceBackground(
                            cornerRadius: SharedActionButtonMetrics.cornerRadius,
                            fill: BoardDarkSurfaceStyle.cardFill
                        ))
                        .overlay {
                            if searchFocused {
                                RoundedRectangle(cornerRadius: SharedActionButtonMetrics.cornerRadius)
                                    .stroke(ProgramBoardStyle.mutedText.opacity(0.5), lineWidth: 1)
                            }
                        }
                        .focused($searchFocused)
                        .onSubmit { Task { await model.search() } }
                        .accessibilityLabel("Search Workspace history")
                    ProgramIconButton(systemName: "magnifyingglass", help: "Search history") {
                        Task { await model.search() }
                    }
                }
                Text(WorkspaceHistoryViewModel.policySummary)
                    .font(AppTypography.font(.metadata))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if model.cards.isEmpty && !model.isLoading {
                            Text("No archived tickets match this search.")
                                .font(AppTypography.font(.supporting))
                                .foregroundStyle(ProgramBoardStyle.mutedText)
                                .padding(.top, 28)
                        }
                        ForEach(model.cards) { card in
                            historyCard(card)
                        }
                    }
                }
            }
            .padding(18)
            .frame(width: 330)

            Rectangle().fill(BoardDarkSurfaceStyle.border).frame(width: 1)

            Group {
                if let card = model.selectedCard {
                    historyDetail(card)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28))
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                        Text("Select a historical ticket")
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                        Text("Search completed work without restoring ticket files.")
                            .font(AppTypography.font(.supporting))
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 390)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func historyCard(_ card: ArtifactHistoryCard) -> some View {
        let badge = WorkspaceHistoryBadge.resolve(state: card.state)
        return Button {
            Task { await model.select(card) }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(card.ticketID)
                        .font(AppTypography.font(.caption))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                    Spacer()
                    Text(card.status.capitalized)
                        .font(AppTypography.font(.caption))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                }
                Text(card.title)
                    .font(AppTypography.font(.ticketTitle))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Text(badge.label)
                    .font(AppTypography.font(.caption))
                    .foregroundStyle(badge.isWarning ? ProgramBoardStyle.red : ProgramBoardStyle.mutedText)
                    .lineLimit(2)
                if card.attachmentCount > 0 {
                    Text("\(card.attachmentCount) attachment\(card.attachmentCount == 1 ? "" : "s")")
                        .font(AppTypography.font(.caption))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BoardDarkSurfaceBackground(
                cornerRadius: BoardDarkSurfaceStyle.nestedCardCornerRadius,
                fill: model.selectedCard?.id == card.id || hoveredCardID == card.id
                    ? BoardDarkSurfaceStyle.cardActiveFill : BoardDarkSurfaceStyle.cardFill
            ))
        }
        .buttonStyle(.plain)
        .onHover { hoveredCardID = $0 ? card.id : nil }
        .accessibilityLabel("\(card.ticketID), \(card.title), \(badge.label)")
    }

    private func historyDetail(_ card: ArtifactHistoryCard) -> some View {
        let badge = WorkspaceHistoryBadge.resolve(
            state: card.state,
            availability: model.detail?.availability
        )
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(card.ticketID)
                        .font(AppTypography.font(.metadata))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                    Text(model.detail?.card?.title ?? card.title)
                        .font(AppTypography.font(.sectionHeading))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                }
                Spacer()
                badgeView(badge)
            }

            if let detail = model.detail, detail.availability != "available" {
                VStack(alignment: .leading, spacing: 10) {
                    Text(detail.recovery ?? unavailableExplanation(detail.availability))
                        .font(AppTypography.font(.supporting))
                        .foregroundStyle(ProgramBoardStyle.red)
                    if detail.availability == "needs_network" {
                        ProgramWorkspaceActionButton(
                            title: "Fetch verified detail", systemName: "arrow.down",
                            prominence: .primary, accessibilityLabel: "Fetch verified detail",
                            help: "Download verified historical detail"
                        ) {
                            Task { await model.select(card, online: true) }
                        }
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let markdown = model.detail?.markdown {
                            Text(markdown)
                                .font(AppTypography.monospacedFont(size: 12, weight: .regular))
                                .foregroundStyle(ProgramBoardStyle.secondaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        dependencySummary
                        attachmentSummary
                    }
                }
                HStack {
                    ProgramWorkspaceActionButton(
                        title: "Restore detail", systemName: nil,
                        isEnabled: model.detail?.availability == "available",
                        accessibilityLabel: "Restore detail",
                        help: "Explicitly rematerialize this terminal ticket and its verified attachments"
                    ) {
                        Task {
                            await model.restore(reopen: false)
                            onWorkspaceChanged()
                        }
                    }
                    ProgramWorkspaceActionButton(
                        title: "Reopen in Backlog", systemName: nil, prominence: .primary,
                        isEnabled: model.detail?.availability == "available",
                        accessibilityLabel: "Reopen in Backlog",
                        help: "Move this ticket into the uncapped unfinished working set"
                    ) {
                        Task {
                            await model.restore(reopen: true)
                            onWorkspaceChanged()
                        }
                    }
                    Spacer()
                }
                .disabled(model.detail?.availability != "available")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var dependencySummary: some View {
        if let dependencies = model.dependencies {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dependencies")
                    .font(AppTypography.font(.body))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                if dependencies.dependencies.isEmpty {
                    Text("No dependencies")
                        .font(AppTypography.font(.metadata))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                }
                ForEach(dependencies.dependencies) { dependency in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: dependency.satisfied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(dependency.satisfied ? ProgramBoardStyle.green : ProgramBoardStyle.red)
                        Text(dependency.ticketID)
                        Text(dependency.availability.replacingOccurrences(of: "_", with: " ").capitalized)
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                    }
                    .font(AppTypography.font(.metadata))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentSummary: some View {
        if let attachments = model.detail?.attachments, !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Attachments")
                    .font(AppTypography.font(.body))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                ForEach(attachments) { attachment in
                    HStack {
                        Image(systemName: "paperclip")
                        Text(attachment.displayName)
                        Spacer()
                        if let size = attachment.size { Text(formatBytes(size)) }
                    }
                    .font(AppTypography.font(.metadata))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                }
                Text("Available after verified detail retrieval; viewing does not restore files.")
                    .font(AppTypography.font(.caption))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
            }
        }
    }

    private func badgeView(_ badge: WorkspaceHistoryBadge) -> some View {
        Text(badge.label)
            .font(AppTypography.font(.caption))
            .foregroundStyle(badge.isWarning ? ProgramBoardStyle.red : ProgramBoardStyle.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(BoardDarkCapsuleBackground())
            .accessibilityLabel("Archive state: \(badge.label)")
    }

    private func messageStrip(_ message: String, warning: Bool) -> some View {
        Text(message)
            .font(AppTypography.font(.supporting))
            .foregroundStyle(warning ? ProgramBoardStyle.red : ProgramBoardStyle.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .background(BoardDarkSurfaceStyle.cardFill)
    }

    private func unavailableExplanation(_ availability: String) -> String {
        switch availability {
        case "needs_network": "This ticket needs to be downloaded from its GitHub archive."
        case "tampered": "Archive metadata or Git object identity failed verification. Restore and reopen are disabled."
        case "not_found": "This historical ticket is missing from the verified archive catalog."
        default: "Historical detail is unavailable."
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
