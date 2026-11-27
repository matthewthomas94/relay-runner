import SwiftUI

/// What the Agents screen's controls do.
struct AgentsScreenActions {
    var select: (String) -> Void = { _ in }
    /// Sends the text box; false leaves the text in place.
    var send: (String) -> Bool = { _ in false }
    var talk: (TalkGesture.Command) -> Void = { _ in }
    var cancelTalk: () -> Void = {}
    var play: (AgentsScreenState.WaitingReply) -> Void = { _ in }
    var stop: () -> Void = {}
    var replay: () -> Void = {}
    var start: () -> Void = {}
    var retry: () -> Void = {}
}

/// Agents (21–25), bottom to top: the dock, the agent tab strip, the chat feed
/// and the header with the agent's orb over its name. The tab bar below
/// belongs to `MainTabView`. While the Mac is unreachable a banner floats over
/// the screen and the chat and controls dim and take no input; the orb is
/// never dimmed.
struct AgentsScreen: View {
    let state: AgentsScreenState
    var actions = AgentsScreenActions()
    @State private var draft: String

    /// How far the dock sits above the tab bar.
    static let dockBottomGap: CGFloat = 13
    static let dimmedOpacity = 0.45

    init(state: AgentsScreenState, actions: AgentsScreenActions = AgentsScreenActions(), draft: String = "") {
        self.state = state
        self.actions = actions
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if state.notRunning {
                    notRunning
                        .transition(.relaySurface)
                } else {
                    AgentChatFeed(name: state.name, messages: state.feed, speakingSeq: state.speakingSeq,
                                  waiting: state.waiting) {
                        if let waiting = state.waiting { actions.play(waiting) }
                    }
                    .id(state.selected)
                    // Switching agents crossfades the chats.
                    .transition(.opacity)
                }
            }
            .animation(RelayMotion.enter, value: state.notRunning)
            .animation(RelayMotion.enter, value: state.selected)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 6)
            .modifier(Dimmed(isDimmed: isOffline))
            AgentTabStrip(tabs: state.tabs, selected: state.selected, onSelect: actions.select)
                .modifier(Dimmed(isDimmed: isOffline))
                .padding(.bottom, 10)
            AgentDock(text: $draft, placeholder: "Message \(state.name)", talkMode: state.talkMode,
                      isTalking: state.isTalking, transcript: state.transcript,
                      canReplay: !state.notRunning, canStop: !state.notRunning,
                      onSend: send, onTalk: actions.talk, onCancel: actions.cancelTalk,
                      onReplay: actions.replay, onStop: actions.stop)
                .modifier(Dimmed(isDimmed: isOffline))
                .padding(.bottom, Self.dockBottomGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .relayBanner(banner)
    }

    private var isOffline: Bool { state.reachability != .reachable }

    private var header: some View {
        VStack(spacing: 10) {
            AgentOrb(state: state.orb)
            Text(state.name)
                .relayTextStyle(.cardTitle)
                .foregroundStyle(RelayColor.neutral10)
                .contentTransition(.opacity)
                .animation(RelayMotion.enter, value: state.name)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var notRunning: some View {
        VStack(spacing: 0) {
            Text("\(state.name) isn’t running")
                .relayTextStyle(.cardTitle)
                .foregroundStyle(RelayColor.neutral10)
            Text("Message \(state.name) to start it.")
                .relayTextStyle(.caption)
                .foregroundStyle(RelayColor.neutral7)
                .padding(.top, 12)
            Button(action: actions.start) { RelayButtonLabel("Start \(state.name)", icon: .play) }
                .buttonStyle(.relaySecondary)
                .padding(.top, 14)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }

    private var banner: RelayBanner? {
        switch state.reachability {
        case .reachable:
            return nil
        case .unreachable:
            return RelayBanner(icon: .wifiOff, title: "Mac unreachable", message: "Check Wi-Fi or Tailscale.",
                               isError: true, action: .init(title: "Retry", perform: actions.retry))
        case .appNotRunning:
            return RelayBanner(icon: .laptop, title: "Relay Runner isn’t running", message: "Open it on your Mac.",
                               action: .init(title: "Retry", perform: actions.retry))
        }
    }

    private func send() {
        if actions.send(draft) { draft = "" }
    }
}

/// The chat and controls while the Mac is unreachable: dimmed, no input.
private struct Dimmed: ViewModifier {
    let isDimmed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isDimmed ? AgentsScreen.dimmedOpacity : 1)
            .disabled(isDimmed)
            .animation(RelayMotion.enter, value: isDimmed)
    }
}
