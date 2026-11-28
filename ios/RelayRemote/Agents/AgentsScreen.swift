import SwiftUI

/// What the Agents screen's controls do.
struct AgentsScreenActions {
    var select: (String) -> Void = { _ in }
    /// Changes the selected agent's work style.
    var setWorkStyle: (String) -> Void = { _ in }
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
/// and the header: the agent's orb beside its name and what it is doing
/// (Figma Final 21, 2026-11-28). The tab bar below
/// belongs to `MainTabView`. While the Mac is unreachable a banner floats over
/// the screen in the header's place, and the chat and controls dim and take
/// no input.
struct AgentsScreen: View {
    let state: AgentsScreenState
    var actions = AgentsScreenActions()
    @State private var draft: String
    /// The agent whose chat is showing, to tell which way a switch goes.
    @State private var shownAgent: String
    @Environment(\.hostsPanels) private var hostsPanels
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the dock sits above the tab bar (Figma Final 21).
    static let dockBottomGap: CGFloat = 12
    static let dimmedOpacity = 0.45

    init(state: AgentsScreenState, actions: AgentsScreenActions = AgentsScreenActions(), draft: String = "") {
        self.state = state
        self.actions = actions
        _draft = State(initialValue: draft)
        _shownAgent = State(initialValue: state.selected)
    }

    /// +1 when the new agent's tab is right of the old one's, -1 left.
    private var switchDirection: CGFloat {
        let order = state.tabs.map(\.slug)
        guard let new = order.firstIndex(of: state.selected), let old = order.firstIndex(of: shownAgent),
              new != old else { return 0 }
        return new > old ? 1 : -1
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                // Switching agents swaps the chats, never with both on
                // screen: the old one blurs and fades in 120 ms, then the new
                // one slides in from the side of the tab that was picked,
                // sharpening as it settles (user, 2026-11-28).
                if state.notRunning {
                    notRunning
                        .id(state.selected)
                        .transition(Self.chatSwap(direction: reduceMotion ? 0 : switchDirection))
                } else {
                    AgentChatFeed(name: state.name, messages: state.feed, speakingSeq: state.speakingSeq,
                                  waitingSeq: state.waiting?.seq)
                    .id(state.selected)
                    .transition(Self.chatSwap(direction: reduceMotion ? 0 : switchDirection))
                }
            }
            .onChange(of: state.selected) { _, new in shownAgent = new }
            .animation(RelayMotion.enter, value: state.notRunning)
            .animation(RelayMotion.enter, value: state.selected)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Tapping the chat puts the keyboard away; buttons in it still work.
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
            .modifier(Dimmed(isDimmed: isOffline))
            // The chat scrolls on under the dock's glass, its newest message
            // resting 10 pt above it (user, 2026-11-27).
            .safeAreaInset(edge: .bottom, spacing: 10) {
                dock
                    .padding(.horizontal, AgentDock.sideInset)
                    .padding(.bottom, Self.dockBottomGap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .modifier(BannerPlacement(banner: banner, hosted: hostsPanels))
    }

    /// Under `MainTabView` the banner is handed to the tab view, which draws
    /// it above the status bar's black scrim; drawn here it sat under the
    /// scrim and its top was cut off (user, 2026-11-28).
    private struct BannerPlacement: ViewModifier {
        let banner: RelayBanner?
        let hosted: Bool

        func body(content: Content) -> some View {
            if hosted { content.floatingBanner(banner) } else { content.relayBanner(banner) }
        }
    }

    /// What the dock's text box shows: the transcript from the moment talking
    /// starts until the message is sent, otherwise the draft.
    private var dockTextKey: String {
        state.isTalking || !state.transcript.isEmpty ? "t" + state.transcript : "d" + draft
    }

    private var isOffline: Bool { state.reachability != .reachable }

    /// The old chat leaves where it is; the new one arrives from `direction`,
    /// 8 pt: further, quick switches read as the chat being shoved sideways
    /// (user, 2026-11-28).
    static func chatSwap(direction: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: ChatSwapEffect(hidden: true, travel: 8 * direction),
                                 identity: ChatSwapEffect(hidden: false, travel: 0))
                .animation(.spring(duration: 0.34, bounce: 0).delay(0.12 + RelayMotion.tabGap)),
            removal: .modifier(active: ChatSwapEffect(hidden: true, travel: 0),
                               identity: ChatSwapEffect(hidden: false, travel: 0))
                .animation(.timingCurve(0.4, 0, 1, 1, duration: 0.12)))
    }

    private struct ChatSwapEffect: ViewModifier {
        let hidden: Bool
        let travel: CGFloat

        func body(content: Content) -> some View {
            content
                .opacity(hidden ? 0 : 1)
                .blur(radius: hidden ? 6 : 0)
                .offset(x: travel)
        }
    }

    /// Under `MainTabView` the dock is drawn by the tab view, in the tab bar's
    /// glass container (`HostedPanel`); here a hidden copy holds its place.
    /// Offline, the whole panel's contents dim once, the agent tabs with them.
    private var dock: some View {
        AgentDock(text: $draft, placeholder: "Message \(state.name)",
                  tabs: AgentTabStrip(tabs: state.tabs, selected: state.selected, onSelect: actions.select),
                  talkMode: state.talkMode,
                  isTalking: state.isTalking, transcript: state.transcript,
                  canReplay: !state.notRunning, canPlay: state.waiting != nil,
                  isPlaying: state.isPlaying, isPreparing: state.isPreparing, canStop: !state.notRunning,
                  canMessage: !state.isStarting,
                  drawsGlass: !hostsPanels,
                  onSend: send, onTalk: actions.talk, onCancel: actions.cancelTalk,
                  onReplay: actions.replay, onPlay: play, onStop: actions.stop)
            .modifier(Dimmed(isDimmed: isOffline))
            .hostedPanel(.agents, hosted: hostsPanels, textKey: dockTextKey)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentOrb(state: state.orb, frameSize: AgentOrb.headerSize, step: AgentOrb.headerStep, gradualColor: true)
            // The name and status swap with the chat, the old ones gone first.
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.name)
                        .relayTextStyle(.cardTitle)
                        .foregroundStyle(RelayColor.neutral10)
                        .accessibilityAddTraits(.isHeader)
                    Text(state.status)
                        .relayTextStyle(.subtitle)
                        .foregroundStyle(RelayColor.neutral7)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(RelayMotion.enter, value: state.status)
                }
                .id(state.name)
                .transition(.relayControlSwap)
            }
            .animation(RelayMotion.enter, value: state.name)
            Spacer(minLength: 8)
            if let style = state.workStyle {
                WorkStyleMenu(style: style, agentName: state.name, choose: actions.setWorkStyle)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        // The banner takes the header's place, as in Figma Final 25; the
        // header peeking out below it looked broken (user, 2026-11-28).
        .opacity(banner == nil ? 1 : 0)
        .animation(RelayMotion.enter, value: banner == nil)
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
        .accessibilityElement(children: .contain)
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

/// The header's work style switch (user, 2026-11-28): the agent's style on
/// the same dropdown as Settings, listing the three styles by name only. The
/// change is saved on the Mac and applies from the agent's next request.
struct WorkStyleMenu: View {
    let style: String
    let agentName: String
    let choose: (String) -> Void

    /// Each style's name, as on the Mac (`ProjectWorkStyle`).
    static let styles: [(value: String, label: String)] = [
        ("auto", "Auto"),
        ("direct", "Direct"),
        ("orchestrated", "Orchestrated"),
    ]

    static func title(_ style: String) -> String {
        styles.first { $0.value == style }?.label ?? style.capitalized
    }

    var body: some View {
        RelayDropdown(label: Self.title(style), options: Self.styles, selection: style,
                      heading: "\(agentName)’s work style", choose: choose)
            .accessibilityLabel("Work style")
    }
}
