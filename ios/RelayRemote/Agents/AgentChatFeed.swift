import SwiftUI

/// The selected agent's chat, newest at the bottom. It fades out at its top
/// and bottom edges with an alpha mask on the feed itself, and has no
/// background, so the glows behind the screen show through.
struct AgentChatFeed: View {
    let name: String
    let messages: [ChatMessage]
    var speakingSeq: Int?

    static let topFade: CGFloat = 32
    static let bottomFade: CGFloat = 24

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                // Only the newest reply with the playing seq: an older one may
                // share it from before the Mac restarted.
                let speakingID = speakingSeq.flatMap { seq in messages.last(where: { $0.seq == seq })?.id }
                ForEach(messages) { message in
                    row(message, speaking: message.id == speakingID)
                        // New rows rise in from below.
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 24))
                                .combined(with: .scale(scale: 0.98, anchor: .bottom)),
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
    private func row(_ message: ChatMessage, speaking: Bool) -> some View {
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

    /// A little bounce, so the glass settles like liquid rather than sliding.
    static let feedChange = Animation.spring(duration: 0.45, bounce: 0.22)
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
