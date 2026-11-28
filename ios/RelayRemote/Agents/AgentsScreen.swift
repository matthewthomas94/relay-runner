import PhotosUI
import RelayRemoteProtocol
import SwiftUI
import UniformTypeIdentifiers

/// What the Agents screen's controls do.
struct AgentsScreenActions {
    var select: (String) -> Void = { _ in }
    /// Changes the selected agent's work style.
    var setWorkStyle: (String) -> Void = { _ in }
    /// Sends the text box and its uploaded files; false leaves them in place.
    var send: (String, [SentFile]) -> Bool = { _, _ in false }
    /// Uploads a picked file to the Mac and returns where it was saved.
    var upload: (Data, String, @escaping @MainActor (Double) -> Void) async throws -> String = { _, _, _ in
        throw CancellationError()
    }
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
    @State private var attachments: [DockAttachment] = []
    @State private var pickingFiles = false
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
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
        let text = state.isTalking || !state.transcript.isEmpty ? "t" + state.transcript : "d" + draft
        return text + attachments.map(\.id.uuidString).joined()
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
                  canReplay: !state.notRunning, canPlay: state.waiting != nil && !state.notRunning,
                  isPlaying: state.isPlaying, isPreparing: state.isPreparing, canStop: !state.notRunning,
                  // Nothing in the dock works for an agent that is not
                  // running until it has started (user, 2026-11-28).
                  canMessage: !state.isStarting && !state.notRunning,
                  drawsGlass: !hostsPanels,
                  attachments: attachments,
                  onAttach: { source in
                      switch source {
                      case .photos: pickingPhotos = true
                      case .files: pickingFiles = true
                      }
                  },
                  onRemoveAttachment: { id in attachments.removeAll { $0.id == id } },
                  onSend: send, onTalk: actions.talk, onCancel: actions.cancelTalk,
                  onReplay: actions.replay, onPlay: play, onStop: actions.stop)
            .modifier(Dimmed(isDimmed: isOffline))
            .hostedPanel(.agents, hosted: hostsPanels, textKey: dockTextKey)
            .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item],
                          allowsMultipleSelection: true, onCompletion: importFiles)
            .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 10,
                          matching: .images)
            .onChange(of: photoItems) { _, items in importPhotos(items) }
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
            Text("Start \(state.name) to message it.")
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
        let files = attachments.compactMap { attachment in
            attachment.path.map { SentFile(name: attachment.name, path: $0) }
        }
        guard actions.send(draft, files) else { return }
        draft = ""
        attachments = []
    }

    // MARK: - Attachments (user, 2026-11-28)

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            Task {
                let read = await Task.detached { Self.read(url) }.value
                switch read {
                case .success(let data): add(data, name: url.lastPathComponent)
                case .failure(let reason): attachments.append(DockAttachment(name: url.lastPathComponent, preview: nil,
                                                                             failure: reason.message))
                }
            }
        }
    }

    private struct ReadFailure: Error { let message: String }

    /// The file's bytes, refusing one over the upload limit before reading it.
    nonisolated private static func read(_ url: URL) -> Result<Data, ReadFailure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > RelayRemoteProtocol.maxUploadBytes {
            return .failure(ReadFailure(message: "Larger than 50 MB"))
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(ReadFailure(message: "Could not be read")) }
        return .success(data)
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: .now)
        for (offset, item) in items.enumerated() {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                // A photo goes as a JPEG, which every agent can read; HEIC is not.
                let jpeg = await Task.detached { UIImage(data: data)?.jpegData(compressionQuality: 0.85) }.value
                add(jpeg ?? data, name: "photo-\(stamp)-\(offset + 1).jpg")
            }
        }
    }

    private func add(_ data: Data, name: String) {
        guard data.count <= RelayRemoteProtocol.maxUploadBytes else {
            attachments.append(DockAttachment(name: name, preview: nil, failure: "Larger than 50 MB"))
            return
        }
        let attachment = DockAttachment(name: name, preview: UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 84, height: 84)))
        attachments.append(attachment)
        let id = attachment.id
        Task {
            do {
                let path = try await actions.upload(data, name) { progress in update(id) { $0.progress = progress } }
                update(id) { $0.path = path }
            } catch {
                update(id) { $0.failure = "Not sent" }
            }
        }
    }

    private func update(_ id: DockAttachment.ID, _ change: (inout DockAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        change(&attachments[index])
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
