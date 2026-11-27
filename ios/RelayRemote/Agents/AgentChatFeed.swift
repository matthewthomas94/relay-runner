import SwiftUI

/// The selected agent's chat, newest at the bottom. It fades out at its top
/// and bottom edges with an alpha mask on the feed itself, and has no
/// background, so the glows behind the screen show through.
struct AgentChatFeed: View {
    let name: String
    let messages: [ChatMessage]
    var speakingSeq: Int?
    var waiting: AgentsScreenState.WaitingReply?
    var onPlay: () -> Void = {}

    static let topFade: CGFloat = 32
    static let bottomFade: CGFloat = 24

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(messages) { message in
                    row(message)
                        .transition(.relayRise)
                }
                if let waiting {
                    WaitingReplyPanel(name: name, receivedAt: waiting.receivedAt, onPlay: onPlay)
                        .id("waiting")
                        .transition(.relaySurface)
                }
            }
            .padding(.horizontal, RelayMetrics.screenMargin)
            .padding(.top, Self.topFade)
            .padding(.bottom, Self.bottomFade)
            .animation(RelayMotion.enter, value: waiting)
            .animation(RelayMotion.enter, value: messages.count)
            .animation(RelayMotion.enter, value: speakingSeq)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        // Dragging the chat down pulls the keyboard away with it.
        .scrollDismissesKeyboard(.interactively)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.topFade)
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.bottomFade)
            }
        }
    }

    @ViewBuilder
    private func row(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                Text(message.text)
                    .relayTextStyle(.body)
                    .foregroundStyle(RelayColor.neutral10)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RelayGlassBackground(glass: .selected,
                                                     shape: RoundedRectangle(cornerRadius: 16, style: .continuous)))
                meta("You · \(Self.time(message.date))")
            }
            .padding(.leading, 72)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .agent:
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .relayTextStyle(.body)
                    .foregroundStyle(RelayColor.neutral10)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .relayGlass(.panel)
                meta(message.seq != nil && message.seq == speakingSeq
                     ? "\(name) · speaking" : "\(name) · \(Self.time(message.date))")
                    .contentTransition(.opacity)
            }
            .padding(.trailing, 51)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .status:
            HStack(spacing: 10) {
                LucideImage(.ticket, size: 18)
                Text(message.text).relayTextStyle(.caption)
            }
            .foregroundStyle(RelayColor.neutral7)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func meta(_ text: String) -> some View {
        Text(text)
            .relayTextStyle(.caption)
            .foregroundStyle(RelayColor.neutral7)
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }
}

/// "New reply from <agent>" in Queue mode, with a secondary Play.
struct WaitingReplyPanel: View {
    let name: String
    let receivedAt: Date
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("New reply from \(name)")
                    .relayTextStyle(.body)
                    .foregroundStyle(RelayColor.neutral10)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Queued · \(Self.age(from: receivedAt, to: context.date))")
                        .relayTextStyle(.caption)
                        .foregroundStyle(RelayColor.neutral7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onPlay) { RelayButtonLabel("Play", icon: .play) }
                .buttonStyle(RelayButtonStyle(role: .secondary, height: 40))
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .relayGlass(.panel)
    }

    static func age(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }
}
