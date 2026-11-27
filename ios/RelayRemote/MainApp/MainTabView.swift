import SwiftUI

/// The app after onboarding: the selected tab's content above the glass tab
/// bar. Each tab is its own view in its own file; this file only switches
/// between them.
struct MainTabView: View {
    let model: AppModel
    @State private var selection: MainTab
    /// The tab bar steps aside while the keyboard is up (user, 2026-11-27).
    @State private var keyboardShown = false
    /// How far each panel is out of the tab bar (`PanelPopProgress`).
    @State private var pop: PanelPopProgress
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
        _pop = State(initialValue: PanelPopProgress(showing: initialTab))
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
            glassLayer(panels)
        }
        // The chosen tab's panel pushes out of the bar as the others sink back in.
        .onChange(of: selection) { _, tab in
            withAnimation(PanelPopProgress.animation) { pop = PanelPopProgress(showing: tab) }
        }
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

    /// The tabs' panels and the tab bar in one `GlassEffectContainer`
    /// (RR-552, RR-553), so a panel's glass and the bar's merge as the panel
    /// pushes out of the bar or sinks back into it (`PanelPopProgress`). With
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
                    } else {
                        PanelPopAnimation(progress: pop) { pop in
                            ForEach([MainTab.agents, .workspace], id: \.self) { tab in
                                if let entry = popCache.entries[tab], pop[tab] > 0.001 {
                                    poppingPanel(entry.panel, place: entry.frame, bar: bar, progress: pop[tab],
                                                 interactive: tab == selection && pop[tab] > 0.95)
                                }
                            }
                        }
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

    /// A panel `progress` of the way out of the bar: the glass over the part
    /// that is out (and a sliver inside, merging with the bar's), and the
    /// panel's contents laid out in place, clipped to it, blurring and fading
    /// as `PanelPopPresentation` says.
    private func poppingPanel(_ panel: HostedPanel, place: CGRect, bar: CGRect, progress: Double,
                              interactive: Bool) -> some View {
        let look = PanelPopPresentation(progress)
        let visible = look.visible(place: place, bar: bar)
        let shape = RoundedRectangle(cornerRadius: min(Self.panelRadius, visible.height / 2), style: .continuous)
        return ZStack(alignment: .top) {
            panel.content
                .frame(width: place.width, height: place.height, alignment: .bottom)
                .opacity(look.controlsOpacity)
                .blur(radius: look.blur)
        }
        .frame(width: visible.width, height: visible.height, alignment: .top)
        .clipShape(shape)
        .glassEffect(panel.glass.liquid, in: shape)
        .position(x: visible.midX, y: visible.midY)
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
        .glassEffect(panel?.glass.liquid ?? RelayGlass.material, in: shape)
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
