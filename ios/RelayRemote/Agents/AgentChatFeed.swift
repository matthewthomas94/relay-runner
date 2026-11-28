import SwiftUI

/// The selected agent's chat, newest at the bottom. It fades out at its top
/// edge with an alpha mask on the feed itself, and has no background; the
/// state glows draw over it (`MainTabView`).
struct AgentChatFeed: View {
    let name: String
    let messages: [ChatMessage]
    var speakingSeq: Int?
    /// The reply the dock's Play will play (Queue mode): a Border Beam in
    /// the playback purple runs round its edge (user, 2026-11-28).
    var waitingSeq: Int?

    static let topFade: CGFloat = 32
    /// The chat's own top fade: long and eased into the black behind, so
    /// messages dissolve under the header instead of looking cropped (user,
    /// 2026-11-28).
    static let headerFade: CGFloat = 170
    static let bottomFade: CGFloat = 24

    var body: some View {
        ScrollView {
            // Not lazy: a LazyVStack estimates the height of rows it has not
            // laid out, and with the bottom anchor the feed jumped past its
            // last message and could not scroll back up when long replies
            // came into view. A chat holds at most `ChatStore.limit` rows.
            VStack(spacing: 20) {
                // Only the newest reply with the playing seq: an older one may
                // share it from before the Mac restarted.
                let speakingID = speakingSeq.flatMap { seq in messages.last(where: { $0.seq == seq })?.id }
                let waitingID = waitingSeq.flatMap { seq in messages.last(where: { $0.seq == seq })?.id }
                ForEach(messages) { message in
                    row(message, speaking: message.id == speakingID,
                        waiting: message.id == waitingID && message.id != speakingID)
                        // New rows rise in from below, unblurring as they
                        // settle, and the rows above ease up to make room
                        // (user, 2026-11-28: they popped in too fast).
                        .transition(.asymmetric(
                            insertion: .modifier(active: RelayHiddenModifier(hidden: 1),
                                                 identity: RelayHiddenModifier(hidden: 0))
                                .combined(with: .offset(y: 32)),
                            removal: .opacity))
                }
            }
            .padding(.horizontal, RelayMetrics.screenMargin)
            .padding(.top, Self.topFade)
            .padding(.bottom, Self.bottomFade)
            .animation(Self.feedChange, value: messages.count)
            .animation(RelayMotion.enter, value: speakingSeq)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        // Dragging the chat down pulls the keyboard away with it.
        .scrollDismissesKeyboard(.interactively)
        // Only the top edge fades, under the agent; the bottom scrolls straight
        // under the dock's glass (user, 2026-11-27).
        .mask {
            VStack(spacing: 0) {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.04), location: 0.12),
                    .init(color: .black.opacity(0.2), location: 0.3),
                    .init(color: .black.opacity(0.5), location: 0.5),
                    .init(color: .black.opacity(0.78), location: 0.7),
                    .init(color: .black.opacity(0.94), location: 0.86),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.headerFade)
                Rectangle().fill(.black)
            }
            // The mask reaches under the bars, so the list shows through
            // their glass instead of stopping at their edge.
            .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private func row(_ message: ChatMessage, speaking: Bool, waiting: Bool) -> some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                Text(message.text)
                    .relayTextStyle(.body)
                    .foregroundStyle(RelayColor.neutral10)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .modifier(FeedGlass(glass: .raised))
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
                    .modifier(FeedGlass())
                    // Libraries.dev's Border Beam in the playback glow's
                    // purples only, matching the dock's Play (`playbackBeam`).
                    .playbackBeam(active: waiting, cornerRadius: RelayMetrics.panelRadius,
                                  lap: PlaybackBeam.replyLap, strength: 1)
                // "speaking" swaps in and out without the two lines overlapping.
                ZStack(alignment: .leading) {
                    Text(speaking ? "\(name) · speaking" : "\(name) · \(Self.time(message.date))")
                        .relayTextStyle(.caption)
                        .foregroundStyle(RelayColor.neutral7)
                        .id(speaking)
                        .transition(.relayControlSwap)
                }
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

    /// No bounce: a message settles into place on the ease-out, rather than
    /// overshooting and springing back (user, 2026-11-28).
    static let feedChange = Animation.spring(duration: 0.7, bounce: 0)
}

/// A chat surface's glass (radius 16): Liquid Glass tinted with the Figma
/// fill, applied to the content itself so the text always draws above it.
private struct FeedGlass: ViewModifier {
    var glass: RelayGlass = .panel

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: RelayMetrics.panelRadius, style: .continuous)
        content
            .glassEffect(glass.liquid, in: shape)
            .environment(\.colorScheme, .dark)
    }
}
