import SwiftUI

/// The app after onboarding: the selected tab's content above the glass tab
/// bar. Each tab is its own view in its own file; this file only switches
/// between them.
struct MainTabView: View {
    let model: AppModel
    @State private var selection: MainTab
    /// The tab bar steps aside while the keyboard is up (user, 2026-11-27).
    @State private var keyboardShown = false
    /// The tab whose panel glass is out above the tab bar; none while the
    /// glass is in the bar between tabs (user, 2026-11-27).
    @State private var panelTab: MainTab?
    /// The tabs' panels and the tab bar share one glass container (RR-552, RR-553).
    @Namespace private var glassMorph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The glass ID in `glassMorph` of the panel above the tab bar (the
    /// Agents dock or the Workspace project tabs): one glass, which goes into
    /// the tab bar and comes back out of it between tabs.
    private static let panelGlassID = "panel"
    /// Under the 12 pt gap between a panel and the tab bar, so the two stay
    /// apart at rest and flow together as the panel nears the bar.
    private static let morphSpacing: CGFloat = 8
    /// The panels' corner radius (Figma Final 21 and 26).
    private static let panelRadius: CGFloat = 20

    /// Debug only: sample Workspace data for a screenshot (`LaunchOptions`).
    private let workspaceSample: String?
    private let ticketSample: TicketSample?

    init(model: AppModel, initialTab: MainTab = .agents, workspaceSample: String? = nil, ticketSample: String? = nil) {
        self.model = model
        self.workspaceSample = workspaceSample
        self.ticketSample = TicketSample.debugSample(ticketSample, unreachable: workspaceSample == "unreachable")
        _selection = State(initialValue: initialTab)
        _panelTab = State(initialValue: initialTab)
    }

    var body: some View {
        ZStack {
            // Tabs swap as the Mac swaps pages: the old one leaves, then the new one arrives.
            Group {
                switch selection {
                case .agents: AgentsTabView(model: model)
                case .workspace: WorkspaceTabView(model: model, sample: WorkspaceFeed.debugSample(workspaceSample))
                case .settings: SettingsTabView(model: model)
                }
            }
            .id(selection)
            .transition(.relayTab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Content scrolling up passes under black behind the status bar,
        // which fades out just below it, so the clock never sits on text.
        .overlay(alignment: .top) { StatusBarScrim() }
        .environment(\.hostsPanels, true)
        // The content ends at the tab bar's top; with the keyboard up the bar
        // steps aside and the content sits on the keyboard.
        .safeAreaPadding(.bottom, keyboardShown ? 0 : GlassTabBar.contentInset)
        // Layering on every tab, back to front: the scrolling content, the
        // state glow, then the tappable glass (user, 2026-11-27).
        .overlay { AppGlowLayer(model: model) }
        .overlayPreferenceValue(HostedPanelKey.self) { panels in
            glassLayer(reduceMotion ? panels[selection] : panelTab.flatMap { panels[$0] })
        }
        .task(id: selection) { await movePanel(to: selection) }
        .animation(RelayMotion.enter, value: keyboardShown)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
        // RR-551: the ticket modal covers the tab bar too, and what is behind it is out of reach.
        .disabled(model.isTicketOpen)
        .accessibilityHidden(model.isTicketOpen)
        .overlay { TicketModalView(model: model, sample: ticketSample) }
        // Banners float over the modal and its scrim, so they are drawn here, last.
        .overlayPreferenceValue(FloatingBannerKey.self) { banner in
            Color.clear.ignoresSafeArea().relayBanner(banner)
        }
        .onAppear { if let ticketSample, LaunchOptions.current.cycleTicketEvery == nil { model.showSampleTicket(ticketSample.row) } }
        // RR-545: a tapped reply notification opens the Agents tab on its agent.
        .onChange(of: model.agentsTabRequests) { withAnimation(RelayMotion.move) { tabSelection.wrappedValue = .agents } }
        #if DEBUG
        .task { await cycleTabsForRecording() }
        .task { await cycleTicketForRecording() }
        #endif
    }

    /// Between tabs, the leaving tab's panel goes into the tab bar and the
    /// arriving tab's panel comes out of it, as its page arrives: one rule for
    /// every tab (user, 2026-11-27). A tab with no panel leaves the glass in
    /// the bar. A quicker switch cancels the wait, so the glass heads for the
    /// latest tab.
    private func movePanel(to tab: MainTab) async {
        guard panelTab != tab else { return }
        if reduceMotion { panelTab = tab; return }
        withAnimation(Self.sink) { panelTab = nil }
        try? await Task.sleep(for: .seconds(RelayMotion.tabExitDuration + RelayMotion.tabGap))
        guard !Task.isCancelled else { return }
        withAnimation(Self.rise) { panelTab = tab }
    }

    /// The panel's glass sinking into the tab bar, and rising out of it: no
    /// bounce, unhurried enough to read as liquid (user, 2026-11-28). The
    /// rise starts as the sink is ending, with the new page, so the two read
    /// as one gesture.
    private static let sink = Animation.spring(duration: 0.34, bounce: 0)
    private static let rise = Animation.spring(duration: 0.44, bounce: 0)

    /// The tabs' panels and the tab bar in one `GlassEffectContainer`
    /// (RR-552, RR-553). The panel above the tab bar is one glass that never
    /// leaves; the tab bar stays put and only that glass changes shape: it
    /// sinks into the tab bar, where the container merges it into the bar's
    /// glass, and rises back out of it (`movePanel`).
    /// The panel's contents fade out quickly and the new contents fade in once
    /// the glass has nearly arrived, so only the glass morphs. With Reduce
    /// Motion the panels crossfade instead.
    private func glassLayer(_ panel: HostedPanel?) -> some View {
        GeometryReader { proxy in
            let bar = CGRect(x: RelayMetrics.barMargin,
                             y: proxy.size.height - GlassTabBar.bottomOffset - GlassTabBar.height,
                             width: proxy.size.width - 2 * RelayMetrics.barMargin,
                             height: GlassTabBar.height)
            let frame = panel.map { proxy[$0.anchor] }
            GlassEffectContainer(spacing: Self.morphSpacing) {
                ZStack(alignment: .bottom) {
                    if reduceMotion {
                        if let panel, let frame {
                            panelGlass(panel, frame: frame, morphs: false)
                                .id(panel.tab)
                                .transition(.opacity)
                        }
                    } else if panel != nil || !keyboardShown {
                        panelGlass(panel, frame: frame ?? Self.tucked(in: bar), morphs: true)
                    }
                    if !keyboardShown {
                        GlassTabBar.MorphGlass(morph: glassMorph)
                            .padding(.bottom, GlassTabBar.bottomOffset)
                            .transition(.opacity.combined(with: .offset(y: 16)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .environment(\.relayGlassFlat, true)
            // The tabs above every glass in the container, so a panel's glass
            // sinking into the bar passes under them, not over them.
            .overlay(alignment: .bottom) {
                if !keyboardShown {
                    GlassTabBar(selection: tabSelection, morph: glassMorph)
                        .padding(.bottom, GlassTabBar.bottomOffset)
                        .transition(.opacity.combined(with: .offset(y: 16)))
                }
            }
        }
        .ignoresSafeArea()
    }

    /// The panel's glass at `frame`, with the panel in it when there is one.
    /// With no panel its fill fades, so inside the tab bar only the bar's shows.
    private func panelGlass(_ panel: HostedPanel?, frame: CGRect, morphs: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous)
        return ZStack {
            if let panel {
                panel.content
                    .id(panel.tab)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.2)),
                        removal: .opacity.animation(.easeOut(duration: 0.08))))
            }
        }
        // Bottom-anchored, so while the dock's own height animates (the
        // text box after talking) its buttons stay put inside the glass.
        .frame(width: frame.width, height: frame.height, alignment: .bottom)
        // Contents leaving a glass that is shrinking stay inside it.
        .clipShape(shape)
        // Sinking into the tab bar with no panel, it is untinted: the bar's
        // tint over its own read as a dark band as the two merged.
        .glassEffect(panel?.glass.liquid ?? RelayGlass.material, in: shape)
        .modifier(PanelGlassID(id: morphs ? Self.panelGlassID : nil, namespace: glassMorph))
        .position(x: frame.midX, y: frame.midY)
        // When the text box grows or shrinks (talking, the transcript, a
        // draft, a message sent), the place the Agents screen holds jumps to
        // its new size at once; move the glass with the dock's own animation
        // instead. Only then: between tabs the glass follows the page as it
        // moves, and chasing it with an animation made it lurch.
        .animation(RelayMotion.move, value: panel?.textKey ?? "")
    }

    /// The morphing panel's glass ID, or none while Reduce Motion crossfades.
    private struct PanelGlassID: ViewModifier {
        let id: String?
        let namespace: Namespace.ID

        func body(content: Content) -> some View {
            if let id {
                content.glassEffectID(id, in: namespace)
            } else {
                content
            }
        }
    }

    /// Black behind the status bar, fading out over `fade` points below it.
    private struct StatusBarScrim: View {
        static let fade: CGFloat = 20

        var body: some View {
            GeometryReader { proxy in
                let inset = proxy.safeAreaInsets.top
                let height = inset + Self.fade
                LinearGradient(stops: [.init(color: RelayColor.neutral1, location: 0),
                                       .init(color: RelayColor.neutral1, location: inset / max(height, 1)),
                                       .init(color: RelayColor.neutral1.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                    .offset(y: -inset)
            }
            .frame(height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Where the panel's glass waits on a tab with no panel: inside the tab bar.
    private static func tucked(in bar: CGRect) -> CGRect {
        bar.insetBy(dx: 12, dy: 8)
    }

    #if DEBUG
    /// `--cycle-tabs=<seconds>`: steps through every pair of tabs both ways on
    /// its own, so the glass morphs can be recorded in the simulator.
    /// Debug: opens the sample ticket from the first card and closes it again.
    private func cycleTicketForRecording() async {
        guard let every = LaunchOptions.current.cycleTicketEvery, let ticketSample else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(every))
            model.showSampleTicket(ticketSample.row, from: CGRect(x: 16, y: 170, width: 370, height: 84))
            try? await Task.sleep(for: .seconds(every))
            model.closeTicket()
        }
    }

    private func cycleTabsForRecording() async {
        guard let every = LaunchOptions.current.cycleTabsEvery else { return }
        let order: [MainTab] = [.workspace, .agents, .settings, .agents, .workspace, .settings, .workspace, .agents]
        while !Task.isCancelled {
            for tab in order {
                try? await Task.sleep(for: .seconds(every))
                withAnimation(RelayMotion.move) { tabSelection.wrappedValue = tab }
            }
        }
    }
    #endif

    /// The selected tab, for the tab bar and the requests that switch tabs.
    private var tabSelection: Binding<MainTab> {
        Binding(get: { selection }, set: { selection = $0 })
    }
}
