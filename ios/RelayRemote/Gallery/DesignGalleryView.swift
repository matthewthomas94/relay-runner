#if DEBUG
import SwiftUI

/// The pages of the reference gallery, each one screen tall for screenshots.
enum GalleryPage: String, CaseIterable, Identifiable {
    case type, controls, modal, glyphs, orbs, listening, playback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .type: return "Type"
        case .controls: return "Controls"
        case .modal: return "Modal"
        case .glyphs: return "Glyph"
        case .orbs: return "Orb"
        case .listening: return "Listening"
        case .playback: return "Playback"
        }
    }
}

/// Debug-only: every design-system component in each of its states, for
/// comparing simulator screenshots with the styles board and screens 21–23.
/// Open it with the `--gallery` or `--gallery=<page>` launch argument.
struct DesignGalleryView: View {
    @State private var page: GalleryPage
    @State private var reveal = 1.0

    init(initialPage: GalleryPage = .type) {
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GalleryPage.allCases) { item in
                        Button(item.title) { page = item }
                            .buttonStyle(RelayButtonStyle(role: item == page ? .primary : .secondary, height: 36))
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 8)
            Group {
                switch page {
                case .type: TypePage()
                case .controls: ControlsPage()
                case .modal: ModalPage()
                case .glyphs: GlyphsPage()
                case .orbs: OrbsPage()
                case .listening: FieldPage(style: .listening, reveal: $reveal)
                case .playback: FieldPage(style: .playback, reveal: $reveal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background {
            ZStack {
                RelayColor.neutral1
                if page == .listening { DotField(style: .listening, reveal: reveal) }
                if page == .playback { DotField(style: .playback, reveal: reveal) }
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(RelayColor.neutral10)
    }
}

private struct GalleryHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).relayTextStyle(.section).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TypePage: View {
    private let swatches: [(String, Color, String)] = [
        ("neutral1", RelayColor.neutral1, "#000000"), ("neutral2", RelayColor.neutral2, "#0c0f13"),
        ("neutral3", RelayColor.neutral3, "#171a1e"), ("neutral4", RelayColor.neutral4, "#212529"),
        ("neutral5", RelayColor.neutral5, "#383e46"), ("neutral7", RelayColor.neutral7, "#889099"),
        ("neutral10", RelayColor.neutral10, "#ffffff"), ("accent2", RelayColor.accent2, "#8070f1"),
        ("success", RelayColor.success, "#34d399"), ("error", RelayColor.error, "#f41509"),
        ("brand", RelayColor.brand, "#f5a15b"),
    ]
    private let styles: [(String, RelayTextStyle, String)] = [
        ("Title XL 32", .titleXL, "Relay Remote"), ("Title L 24", .titleL, "Start a session"),
        ("Card title 18", .cardTitle, "George"), ("Section 16", .section, "Voice"),
        ("Body 16", .body, "Can you cut a new release?"), ("Caption 12", .caption, "Currently working on"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("R/").relayTextStyle(.body).foregroundStyle(RelayColor.brand)
            GalleryHeading("Colour")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                ForEach(swatches, id: \.0) { name, color, hex in
                    VStack(alignment: .leading, spacing: 2) {
                        RoundedRectangle(cornerRadius: 10).fill(color)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RelayColor.neutral4))
                            .frame(height: 36)
                        Text(name).relayTextStyle(.caption)
                        Text(hex).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                    }
                }
            }
            GalleryHeading("Type · Bai Jamjuree")
            ForEach(styles, id: \.0) { label, style, sample in
                HStack(alignment: .firstTextBaseline) {
                    Text(label).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                        .frame(width: 90, alignment: .leading)
                    Text(sample).relayTextStyle(style)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Hero 28/40").relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                    .frame(width: 90, alignment: .leading)
                Text("Let’s start /").relayTextStyle(.hero)
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct ControlsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GalleryHeading("Buttons · 44 pt, radius 12")
            HStack(spacing: 8) {
                Button {} label: { RelayButtonLabel("Start session") }.buttonStyle(.relayPrimary)
                Button {} label: { RelayButtonLabel("Scan pairing code", icon: .qrCode) }.buttonStyle(.relayPrimary)
            }
            HStack(spacing: 8) {
                Button {} label: { RelayButtonLabel("Replay", icon: .rotateCcw) }.buttonStyle(.relaySecondary)
                Button {} label: { RelayButtonLabel("Stop session", icon: .power) }.buttonStyle(.relayDanger)
                Button {} label: { RelayButtonLabel(icon: .x) }.buttonStyle(.relaySecondary)
                    .accessibilityLabel("Close")
            }
            GalleryHeading("Glass panel")
            GlassPanel {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Matthew’s MacBook Pro").relayTextStyle(.body)
                    Text("Connected over Tailscale").relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                }
            }
            GalleryHeading("Banners")
            VStack(spacing: 8) {
                RelayBannerView(banner: RelayBanner(icon: .refreshCw, title: "Reconnecting",
                                                    message: "Trying again in 4 s. Replies wait on your Mac."))
                RelayBannerView(banner: RelayBanner(icon: .wifiOff, title: "Mac unreachable",
                                                    message: "Check Wi-Fi or Tailscale.", isError: true,
                                                    action: .init(title: "Retry") {}))
                RelayBannerView(banner: RelayBanner(icon: .laptop, title: "Relay Runner isn’t running",
                                                    message: "Open Relay Runner on your Mac to start a session."))
                RelayBannerView(banner: RelayBanner(icon: .keyRound, title: "This iPhone needs pairing again",
                                                    message: "Your Mac no longer accepts this device’s key.",
                                                    isError: true, action: .init(title: "Pair") {}))
            }
        }
        .padding(.horizontal, 16)
    }
}

/// RR-551: the modal over a page of rows, short and then long. Starts open;
/// close it with any of its gestures and open it again from the buttons.
private struct ModalPage: View {
    @State private var content: Size? = .short

    private enum Size { case short, long }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GalleryHeading("Modal · glass panel over a 60% scrim")
            HStack(spacing: 8) {
                Button("Short") { content = .short }.buttonStyle(.relaySecondary)
                Button("Long") { content = .long }.buttonStyle(.relaySecondary)
            }
            ForEach(0..<6, id: \.self) { row in
                GlassPanel { Text("A row behind the modal \(row + 1)").relayTextStyle(.body) }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            RelayModal(isPresented: content != nil, onClose: { content = nil }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RR-551 · relay-runner").relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                    Text("A ticket title in the card style").relayTextStyle(.cardTitle)
                    Text("In progress · George").relayTextStyle(.body)
                }
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<(content == .long ? 30 : 2), id: \.self) { line in
                        Text("Body line \(line + 1) inside the scrolling part of the panel.").relayTextStyle(.body)
                    }
                }
            }
        }
    }
}

private struct GlyphsPage: View {
    @State private var splitting = StatusGlyphState.off

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GalleryHeading("Agent status · the four-dot glyph")
            ForEach(StatusGlyphState.allCases, id: \.self) { state in
                HStack(spacing: 10) {
                    StatusGlyph(state: state)
                    Text(StatusGlyph.accessibilityLabel(state)).relayTextStyle(.body)
                }
            }
            GalleryHeading("Coming online: the grey dot splits into four")
            HStack(spacing: 12) {
                ForEach([StatusGlyphState.off, .ready, .working], id: \.self) { state in
                    glyphTile(StatusGlyph(state: state), label: StatusGlyph.accessibilityLabel(state))
                }
                glyphTile(StatusGlyph(state: splitting), label: "Splitting")
            }
            .task {
                // Loops off → ready so the split can be watched and recorded.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.4))
                    splitting = splitting == .off ? .ready : .off
                }
            }
            GalleryHeading("Hero text with chips")
            VStack(spacing: 0) {
                HeroTextView(hero: HeroText(lines: [[.chip(icon: .mic, label: "Hold to talk", style: .primary),
                                                     .text("& say hi")]]))
                HeroTextView(hero: HeroText(lines: [[.text("Tap"), .chip(icon: .square, label: nil, style: .secondary),
                                                     .text("to stop playback")]]))
            }
            GalleryHeading("Icons")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 9), spacing: 12) {
                ForEach(LucideIcon.allCases, id: \.self) { icon in
                    LucideImage(icon, size: 24)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func glyphTile(_ glyph: StatusGlyph, label: String) -> some View {
        VStack(spacing: 6) {
            glyph
                .frame(width: 48, height: 48)
                .relayGlass(.panel, cornerRadius: 12)
            Text(label).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
        }
    }
}

private struct OrbsPage: View {
    var body: some View {
        VStack(spacing: 20) {
            ForEach(Array(AgentOrbState.allCases.enumerated()), id: \.offset) { index, state in
                VStack(spacing: 4) {
                    AgentOrb(state: state, phase: Double(index) * 2.1)
                    Text(state.rawValue.capitalized).relayTextStyle(.cardTitle)
                }
            }
        }
        .padding(.top, 24)
    }
}

/// A state glow's controls; the glow itself fills the screen behind the
/// gallery, at the size it has in the app.
private struct FieldPage: View {
    let style: DotFieldStyle
    @Binding var reveal: Double

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Fade in").relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                Slider(value: $reveal, in: 0...1)
            }
            Text(style == .listening ? "Listening · bottom 32%" : "Playback · bottom 44%")
                .relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
        }
        .padding(.horizontal, 16)
    }
}
#endif
