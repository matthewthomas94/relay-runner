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
                        errorMessage: model.errorMessage,
                        isLoading: model.isLoading,
                        theme: model.theme,
                        onRefresh: onRefresh,
                        onDismiss: onDismiss
                    )
                    ProgramWorkColumnPanel(
                        title: "Active",
                        emptyText: "No active runs",
                        tint: ProgramBoardStyle.green,
                        items: snapshot.activeWork.items,
                        theme: model.theme
                    )
                    ProgramWorkColumnPanel(
                        title: "Ready",
                        emptyText: "No ready work",
                        tint: ProgramBoardStyle.purple,
                        items: snapshot.readyWork.items,
                        theme: model.theme
                    )
                    ProgramWorkColumnPanel(
                        title: "Blocked",
                        emptyText: "No blocked work",
                        tint: ProgramBoardStyle.red,
                        items: snapshot.blockedWork.items,
                        theme: model.theme
                    )
                    ProgramWorkColumnPanel(
                        title: "Awaiting merge",
                        emptyText: "No merge queue",
                        tint: ProgramBoardStyle.amber,
                        items: snapshot.awaitingMerge.items,
                        theme: model.theme
                    )
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
    let errorMessage: String?
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

            if let errorMessage {
                ProgramErrorStrip(message: errorMessage)
            }

            ProgramMetricGrid(snapshot: snapshot)

            ProgramSectionHeader(title: "Projects", count: snapshot.projects.count)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.projects) { item in
                        ProgramProjectCard(item: item)
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
            ProgramMetricTile(label: "Projects", value: "\(snapshot.projectCount)", tint: ProgramBoardStyle.blue)
            ProgramMetricTile(label: "Active", value: "\(snapshot.activeWork.items.count)", tint: ProgramBoardStyle.green)
            ProgramMetricTile(label: "Ready", value: "\(snapshot.readyWork.items.count)", tint: ProgramBoardStyle.purple)
            ProgramMetricTile(label: "Blocked", value: "\(snapshot.blockedWork.items.count)", tint: ProgramBoardStyle.red)
            ProgramMetricTile(label: "Merge", value: "\(snapshot.awaitingMerge.items.count)", tint: ProgramBoardStyle.amber)
        }
    }
}

private struct ProgramMetricTile: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .opacity(0.9)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                    .lineLimit(1)
            }
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
    }
}

private struct ProgramProjectCard: View {
    let item: ProgramStatusItem

    var body: some View {
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

            HStack(spacing: 6) {
                ProjectCount(label: "open", value: item.openTickets)
                ProjectCount(label: "active", value: item.activeRuns)
                ProjectCount(label: "blocked", value: item.blocked)
                ProjectCount(label: "merge", value: item.awaitingMerge)
            }

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
        .shadow(color: Color.black.opacity(0.40), radius: 8, x: 0, y: 3)
    }
}

private struct ProjectCount: View {
    let label: String
    let value: Int?

    var body: some View {
        Text("\(value ?? 0) \(label)")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(ProgramBoardStyle.secondaryText)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

private struct ProgramWorkColumnPanel: View {
    let title: String
    let emptyText: String
    let tint: Color
    let items: [ProgramStatusItem]
    let theme: ParticleFieldRenderer.Theme?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
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

            if items.isEmpty {
                ProgramColumnEmpty(text: emptyText)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            ProgramWorkCard(item: item)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

private struct ProgramColumnEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProgramBoardStyle.mutedText)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .padding(.horizontal, 10)
            .background(ProgramCardBackground(cornerRadius: 16))
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
