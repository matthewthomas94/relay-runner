import SwiftUI

struct BoardView: View {
    @Bindable var appState: AppState
    @State private var tickets: [Ticket] = []
    @State private var project: ProjectResolver.LinkedProject?
    @State private var loaded = false

    private let columns: [ColumnSpec] = [
        ColumnSpec(status: .backlog,    title: "Backlog"),
        ColumnSpec(status: .ready,      title: "Ready"),
        ColumnSpec(status: .inProgress, title: "In Progress"),
        ColumnSpec(status: .done,       title: "Done"),
    ]

    var body: some View {
        Group {
            if !loaded {
                ProgressView().controlSize(.small)
            } else if project == nil {
                EmptyStateView(
                    headline: "No linked project",
                    detail: "Run /relay-link-project from a Claude Code session in your repo to link it to the orchestrator."
                )
            } else if tickets.isEmpty {
                EmptyStateView(
                    headline: "No tickets in .orchestrator/",
                    detail: "Create files at .orchestrator/<id>.md in this repo. See docs/specs/orchestrator-tickets.md."
                )
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(columns) { column in
                        BoardColumn(
                            spec: column,
                            tickets: tickets.filter { $0.status == column.status }
                        )
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 920, minHeight: 520)
        .background(Color.black.opacity(0.85))
        .navigationTitle(project.map { $0.repoPath.lastPathComponent } ?? "Board")
        .task {
            await load()
        }
    }

    private func load() async {
        let resolved = ProjectResolver.resolve()
        let scanned = resolved.map { ProjectResolver.scanTickets(in: $0) } ?? []
        await MainActor.run {
            self.project = resolved
            self.tickets = scanned
            self.loaded = true
        }
    }
}

private struct ColumnSpec: Identifiable {
    let status: Ticket.Status
    let title: String
    var id: String { status.rawValue }
}

private struct BoardColumn: View {
    let spec: ColumnSpec
    let tickets: [Ticket]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(spec.title)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                Text("\(tickets.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(.white.opacity(0.08))
                    )
                Spacer()
            }
            .padding(.horizontal, 4)

            if tickets.isEmpty {
                EmptyColumnPlaceholder(columnTitle: spec.title)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(tickets) { ticket in
                            TicketCard(ticket: ticket)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct TicketCard: View {
    let ticket: Ticket

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ticket.id)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                PriorityBadge(priority: ticket.priority)
            }
            Text(ticket.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
        .opacity(ticket.canceled ? 0.45 : 1.0)
        .overlay(alignment: .topLeading) {
            if ticket.canceled {
                Text("CANCELED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.1)))
                    .padding(8)
            }
        }
    }
}

private struct PriorityBadge: View {
    let priority: Ticket.Priority

    private var color: Color {
        switch priority {
        case .urgent: return Color(red: 244 / 255, green: 60 / 255, blue: 9 / 255)
        case .high:   return Color(red: 242 / 255, green: 170 / 255, blue: 12 / 255)
        case .medium: return Color(red: 226 / 255, green: 232 / 255, blue: 240 / 255).opacity(0.5)
        case .low:    return Color.white.opacity(0.25)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

private struct EmptyColumnPlaceholder: View {
    let columnTitle: String

    var body: some View {
        Text("No tickets in \(columnTitle)")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
    }
}

private struct EmptyStateView: View {
    let headline: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Text(headline)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
