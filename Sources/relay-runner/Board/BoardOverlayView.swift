import SwiftUI

struct BoardOverlayView: View {
    let tickets: [Ticket]
    let onDismiss: () -> Void

    private let columns: [BoardColumnSpec] = [
        BoardColumnSpec(status: .backlog,    title: "Backlog"),
        BoardColumnSpec(status: .ready,      title: "Ready"),
        BoardColumnSpec(status: .inProgress, title: "In progress"),
        BoardColumnSpec(status: .done,       title: "Done"),
    ]

    var body: some View {
        // Outer tap layer captures clicks that miss the columns — dismiss.
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { onDismiss() }
            .overlay(alignment: .top) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns) { spec in
                        BoardColumnPanel(
                            spec: spec,
                            tickets: tickets.filter { $0.status == spec.status }
                        )
                    }
                }
                .padding(.top, 89)
            }
            .ignoresSafeArea()
    }
}

struct BoardColumnSpec: Identifiable {
    let status: Ticket.Status
    let title: String
    var id: String { status.rawValue }
}

private struct BoardColumnPanel: View {
    let spec: BoardColumnSpec
    let tickets: [Ticket]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(spec.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 1.0))
                .padding(.bottom, 4)

            if tickets.isEmpty {
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(tickets) { ticket in
                            TicketCard(ticket: ticket)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .frame(width: 358, height: 633, alignment: .topLeading)
        .background(BoardPanelBackground())
        .shadow(color: Color(.sRGB, red: 198 / 255, green: 191 / 255, blue: 249 / 255, opacity: 0.10), radius: 6, x: 0, y: 8)
        .shadow(color: Color(.sRGB, red: 40 / 255, green: 17 / 255, blue: 208 / 255, opacity: 0.25), radius: 12, x: 0, y: 8)
        .onTapGesture { /* swallow taps on the panel so they don't dismiss */ }
    }
}

/// Glass + tint background. Approximates the Figma `Glass` (radius 8) +
/// dark-purple tint visible in the design. NSVisualEffectView would be a more
/// authentic match — swap in a polish pass if material isn't close enough.
private struct BoardPanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct TicketCard: View {
    let ticket: Ticket

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ticket.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 1.0))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let description = ticket.description {
                Text(description)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.65))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.sRGB, red: 132 / 255, green: 110 / 255, blue: 240 / 255, opacity: 0.30))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .opacity(ticket.canceled ? 0.45 : 1.0)
    }
}
