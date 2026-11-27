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

    /// Play morphs the "New reply" panel into the reply's bubble: the glass
    /// reshapes from one to the other, the panel's label and button fade out
    /// fast, and the reply's text fades in as the glass settles.
    @Namespace private var replyMorph
    /// The last reply shown as "New reply", so its bubble knows to arrive
    /// out of the panel instead of rising in on its own.
    @State private var lastWaitingSeq: Int?
    /// Replies whose text already faded in, so scrolling back never replays it.
    @State private var arrived: Set<Int> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(messages) { message in
                    row(message)
                        .transition(isMorphing(message) ? .identity : .relayRise)
                }
                if let waiting {
                    WaitingReplyPanel(name: name, receivedAt: waiting.receivedAt, onPlay: onPlay,
                                      glassID: Self.morphID(waiting.seq), namespace: replyMorph)
                        .id("waiting")
                        // It rises in from the bottom of the chat, and on
                        // Play its glass becomes the reply's bubble.
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 24))
                                .combined(with: .scale(scale: 0.98, anchor: .bottom))
                                .animation(RelayMotion.move),
                            removal: .opacity.animation(.easeOut(duration: 0.12))))
                }
            }
            .padding(.horizontal, RelayMetrics.screenMargin)
            .padding(.top, Self.topFade)
            .padding(.bottom, Self.bottomFade)
            // One animation for a feed change, so Play's two halves (the
            // panel leaving, the bubble arriving) move as one.
            .animation(RelayMotion.move, value: FeedChange(count: messages.count, waiting: waiting?.seq))
            .animation(RelayMotion.enter, value: speakingSeq)
        }
        .onChange(of: waiting?.seq, initial: true) { _, seq in
            if let seq { lastWaitingSeq = seq }
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
                    .modifier(MorphArrival(active: isMorphing(message)) {
                        if let seq = message.seq { arrived.insert(seq) }
                    })
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        RelayGlassBackground(shape: RoundedRectangle(cornerRadius: RelayMetrics.panelRadius,
                                                                     style: .continuous))
                            .modifier(ReplyMorph(id: isMorphing(message) ? message.seq.map(Self.morphID) : nil,
                                                 restingID: message.id.uuidString, namespace: replyMorph))
                    }
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

    static func morphID(_ seq: Int) -> String { "reply-\(seq)" }

    /// The reply that was just "New reply", arriving out of its panel as the
    /// panel goes. A newer reply taking over the panel leaves the older one to
    /// rise in as a plain bubble.
    private func isMorphing(_ message: ChatMessage) -> Bool {
        guard waiting == nil, let seq = message.seq, message.role == .agent else { return false }
        return seq == lastWaitingSeq && !arrived.contains(seq)
    }

    private struct FeedChange: Equatable {
        let count: Int
        let waiting: Int?
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
    /// Ties the panel's glass to its reply's bubble for the Play morph.
    var glassID: String?
    var namespace: Namespace.ID?

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
        .background {
            RelayGlassBackground(shape: RoundedRectangle(cornerRadius: RelayMetrics.panelRadius,
                                                         style: .continuous))
                .modifier(ReplyMorph(id: glassID, restingID: "waiting", namespace: namespace))
        }
    }

    static func age(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }
}

/// Ties a reply's bubble to its "New reply" panel so pressing Play morphs one
/// into the other; replies without a seq are left alone.
private struct ReplyMorph: ViewModifier {
    let id: String?
    /// An id no other view shares, used while not morphing, so the glass keeps
    /// one identity instead of being rebuilt when the morph ends.
    let restingID: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: id ?? restingID, in: namespace)
        } else {
            content
        }
    }
}

/// The reply's text arriving inside the glass that morphed out of the
/// "New reply" panel: it fades in from a 4 pt blur just after the glass
/// starts moving. `done` runs once it has, so it never plays again.
private struct MorphArrival: ViewModifier {
    let active: Bool
    let done: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let hidden = active && !shown
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden && !reduceMotion ? 4 : 0)
            .onAppear {
                guard active else { return }
                withAnimation(RelayMotion.enter.delay(0.08)) { shown = true } completion: { done() }
            }
    }
}
