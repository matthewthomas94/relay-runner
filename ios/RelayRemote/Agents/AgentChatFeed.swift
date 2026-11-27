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

    /// A row of the feed. An agent's reply keeps one identity, its chat
    /// message's id, from the moment it waits as "New reply" to after it
    /// plays, so pressing Play reshapes that one piece of glass into the
    /// bubble instead of swapping one view for another. Not its seq: the
    /// Mac's numbering starts again when it restarts.
    private enum Item: Identifiable {
        case message(ChatMessage)
        case waiting(AgentsScreenState.WaitingReply)

        var id: String {
            switch self {
            case .waiting(let waiting): return waiting.messageID?.uuidString ?? "waiting-\(waiting.seq)"
            case .message(let message): return message.id.uuidString
            }
        }

        /// The agent reply this row shows, waiting or played.
        var reply: ReplyRow.Content? {
            switch self {
            case .waiting(let waiting): return .waiting(waiting)
            case .message(let message): return message.role == .agent ? .reply(message) : nil
            }
        }
    }

    /// The waiting reply stands in for its message, where it is in the chat.
    private var items: [Item] {
        guard let waiting else { return messages.map(Item.message) }
        guard let id = waiting.messageID, messages.contains(where: { $0.id == id }) else {
            return messages.map(Item.message) + [.waiting(waiting)]
        }
        return messages.map { $0.id == id ? .waiting(waiting) : .message($0) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                // Only the newest reply with the playing seq: an older one may
                // share it from before the Mac restarted.
                let speakingID = speakingSeq.flatMap { seq in messages.last(where: { $0.seq == seq })?.id }
                ForEach(items) { item in
                    Group {
                        // One branch for every agent reply, so a reply keeps
                        // its view (and its glass) when it changes state.
                        if let reply = item.reply {
                            ReplyRow(content: reply, name: name,
                                     speaking: item.id == speakingID?.uuidString, onPlay: onPlay)
                        } else if case .message(let message) = item {
                            row(message)
                        }
                    }
                    // New rows (and a new "New reply") rise in from below.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 24))
                            .combined(with: .scale(scale: 0.98, anchor: .bottom)),
                        removal: .opacity))
                }
            }
            .padding(.horizontal, RelayMetrics.screenMargin)
            .padding(.top, Self.topFade)
            .padding(.bottom, Self.bottomFade)
            .animation(Self.feedChange, value: FeedChange(count: messages.count, waiting: waiting?.seq))
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
                    .modifier(FeedGlass(glass: .selected))
                meta("You · \(Self.time(message.date))")
            }
            .padding(.leading, 72)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .agent:
            EmptyView()
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

    /// A little bounce, so the glass settles like liquid rather than sliding.
    static let feedChange = Animation.spring(duration: 0.45, bounce: 0.22)

    private struct FeedChange: Equatable {
        let count: Int
        let waiting: Int?
    }
}

/// An agent's reply: first the "New reply" panel with Play, then the bubble.
/// Both live in one glass shape, so Play stretches and settles that glass
/// from the panel's size to the bubble's on a springy animation while the
/// panel's label and button drop out and the reply's text fades in.
private struct ReplyRow: View {
    enum Content {
        case waiting(AgentsScreenState.WaitingReply)
        case reply(ChatMessage)

        var seq: Int? {
            switch self {
            case .waiting(let waiting): return waiting.seq
            case .reply(let message): return message.seq
            }
        }
    }

    let content: Content
    let name: String
    let speaking: Bool
    let onPlay: () -> Void

    /// How long the card's contents take to leave before the reply arrives.
    static let swapOut: TimeInterval = 0.16

    private var isWaiting: Bool {
        if case .waiting = content { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                switch content {
                case .waiting(let waiting):
                    WaitingReplyContent(name: name, receivedAt: waiting.receivedAt, onPlay: onPlay)
                        // The desktop's swap, which never overlaps: the card's
                        // contents blur out first, then the reply blurs in.
                        .transition(.asymmetric(
                            insertion: .relaySurface.animation(RelayMotion.enter),
                            removal: .relaySurface.animation(.easeIn(duration: Self.swapOut))))
                case .reply(let message):
                    Text(message.text)
                        .relayTextStyle(.body)
                        .foregroundStyle(RelayColor.neutral10)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        // Only seen when Play turns the panel into this bubble.
                        .transition(.asymmetric(
                            insertion: .relaySurface.animation(RelayMotion.enter.delay(Self.swapOut)),
                            removal: .identity))
                }
            }
            .modifier(FeedGlass())
            if case .reply(let message) = content {
                Text(speaking ? "\(name) · speaking" : "\(name) · \(AgentChatFeed.time(message.date))")
                    .relayTextStyle(.caption)
                    .foregroundStyle(RelayColor.neutral7)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
        }
        .padding(.trailing, isWaiting ? 0 : 51)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "New reply from <agent>" in Queue mode, with a secondary Play, on its
/// own glass (the tutorial uses it).
struct WaitingReplyPanel: View {
    let name: String
    let receivedAt: Date
    let onPlay: () -> Void

    var body: some View {
        WaitingReplyContent(name: name, receivedAt: receivedAt, onPlay: onPlay)
            .modifier(FeedGlass())
    }
}

/// The "New reply" panel's label and Play button, without the glass.
struct WaitingReplyContent: View {
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
    }

    static func age(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }
}

/// A chat surface's glass (radius 16): the Figma fill over Liquid Glass,
/// applied to the content itself so the text always draws above it.
private struct FeedGlass: ViewModifier {
    var glass: RelayGlass = .panel

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: RelayMetrics.panelRadius, style: .continuous)
        content
            .background(shape.fill(glass.tint))
            .glassEffect(RelayGlass.material, in: shape)
            .environment(\.colorScheme, .dark)
    }
}
