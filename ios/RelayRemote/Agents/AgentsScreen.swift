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

/// Agents (21–25), bottom to top: the dock (one glass message panel holding
/// the agent tabs, the text box and Replay and Stop, RR-553), the chat feed
/// and the header with the agent's orb over its name. The tab bar below
/// belongs to `MainTabView`. While the Mac is unreachable a banner floats over
/// the screen and the chat and controls dim and take no input; the orb is
/// never dimmed.
struct AgentsScreen: View {
    let state: AgentsScreenState
    var actions = AgentsScreenActions()
    @State private var draft: String
    @Environment(\.hostsPanels) private var hostsPanels

    /// How far the dock sits above the tab bar (Figma Final 21).
    static let dockBottomGap: CGFloat = 12
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
                // Switching agents swaps the chats quickly, and never with
                // both on screen (RR-553): the old one is gone in 100 ms,
                // then the new one fades in.
                if state.notRunning {
                    notRunning
                        .id(state.selected)
                        .transition(.relayControlSwap)
                } else {
                    AgentChatFeed(name: state.name, messages: state.feed, speakingSeq: state.speakingSeq)
                    .id(state.selected)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(RelayMotion.controlExitDuration)),
                        removal: .opacity.animation(RelayMotion.controlExit)))
                }
            }
            .animation(RelayMotion.enter, value: state.notRunning)
            .animation(RelayMotion.enter, value: state.selected)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 10)
            // Tapping the chat puts the keyboard away; buttons in it still work.
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
            .modifier(Dimmed(isDimmed: isOffline))
            dock
                .padding(.horizontal, AgentDock.sideInset)
                .padding(.bottom, Self.dockBottomGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .relayBanner(banner)
    }

    private var isOffline: Bool { state.reachability != .reachable }

    /// Under `MainTabView` the dock is drawn by the tab view, in the tab bar's
    /// glass container (`HostedPanel`); here a hidden copy holds its place.
    /// Offline, the whole panel's contents dim once, the agent tabs with them.
    private var dock: some View {
        AgentDock(text: $draft, placeholder: "Message \(state.name)",
                  tabs: AgentTabStrip(tabs: state.tabs, selected: state.selected, onSelect: actions.select),
                  talkMode: state.talkMode,
                  isTalking: state.isTalking, transcript: state.transcript,
                  canReplay: !state.notRunning, canPlay: state.waiting != nil,
                  canStop: !state.notRunning,
                  drawsGlass: !hostsPanels,
                  onSend: send, onTalk: actions.talk, onCancel: actions.cancelTalk,
                  onReplay: actions.replay, onPlay: play, onStop: actions.stop)
            .modifier(Dimmed(isDimmed: isOffline))
            .hostedPanel(.agents, hosted: hostsPanels, isTalking: state.isTalking)
    }

    private var header: some View {
        VStack(spacing: 10) {
            AgentOrb(state: state.orb)
            // The name swaps with the chat, the old name gone first.
            ZStack {
                Text(state.name)
                    .relayTextStyle(.cardTitle)
                    .foregroundStyle(RelayColor.neutral10)
                    .id(state.name)
                    .transition(.relayControlSwap)
            }
            .animation(RelayMotion.enter, value: state.name)
        }
        .padding(.top, 2)
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
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

    private func play() {
        if let waiting = state.waiting { actions.play(waiting) }
    }

    private func send() {
        if actions.send(draft) { draft = "" }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
