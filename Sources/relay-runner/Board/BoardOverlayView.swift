import AppKit
import SwiftUI

/// Observable model driving the board view. The controller mutates `theme`
/// from a poll timer so the panel glow updates live as the particle field
/// changes (recording starts → red, playback starts → purple).
@Observable
final class BoardViewModel {
    var tickets: [Ticket] = []
    var theme: ParticleFieldRenderer.Theme?
}

struct BoardOverlayView: View {
    @Bindable var model: BoardViewModel
    let onDismiss: () -> Void

    private let columns: [BoardColumnSpec] = [
        BoardColumnSpec(status: .backlog,    title: "Backlog"),
        BoardColumnSpec(status: .ready,      title: "Ready"),
        BoardColumnSpec(status: .inProgress, title: "In progress"),
        BoardColumnSpec(status: .done,       title: "Done"),
    ]

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { onDismiss() }
            .overlay(alignment: .top) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns) { spec in
                        BoardColumnPanel(
                            spec: spec,
                            tickets: model.tickets.filter { $0.status == spec.status },
                            theme: model.theme
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
    let theme: ParticleFieldRenderer.Theme?

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
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(width: 358, height: 633, alignment: .topLeading)
        .background(PillGlassBackground(cornerRadius: 16))
        // Theme-aware glow. Mirrors TranscriptionPill.applyTheme: same
        // primary-shadow colors for STT (red) and TTS (purple). With no
        // particle theme active we drop to a neutral dark shadow — depth
        // without the saturated glow.
        .shadow(
            color: BoardColumnPanel.shadowColor(for: theme),
            radius: 20,
            x: 0,
            y: -6
        )
        .animation(.easeInOut(duration: 0.4), value: theme)
        .onTapGesture { /* swallow taps on the panel so they don't dismiss */ }
    }

    private static func shadowColor(for theme: ParticleFieldRenderer.Theme?) -> Color {
        switch theme {
        case .stt:
            // TranscriptionPill STT primaryShadowColor — #F43C09
            return Color(.sRGB, red: 244 / 255, green: 60 / 255, blue: 9 / 255, opacity: 0.20)
        case .tts:
            // TranscriptionPill TTS primaryShadowColor — #2811D0
            return Color(.sRGB, red: 40 / 255, green: 17 / 255, blue: 208 / 255, opacity: 0.20)
        case nil:
            // No particle field active — neutral drop shadow, no color glow.
            return Color.black.opacity(0.45)
        }
    }
}

/// Replicates the TranscriptionPill's "liquid glass" layer stack (TTS theme)
/// so columns and cards share the exact same visual language as the pill.
/// Mirrors values from `TranscriptionPill.init` — keep in sync if those change.
private struct PillGlassBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            // 1. Visual-effect blur of what's behind (underWindowBackground material).
            VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow)
            // 2. Dark base fill — NSColor(white: 0, alpha: 0.45).
            Color.black.opacity(0.45)
            // 3. Subtle vertical gradient overlay (bottom darker, top hint of light).
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(white: 0.97).opacity(0.10),
                    Color(white: 0).opacity(0.10),
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            // 4. Top specular highlight — 1 px of white at the top edge.
            VStack(spacing: 0) {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(0.10),
                        Color.white.opacity(0.0),
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1)
                Spacer(minLength: 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            // 5. Border gradient (white at top, fading to transparent).
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.10), location: 0.0),
                            .init(color: Color.white.opacity(0.0),  location: 0.9),
                            .init(color: Color.white.opacity(0.0),  location: 1.0),
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
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
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PillGlassBackground(cornerRadius: 16))
        .opacity(ticket.canceled ? 0.45 : 1.0)
    }
}
