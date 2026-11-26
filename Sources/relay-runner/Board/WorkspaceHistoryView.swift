import SwiftUI

struct WorkspaceHistoryView: View {
    @Bindable var model: WorkspaceHistoryViewModel
    /// RR-550: the History chat, kept per repository and per ticket.
    let chat: WorkspaceHistoryChatModel
    let onClose: () -> Void
    var onWorkspaceChanged: () -> Void = {}
    /// Shown as a Workspace tab: it fills the page as two panels, and
    /// `accessory` replaces the close button.
    var isEmbedded = false
    var accessory: AnyView?
    @State private var hoveredCardID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isEmbedded {
            embeddedBody
        } else {
            windowBody
        }
    }

    /// The History tab: the title, search and archived tickets in a left
    /// panel as wide as the Workspace's Projects panel, and the open ticket in
    /// its own panel with the project picker at its top right.
    private var embeddedBody: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: BoardSurfaceLayout.columnSpacing) {
                VStack(spacing: 0) {
                    HStack {
                        title
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 22)
                    .frame(height: Self.headerHeight)
                    messageStrips
                    ZStack {
                        if model.historyLoaded {
                            historyList
                                .opacity(model.isLoading ? 0.65 : 1)
                                .overlay {
                                    if model.isLoading {
                                        ProgressView().controlSize(.small)
                                            .accessibilityLabel("Loading Workspace history")
                                            .transition(.relayElement)
                                    }
                                }
                                .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.isLoading)
                                .transition(.relayAfterDots(.surface))
                        } else {
                            SkeletonLoader(layout: .historyList, label: "Loading Workspace history")
                                .transition(.dotDisintegrateReplacing)
                        }
                    }
                    .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.historyLoaded)
                }
                .frame(width: BoardSurfaceLayout.boardColumnWidth(rowWidth: geometry.size.width))
                .frame(maxHeight: .infinity)
                .historyPanelChrome()

                VStack(spacing: 0) {
                    HStack {
                        Spacer(minLength: 0)
                        accessory
                    }
                    .padding(.horizontal, 22)
                    .frame(height: Self.headerHeight)
                    historyDetailPanel
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .historyPanelChrome()
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.errorMessage)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.notice)
        .task { await model.refresh() }
    }

    private static let headerHeight: CGFloat = 70

    @ViewBuilder
    private var messageStrips: some View {
        if let error = model.errorMessage {
            messageStrip(error, warning: true)
                .transition(.relayElement)
        }
        if let notice = model.notice {
            messageStrip(notice, warning: false)
                .transition(.relayElement)
        }
    }

    private var title: some View {
        Text("Workspace History")
            .font(AppTypography.font(.sectionHeading))
            .foregroundStyle(ProgramBoardStyle.primaryText)
    }

    private var windowBody: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(SettingsSurfaceColor.divider).frame(height: 1)
            messageStrips
            ZStack {
                if model.historyLoaded {
                    historySurface
                    .opacity(model.isLoading ? 0.65 : 1)
                    .overlay {
                        if model.isLoading {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Loading Workspace history")
                                .transition(.relayElement)
                        }
                    }
                    .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.isLoading)
                    .transition(.relayAfterDots(.surface))
                } else {
                    SkeletonLoader(layout: .history, label: "Loading Workspace history")
                        .transition(.dotDisintegrateReplacing)
                }
            }
            .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.historyLoaded)
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.errorMessage)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.notice)
        .frame(width: 940, height: 640)
        .background(BoardDarkSurfaceBackground(cornerRadius: BoardDarkSurfaceStyle.floatingPanelCornerRadius, panelGlass: true))
        .clipShape(RoundedRectangle(cornerRadius: BoardDarkSurfaceStyle.floatingPanelCornerRadius, style: .continuous))
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            title
            Spacer()
            ProgramIconButton(icon: .x, help: "Close history", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .frame(height: 70)
    }

    private var historySurface: some View {
        HStack(spacing: 0) {
            historyList
                .frame(width: 330)

            Rectangle().fill(SettingsSurfaceColor.divider).frame(width: 1)

            historyDetailPanel
        }
    }

    private var historyList: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("Search archived tickets", text: $model.query, prompt: Text(""))
                    .appPlaceholder("Search archived tickets", when: model.query.isEmpty)
                    .graphicalInput()
                    .onSubmit { Task { await model.search() } }
                    .onChange(of: model.query) { Task { await model.queryChanged() } }
                    .accessibilityLabel("Search Workspace history")
                ProgramIconButton(icon: .search, help: "Search archived tickets") {
                    Task { await model.search() }
                }
            }
            RelayFadingScrollView {
                LazyVStack(spacing: 8) {
                    if model.cards.isEmpty && !model.isLoading {
                        RelaySwap(model.emptyMessage, style: .text) { message in
                            Text(message)
                                .font(AppTypography.font(.supporting))
                                .foregroundStyle(ProgramBoardStyle.mutedText)
                        }
                        .padding(.top, 28)
                        .transition(.relayReplacing(.text))
                    }
                    ForEach(model.cards) { card in
                        historyCard(card)
                            // Results after an empty search wait for the
                            // empty-state line to leave their place.
                            .transition(.relayReplacing(.element))
                    }
                }
            }
            .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.cards)
        }
        .padding(18)
    }

    private var historyDetailPanel: some View {
        ZStack {
            if let card = model.selectedCard {
                historyDetail(card)
                    .id(card.id)
                    .transition(.relayReplacing(.surface))
            } else {
                // RR-550: with no ticket open the panel chats with the
                // repository's history, as Notes chats with the library.
                NoteChatPanel(
                    chat: chat,
                    scope: model.chatScope,
                    placeholder: "Ask about this project's history",
                    hintTitle: "Ask about this project's history",
                    hintDetail: "Select a ticket to ask about just that ticket."
                )
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.relayReplacing(.surface))
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.selectedCard?.id)
    }

    private func historyCard(_ card: ArtifactHistoryCard) -> some View {
        let badge = WorkspaceHistoryBadge.resolve(state: card.state)
        let selected = model.selectedCard?.id == card.id
        let hovered = hoveredCardID == card.id
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
                // Only a problem earns a line; a healthy archive state says nothing.
                if badge.isWarning {
                    Text(badge.label)
                        .font(AppTypography.font(.caption))
                        .foregroundStyle(ProgramBoardStyle.red)
                        .lineLimit(2)
                }
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
                fill: selected || hovered
                    ? BoardDarkSurfaceStyle.cardActiveFill : BoardDarkSurfaceStyle.cardFill
            ))
            .animation(RelayMotion.hover, value: hovered)
            .animation(RelayMotion.change(reduceMotion: reduceMotion), value: selected)
        }
        .buttonStyle(.graphicalPress)
        .onHover { hoveredCardID = $0 ? card.id : nil }
        .accessibilityLabel(badge.isWarning ? "\(card.ticketID), \(card.title), \(badge.label)" : "\(card.ticketID), \(card.title)")
    }

    /// Laid out like an open note: title and close button, a row of actions,
    /// notices, then the ticket in a scroll view.
    private func historyDetail(_ card: ArtifactHistoryCard) -> some View {
        let detail = model.detail
        let available = detail?.availability == "available"
        let busy = model.isLoading
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.ticketID)
                        .font(AppTypography.font(.metadata))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                    RelaySwap(detail?.card?.title ?? card.title, style: .text, alignment: .leading) { title in
                        Text(title)
                            .font(AppTypography.font(.screenTitle))
                            .foregroundStyle(ProgramBoardStyle.primaryText)
                    }
                }
                Spacer(minLength: 0)
                ProgramIconButton(icon: .x, help: "Close ticket") { model.close() }
            }

            HStack(alignment: .center, spacing: 8) {
                ProgramDetailActionButton(
                    icon: .rotateCcw, title: "Restore",
                    disabled: !available || busy,
                    help: available ? "Restore ticket file" : "Ticket not open"
                ) {
                    Task {
                        await model.restore(reopen: false)
                        onWorkspaceChanged()
                    }
                }
                ProgramDetailActionButton(
                    icon: .undo2, title: "Reopen in Backlog",
                    disabled: !available || busy,
                    help: available ? "Reopen in backlog" : "Ticket not open"
                ) {
                    Task {
                        await model.restore(reopen: true)
                        onWorkspaceChanged()
                    }
                }
                if detail?.availability == "needs_network" {
                    ProgramDetailActionButton(
                        icon: .arrowDown, title: "Download",
                        disabled: busy,
                        help: "Download ticket detail"
                    ) {
                        Task { await model.select(card, online: true) }
                    }
                    .transition(.relayElement)
                }
                if model.detailErrorMessage != nil {
                    ProgramDetailActionButton(
                        icon: .refreshCw, title: "Retry",
                        disabled: busy,
                        help: "Reload ticket"
                    ) {
                        Task { await model.select(card) }
                    }
                    .transition(.relayElement)
                }
            }

            if let detail, detail.availability != "available" {
                ProgramDetailNotice(message: detail.recovery ?? unavailableExplanation(detail.availability))
                    .transition(.relayElement)
            }
            if let error = model.detailErrorMessage {
                ProgramDetailNotice(message: error)
                    .transition(.relayElement)
            }

            BoardOverlayScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if detail == nil, model.detailErrorMessage == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Opening ticket…")
                                .font(AppTypography.font(.supporting))
                                .foregroundStyle(ProgramBoardStyle.mutedText)
                        }
                        .transition(.relayReplacing(.element))
                    } else if let markdown = detail?.markdown {
                        Text(markdown)
                            .font(AppTypography.monospacedFont(size: 12, weight: .regular))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.relayText)
                    }
                    dependencySummary
                    attachmentSummary
                }
            }
            // RR-550: the ticket stays above the chat, as a note's summary
            // does; a long one scrolls on its own.
            .frame(minHeight: 120, maxHeight: 280, alignment: .top)
            .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.detail)
            .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.dependencies)

            NoteChatPanel(
                chat: chat,
                scope: model.chatScope,
                placeholder: "Ask about this ticket",
                hintTitle: "Ask about this ticket",
                hintDetail: "Answers draw on the ticket text available on this Mac."
            )
            .frame(maxHeight: .infinity)
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.detailErrorMessage)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: detail?.availability)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var dependencySummary: some View {
        if let dependencies = model.dependencies {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dependencies")
                    .font(AppTypography.font(.cardHeading))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                if dependencies.dependencies.isEmpty {
                    Text("No dependencies")
                        .font(AppTypography.font(.metadata))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                        .transition(.relayReplacing(.text))
                }
                ForEach(dependencies.dependencies) { dependency in
                    HStack(alignment: .firstTextBaseline) {
                        LucideImage(dependency.satisfied ? .circleCheck : .triangleExclamationPoint, size: 12)
                            .foregroundStyle(dependency.satisfied ? ProgramBoardStyle.green : ProgramBoardStyle.red)
                        Text(dependency.ticketID)
                        Text(dependency.availability.replacingOccurrences(of: "_", with: " ").capitalized)
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                    }
                    .font(AppTypography.font(.metadata))
                    .accessibilityElement(children: .combine)
                    .transition(.relayElement)
                }
            }
            .transition(.relayElement)
        }
    }

    @ViewBuilder
    private var attachmentSummary: some View {
        if let attachments = model.detail?.attachments, !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Attachments")
                    .font(AppTypography.font(.cardHeading))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                ForEach(attachments) { attachment in
                    HStack {
                        LucideImage(.paperclip, size: 12)
                        Text(attachment.displayName)
                        Spacer()
                        if let size = attachment.size { Text(formatBytes(size)) }
                    }
                    .font(AppTypography.font(.metadata))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                    .transition(.relayElement)
                }
                Text("Available after verified detail retrieval; viewing does not restore files.")
                    .font(AppTypography.font(.caption))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
            }
            .transition(.relayElement)
        }
    }

    private func messageStrip(_ message: String, warning: Bool) -> some View {
        RelaySwap(message, style: .text, alignment: .leading) { message in
            Text(message)
                .font(AppTypography.font(.supporting))
                .foregroundStyle(warning ? ProgramBoardStyle.red : ProgramBoardStyle.green)
        }
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

private extension View {
    func historyPanelChrome() -> some View {
        background(BoardDarkSurfaceBackground(cornerRadius: BoardDarkSurfaceStyle.floatingPanelCornerRadius, panelGlass: true))
            .clipShape(RoundedRectangle(cornerRadius: BoardDarkSurfaceStyle.floatingPanelCornerRadius, style: .continuous))
    }
}
