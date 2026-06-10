import SwiftUI

struct ProgramBoardOverlayView: View {
    @Bindable var model: ProgramBoardViewModel
    let onDismiss: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                ProgramBoardContent(
                    model: model,
                    onRefresh: onRefresh,
                    onDismiss: onDismiss
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

    var body: some View {
        if let snapshot = model.snapshot {
            if snapshot.hasRegisteredProjects {
                HStack(alignment: .top, spacing: 12) {
                    ProgramOverviewColumn(
                        snapshot: snapshot,
                        selectedProjectPath: model.selectedProjectPath,
                        selectedScopeTitle: model.selectedScopeTitle,
                        errorMessage: model.errorMessage,
                        isLoading: model.isLoading,
                        theme: model.theme,
                        onSelectAll: model.selectAllProjects,
                        onSelectProject: model.selectProject,
                        onRefresh: onRefresh,
                        onDismiss: onDismiss
                    )
                    ForEach(ProgramBoardLane.allCases) { lane in
                        ProgramWorkColumnPanel(
                            title: lane.title,
                            emptyText: lane.emptyText,
                            items: model.ticketItems(in: lane),
                            showsProjectContext: model.isAllSelected,
                            theme: model.theme
                        )
                    }
                }
            } else {
                ProgramStatePanel(
                    title: "No registered projects",
                    detail: snapshot.summary.message,
                    isLoading: model.isLoading,
                    theme: model.theme,
                    onRefresh: onRefresh,
                    onDismiss: onDismiss
                )
            }
        } else if model.isLoading {
            ProgramStatePanel(
                title: "Loading program status",
                detail: nil,
                isLoading: true,
                theme: model.theme,
                onRefresh: onRefresh,
                onDismiss: onDismiss
            )
        } else {
            ProgramStatePanel(
                title: "Program status unavailable",
                detail: model.errorMessage,
                isLoading: false,
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
    let isLoading: Bool
    let theme: ParticleFieldRenderer.Theme?
    let onSelectAll: () -> Void
    let onSelectProject: (String) -> Void
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgramBoardTitleBar(
                isLoading: isLoading,
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
                LazyVStack(alignment: .leading, spacing: 6) {
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
    let isLoading: Bool
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Program Board")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                Text("Workspace status")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
            }
            Spacer(minLength: 0)
            if isLoading {
                ProgressView()
                    .scaleEffect(0.62)
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            }
            ProgramIconButton(systemName: "arrow.clockwise", help: "Refresh program status", action: onRefresh)
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
    let title: String
    let emptyText: String
    let items: [ProgramStatusItem]
    let showsProjectContext: Bool
    let theme: ParticleFieldRenderer.Theme?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
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
                    ProgramColumnEmpty(text: emptyText)
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            ProgramWorkCard(item: item, showsProjectContext: showsProjectContext)
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
    let showsProjectContext: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.ticketID ?? "No ticket")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                            .lineLimit(1)
                        Text(item.title ?? "Untitled work")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ProgramBoardStyle.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if showsProjectContext {
                        ProjectContextLine(project: item.project)
                    }
                }
                Spacer(minLength: 0)
                if let priority = item.priority, !priority.isEmpty {
                    ProgramInlineBadge(label: priority.displayLabel)
                }
            }

            if item.isAwaitingMerge || item.hasActiveWorker {
                HStack(alignment: .center, spacing: 6) {
                    if item.isAwaitingMerge {
                        ProgramInlineBadge(label: "Awaiting merge")
                    }
                    if item.hasActiveWorker {
                        ProgramInlineBadge(label: "Active")
                    }
                    Spacer(minLength: 0)
                }
            }

            let details = detailParts
            if !details.isEmpty {
                Text(details.joined(separator: "  "))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                    .lineLimit(2)
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
        .shadow(color: Color.black.opacity(0.40), radius: 8, x: 0, y: 3)
    }

    private var detailParts: [String] {
        var parts: [String] = []
        if let status = item.status {
            parts.append(status.displayLabel)
        }
        if let runState = item.runState,
           runState.programStateKey != (item.status?.programStateKey ?? "") {
            parts.append(runState.displayLabel)
        } else if item.status == nil, let ticketState = item.ticketState {
            parts.append(ticketState.displayLabel)
        }
        if let runID = item.runID {
            parts.append("run \(runID)")
        } else if let branch = item.branch, !branch.isEmpty {
            parts.append(branch)
        }
        if let provider = item.provider {
            parts.append(provider)
        }
        if !item.blockedBy.isEmpty {
            parts.append("blocked by \(item.blockedBy.joined(separator: ", "))")
        }
        if !item.dependsOn.isEmpty {
            parts.append("depends on \(item.dependsOn.joined(separator: ", "))")
        }
        if let activity = item.activity, !activity.isEmpty {
            parts.append(activity)
        }
        return parts
    }
}

private struct ProjectContextLine: View {
    let project: ProgramStatusProject?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project?.name ?? "Unknown project")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .lineLimit(1)
            Text(project?.path ?? "unknown")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
    }
}

private struct ProgramStatePanel: View {
    let title: String
    let detail: String?
    let isLoading: Bool
    let theme: ParticleFieldRenderer.Theme?
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgramBoardTitleBar(
                isLoading: isLoading,
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

private extension ProgramStatusItem {
    var isAwaitingMerge: Bool {
        [status, runState, ticketState]
            .compactMap { $0?.programStateKey }
            .contains("awaiting_merge")
    }

    var hasActiveWorker: Bool {
        [status, runState, ticketState]
            .compactMap { $0?.programStateKey }
            .contains("active")
    }
}

private enum ProgramBoardStyle {
    static let primaryText = Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 1.0)
    static let secondaryText = Color(.sRGB, red: 203 / 255, green: 213 / 255, blue: 225 / 255, opacity: 0.78)
    static let mutedText = Color(.sRGB, red: 148 / 255, green: 163 / 255, blue: 184 / 255, opacity: 0.82)
    static let red = Color(.sRGB, red: 244 / 255, green: 60 / 255, blue: 9 / 255, opacity: 1.0)
}

private extension String {
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
