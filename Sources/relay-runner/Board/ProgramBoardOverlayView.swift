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

            VStack(alignment: .leading, spacing: 14) {
                ProgramBoardHeader(
                    isLoading: model.isLoading,
                    onRefresh: onRefresh,
                    onDismiss: onDismiss
                )

                if let error = model.errorMessage, model.snapshot != nil {
                    ProgramErrorStrip(message: error)
                }

                ProgramBoardContent(model: model)
            }
            .padding(18)
            .frame(width: 1180, height: 684, alignment: .topLeading)
            .background(ProgramBoardPanelBackground(theme: model.theme))
            .contentShape(Rectangle())
            .onTapGesture { }
        }
        .ignoresSafeArea()
    }
}

private struct ProgramBoardHeader: View {
    let isLoading: Bool
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Program Board")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                Text("Graphify Core")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
            }
            Spacer(minLength: 0)
            if isLoading {
                ProgressView()
                    .scaleEffect(0.62)
                    .controlSize(.small)
            }
            ProgramIconButton(systemName: "arrow.clockwise", help: "Refresh program status", action: onRefresh)
            ProgramIconButton(systemName: "xmark", help: "Close Program Board", action: onDismiss)
        }
    }
}

private struct ProgramBoardContent: View {
    @Bindable var model: ProgramBoardViewModel

    var body: some View {
        if let snapshot = model.snapshot {
            if snapshot.hasRegisteredProjects {
                VStack(alignment: .leading, spacing: 14) {
                    ProgramMetricBand(snapshot: snapshot)
                    HStack(alignment: .top, spacing: 14) {
                        ProgramProjectTable(projects: snapshot.projects)
                            .frame(width: 420)
                        ProgramWorkTable(snapshot: snapshot)
                    }
                    if !snapshot.hasActiveWork {
                        Text("No active work across registered projects.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                    }
                }
            } else {
                ProgramEmptyState(
                    title: "No registered projects",
                    detail: snapshot.summary.message
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if model.isLoading {
            ProgramEmptyState(title: "Loading program status", detail: nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgramEmptyState(
                title: "Program status unavailable",
                detail: model.errorMessage
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProgramMetricBand: View {
    let snapshot: ProgramDashboardSnapshot

    var body: some View {
        HStack(spacing: 0) {
            ProgramMetric(label: "Projects", value: "\(snapshot.projectCount)", tint: ProgramBoardStyle.blue)
            ProgramMetricDivider()
            ProgramMetric(label: "Active", value: "\(snapshot.activeWork.items.count)", tint: ProgramBoardStyle.green)
            ProgramMetricDivider()
            ProgramMetric(label: "Ready", value: "\(snapshot.readyWork.items.count)", tint: ProgramBoardStyle.purple)
            ProgramMetricDivider()
            ProgramMetric(label: "Blocked", value: "\(snapshot.blockedWork.items.count)", tint: ProgramBoardStyle.red)
            ProgramMetricDivider()
            ProgramMetric(label: "Awaiting merge", value: "\(snapshot.awaitingMerge.items.count)", tint: ProgramBoardStyle.amber)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.24))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct ProgramMetric: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.primaryText)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProgramMetricDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 30)
            .padding(.horizontal, 12)
    }
}

private struct ProgramProjectTable: View {
    let projects: [ProgramStatusItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgramSectionHeader(title: "Projects", count: projects.count)
            ProgramTableSurface {
                if projects.isEmpty {
                    ProgramColumnEmpty(text: "No registered projects")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(projects) { item in
                                ProgramProjectRow(item: item)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ProgramProjectRow: View {
    let item: ProgramStatusItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.project?.name ?? "Unknown project")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !item.providers.isEmpty {
                    Text(item.providers.joined(separator: ", "))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            Text(item.project?.path ?? "unknown")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                ProjectCount(label: "open", value: item.openTickets)
                ProjectCount(label: "active", value: item.activeRuns)
                ProjectCount(label: "blocked", value: item.blocked)
                ProjectCount(label: "merge", value: item.awaitingMerge)
                if let stale = item.staleRuns, stale > 0 {
                    ProjectCount(label: "stale", value: stale)
                }
            }
            if !item.providerHealth.isEmpty {
                Text(item.providerHealth.joined(separator: "  "))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProgramBoardStyle.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
        }
    }
}

private struct ProjectCount: View {
    let label: String
    let value: Int?

    var body: some View {
        Text("\(value ?? 0) \(label)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(ProgramBoardStyle.secondaryText)
            .monospacedDigit()
            .lineLimit(1)
    }
}

private struct ProgramWorkTable: View {
    let snapshot: ProgramDashboardSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgramSectionHeader(title: "Work", count: workCount)
            ProgramTableSurface {
                HStack(alignment: .top, spacing: 0) {
                    ProgramWorkColumn(
                        title: "Active",
                        emptyText: "No active runs",
                        tint: ProgramBoardStyle.green,
                        items: snapshot.activeWork.items
                    )
                    ProgramVerticalDivider()
                    ProgramWorkColumn(
                        title: "Ready",
                        emptyText: "No ready work",
                        tint: ProgramBoardStyle.purple,
                        items: snapshot.readyWork.items
                    )
                    ProgramVerticalDivider()
                    ProgramWorkColumn(
                        title: "Blocked",
                        emptyText: "No blocked work",
                        tint: ProgramBoardStyle.red,
                        items: snapshot.blockedWork.items
                    )
                    ProgramVerticalDivider()
                    ProgramWorkColumn(
                        title: "Awaiting",
                        emptyText: "No merge queue",
                        tint: ProgramBoardStyle.amber,
                        items: snapshot.awaitingMerge.items
                    )
                }
            }
        }
    }

    private var workCount: Int {
        snapshot.activeWork.items.count +
            snapshot.readyWork.items.count +
            snapshot.blockedWork.items.count +
            snapshot.awaitingMerge.items.count
    }
}

private struct ProgramWorkColumn: View {
    let title: String
    let emptyText: String
    let tint: Color
    let items: [ProgramStatusItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                Spacer(minLength: 0)
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            }

            if items.isEmpty {
                ProgramColumnEmpty(text: emptyText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            ProgramWorkRow(item: item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ProgramWorkRow: View {
    let item: ProgramStatusItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.ticketID ?? "No ticket")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                    .lineLimit(1)
                Text(item.title ?? "Untitled work")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                    .lineLimit(2)
            }
            Text(item.project?.name ?? "Unknown project")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .lineLimit(1)

            let details = detailParts
            if !details.isEmpty {
                Text(details.joined(separator: "  "))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
        }
    }

    private var detailParts: [String] {
        var parts: [String] = []
        if let status = item.status ?? item.runState ?? item.ticketState {
            parts.append(status.displayLabel)
        }
        if let runID = item.runID {
            parts.append("run \(runID)")
        }
        if let provider = item.provider {
            parts.append(provider)
        }
        if !item.blockedBy.isEmpty {
            parts.append("blocked by \(item.blockedBy.joined(separator: ", "))")
        }
        if let activity = item.activity, !activity.isEmpty {
            parts.append(activity)
        }
        return parts
    }
}

private struct ProgramSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.primaryText)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
    }
}

private struct ProgramTableSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: 500, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ProgramColumnEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProgramBoardStyle.mutedText)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            .padding(.horizontal, 10)
    }
}

private struct ProgramEmptyState: View {
    let title: String
    let detail: String?

    var body: some View {
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
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(ProgramBoardStyle.red.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ProgramBoardStyle.red.opacity(0.25), lineWidth: 0.5)
            )
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
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ProgramVerticalDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 0.5)
            .frame(maxHeight: .infinity)
    }
}

private struct ProgramBoardPanelBackground: View {
    let theme: ParticleFieldRenderer.Theme?

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: shadowColor, radius: 24, x: 0, y: 12)
    }

    private var shadowColor: Color {
        switch theme {
        case .stt:
            return Color(.sRGB, red: 244 / 255, green: 60 / 255, blue: 9 / 255, opacity: 0.20)
        case .tts:
            return Color(.sRGB, red: 96 / 255, green: 165 / 255, blue: 250 / 255, opacity: 0.20)
        case nil:
            return Color.black.opacity(0.55)
        }
    }
}

private enum ProgramBoardStyle {
    static let primaryText = Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 1.0)
    static let secondaryText = Color(.sRGB, red: 203 / 255, green: 213 / 255, blue: 225 / 255, opacity: 0.78)
    static let mutedText = Color(.sRGB, red: 148 / 255, green: 163 / 255, blue: 184 / 255, opacity: 0.82)
    static let green = Color(.sRGB, red: 52 / 255, green: 211 / 255, blue: 153 / 255, opacity: 1.0)
    static let amber = Color(.sRGB, red: 245 / 255, green: 180 / 255, blue: 40 / 255, opacity: 1.0)
    static let red = Color(.sRGB, red: 244 / 255, green: 60 / 255, blue: 9 / 255, opacity: 1.0)
    static let blue = Color(.sRGB, red: 96 / 255, green: 165 / 255, blue: 250 / 255, opacity: 1.0)
    static let purple = Color(.sRGB, red: 198 / 255, green: 191 / 255, blue: 249 / 255, opacity: 1.0)
}

private extension String {
    var displayLabel: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
