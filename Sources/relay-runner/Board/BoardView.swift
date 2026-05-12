import SwiftUI

struct BoardView: View {
    @Bindable var appState: AppState

    private let columns: [ColumnSpec] = [
        ColumnSpec(status: "backlog",     title: "Backlog"),
        ColumnSpec(status: "ready",       title: "Ready"),
        ColumnSpec(status: "in_progress", title: "In Progress"),
        ColumnSpec(status: "done",        title: "Done"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(columns) { column in
                BoardColumn(spec: column, tickets: [])
            }
        }
        .padding(20)
        .frame(minWidth: 920, minHeight: 520)
        .background(Color.black.opacity(0.85))
    }
}

private struct ColumnSpec: Identifiable {
    let status: String
    let title: String
    var id: String { status }
}

private struct BoardColumn: View {
    let spec: ColumnSpec
    let tickets: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spec.title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 4)

            if tickets.isEmpty {
                EmptyColumnPlaceholder(columnTitle: spec.title)
            } else {
                // Cards land here in a later commit.
                EmptyView()
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
