import SwiftUI

/// The app after onboarding: the selected tab's content above the glass tab
/// bar. Each tab is its own view in its own file; this file only switches
/// between them.
struct MainTabView: View {
    let model: AppModel
    @State private var selection: MainTab
    /// The tab bar steps aside while the keyboard is up (user, 2026-11-27).
    @State private var keyboardShown = false
    /// The tab whose panel is out above the tab bar, or sinking into it on
    /// the way to Settings (user, 2026-11-28).
    @State private var panelTab: MainTab?
    /// How far that panel is out of the tab bar (`PanelPop`).
    @State private var panelOut: Double
    @State private var popCache = PanelPopCache()
    /// The tabs' panels and the tab bar share one glass container (RR-552, RR-553).
    @Namespace private var glassMorph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        let hasPanel = Self.panelTabs.contains(initialTab)
        _panelTab = State(initialValue: hasPanel ? initialTab : nil)
        _panelOut = State(initialValue: hasPanel ? 1 : 0)
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
        // The state glow: on Agents over the chat; on Workspace and Settings
        // behind the tickets and the Settings panel, showing faintly through
        // their glass (user, 2026-11-28). Both stay alive so a tab switch
        // keeps the glow where it is.
        .background { AppGlowLayer(model: model).opacity(selection == .agents ? 0 : 1) }
        .overlay { AppGlowLayer(model: model).opacity(selection == .agents ? 1 : 0) }
        .overlayPreferenceValue(HostedPanelKey.self) { panels in
            glassLayer(panels)
        }
        .onChange(of: selection) { _, tab in movePanel(to: tab) }
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

    /// Between Agents and Workspace the dock morphs straight into the project
    /// tabs and back (user, 2026-11-28). To or from Settings, which has no
    /// panel, the panel sinks into the tab bar, or pushes out of it, as the
    /// desktop wheel's submenus do (`PanelPop`).
    private func movePanel(to tab: MainTab) {
        let hasPanel = Self.panelTabs.contains(tab)
        if reduceMotion {
            panelTab = hasPanel ? tab : nil
            panelOut = hasPanel ? 1 : 0
        } else if !hasPanel {
            withAnimation(PanelPop.animation) { panelOut = 0 }
        } else if panelTab != nil, panelOut == 1 {
            withAnimation(Self.morph) { panelTab = tab }
        } else {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { panelTab = tab }
            withAnimation(PanelPop.animation) { panelOut = 1 }
        }
    }

    /// No Liquid Glass under the jet black bars: its refracted edge and
    /// shadow showed round them, which the Figma doesn't have (user,
    /// 2026-11-28). They keep their place in the glass container, so the
    /// panels still move with the bar.
    static let barGlass = Glass.identity

    /// The dock reshaping into the project tabs and back: no bounce.
    private static let morph = Animation.spring(duration: 0.44, bounce: 0)
    /// The tabs with a panel above the tab bar.
    private static let panelTabs: Set<MainTab> = [.agents, .workspace]

    /// The tabs' panels and the tab bar in one `GlassEffectContainer`
    /// (RR-552, RR-553), so the panel's glass and the bar's merge as the
    /// panel pushes out of the bar or sinks back into it (`movePanel`). The
    /// panel is drawn from its page's live copy; only once the page has gone
    /// (sinking on the way to Settings) from the last copy it handed up. With
    /// Reduce Motion the selected tab's panel crossfades instead.
    private func glassLayer(_ panels: [MainTab: HostedPanel]) -> some View {
        GeometryReader { proxy in
            let bar = CGRect(x: RelayMetrics.barMargin,
                             y: proxy.size.height - GlassTabBar.bottomOffset - GlassTabBar.height,
                             width: proxy.size.width - 2 * RelayMetrics.barMargin,
                             height: GlassTabBar.height)
            let _ = panels.values.forEach { popCache.remember($0, at: proxy[$0.anchor]) }
            GlassEffectContainer(spacing: Self.morphSpacing) {
                ZStack(alignment: .bottom) {
                    if reduceMotion {
                        if let panel = panels[selection] {
                            panelGlass(panel, frame: proxy[panel.anchor])
                                .id(panel.tab)
                                .transition(.opacity)
                        }
                    }
                    if !keyboardShown {
                        GlassTabBar.MorphGlass(morph: glassMorph)
                            .padding(.bottom, GlassTabBar.bottomOffset)
                            .transition(.opacity.combined(with: .offset(y: 16)))
                    }
                    // Over the bar's black, so the two can flow together as one.
                    if !reduceMotion, let panelTab, let entry = panels[panelTab].map({
                        PanelPopCache.Entry(panel: $0, frame: proxy[$0.anchor])
                    }) ?? popCache.entries[panelTab] {
                        poppingPanel(entry.panel, place: entry.frame, bar: bar,
                                     interactive: panelTab == selection)
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

    /// The panel `panelOut` of the way out of the bar (`PanelPop`). When it
    /// morphs into the other tab's panel, its contents fade out quickly and
    /// the new ones fade in once the glass has nearly arrived, so only the
    /// glass morphs.
    private func poppingPanel(_ panel: HostedPanel, place: CGRect, bar: CGRect, interactive: Bool) -> some View {
        ZStack {
            panel.content
                .id(panel.tab)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.2)),
                    removal: .opacity.animation(.easeOut(duration: 0.08))))
        }
        .modifier(PanelPop(progress: panelOut, place: place, bar: bar, radius: Self.panelRadius))
        .allowsHitTesting(interactive)
        // When the text box grows or shrinks (talking, the transcript, a
        // draft, a message sent), the place the Agents screen holds jumps to
        // its new size at once; move the glass with the dock's own animation.
        .animation(RelayMotion.move, value: panel.textKey)
    }

    /// With Reduce Motion: the selected tab's panel glass at `frame`.
    private func panelGlass(_ panel: HostedPanel?, frame: CGRect) -> some View {
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
        .background { if panel != nil { RelayJetBackground(shape: shape) } }
        .glassEffect(Self.barGlass, in: shape)
        .position(x: frame.midX, y: frame.midY)
        // When the text box grows or shrinks (talking, the transcript, a
        // draft, a message sent), the place the Agents screen holds jumps to
        // its new size at once; move the glass with the dock's own animation
        // instead. Only then: between tabs the glass follows the page as it
        // moves, and chasing it with an animation made it lurch.
        .animation(RelayMotion.move, value: panel?.textKey ?? "")
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
