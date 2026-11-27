import SwiftUI

/// The app after onboarding: the selected tab's content above the glass tab
/// bar. Each tab is its own view in its own file; this file only switches
/// between them.
struct MainTabView: View {
    let model: AppModel
    @State private var selection: MainTab
    /// The tab bar steps aside while the keyboard is up (user, 2026-11-27).
    @State private var keyboardShown = false
    /// +1 when the new tab is to the right of the old one, -1 to the left.
    @State private var direction: CGFloat = 0
    /// The dock and the tab bar share one glass container (RR-552).
    @Namespace private var glassMorph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Agents dock's glass ID in `glassMorph`.
    private static let dockGlassID = "dock"
    /// Just under the 13 pt gap between the dock and the tab bar, so the two
    /// stay apart at rest and flow together as the dock nears the bar.
    private static let morphSpacing: CGFloat = 12

    /// Debug only: sample Workspace data for a screenshot (`LaunchOptions`).
    private let workspaceSample: String?
    private let ticketSample: TicketSample?

    init(model: AppModel, initialTab: MainTab = .agents, workspaceSample: String? = nil, ticketSample: String? = nil) {
        self.model = model
        self.workspaceSample = workspaceSample
        self.ticketSample = TicketSample.debugSample(ticketSample, unreachable: workspaceSample == "unreachable")
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        ZStack {
            // Tabs crossfade with a hint of scale instead of cutting.
            Group {
                switch selection {
                case .agents: AgentsTabView(model: model)
                case .workspace: WorkspaceTabView(model: model, sample: WorkspaceFeed.debugSample(workspaceSample))
                case .settings: SettingsTabView(model: model)
                }
            }
            .id(selection)
            .transition(.relayTab(direction: direction))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Content scrolling up passes under black behind the status bar,
        // which fades out just below it, so the clock never sits on text.
        .overlay(alignment: .top) { StatusBarScrim() }
        .environment(\.hostsDock, true)
        // The content ends at the tab bar's top; with the keyboard up the bar
        // steps aside and the content sits on the keyboard.
        .safeAreaPadding(.bottom, keyboardShown ? 0 : GlassTabBar.contentInset)
        .overlayPreferenceValue(HostedDockKey.self) { dock in glassLayer(dock) }
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
        .onAppear { if let ticketSample { model.showSampleTicket(ticketSample.row) } }
        // RR-545: a tapped reply notification opens the Agents tab on its agent.
        .onChange(of: model.agentsTabRequests) { withAnimation(RelayMotion.move) { tabSelection.wrappedValue = .agents } }
        #if DEBUG
        .task { await cycleTabsForRecording() }
        #endif
    }

    /// The Agents dock and the tab bar in one `GlassEffectContainer` (RR-552).
    /// The dock's glass never leaves: away from Agents it sits tucked inside
    /// the bar, where the container merges it into the bar's glass. Leaving
    /// Agents it sinks into the bar, and as it nears the bar the two flow
    /// together like liquid; coming back it rises out of the bar into the
    /// place the Agents screen holds for it. The dock's contents fade out
    /// quickly and fade in once it has arrived, so only the glass morphs.
    /// With Reduce Motion the dock crossfades instead.
    private func glassLayer(_ dock: HostedDock?) -> some View {
        GeometryReader { proxy in
            let bar = CGRect(x: RelayMetrics.screenMargin,
                             y: proxy.size.height - GlassTabBar.bottomOffset - GlassTabBar.height,
                             width: proxy.size.width - 2 * RelayMetrics.screenMargin,
                             height: GlassTabBar.height)
            let shown = selection == .agents ? dock.map { proxy[$0.anchor] } : nil
            GlassEffectContainer(spacing: Self.morphSpacing) {
                ZStack(alignment: .bottom) {
                    if reduceMotion {
                        if let shown, let dock {
                            dockGlass(dock, frame: shown, filled: true)
                                .transition(.opacity)
                        }
                    } else if shown != nil || !keyboardShown {
                        dockGlass(shown == nil ? nil : dock, frame: shown ?? Self.tucked(in: bar), filled: shown != nil)
                    }
                    if !keyboardShown {
                        GlassTabBar(selection: tabSelection, morph: glassMorph)
                            .padding(.bottom, GlassTabBar.bottomOffset)
                            .transition(.opacity.combined(with: .offset(y: 16)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .environment(\.relayGlassFlat, true)
        }
        .ignoresSafeArea()
    }

    /// The dock's glass at `frame`, with the dock in it when `dock` is set.
    /// Its fill fades as it sinks, so inside the bar only the bar's shows.
    private func dockGlass(_ dock: HostedDock?, frame: CGRect, filled: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: AgentDock.cornerRadius, style: .continuous)
        return ZStack {
            if let dock {
                // The dock's buttons carry glass of their own, in a container
                // of their own so they neither merge into the dock's glass
                // nor take part in its morph.
                GlassEffectContainer(spacing: 0) { dock.content }
                    .environment(\.relayGlassFlat, false)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.15)),
                        removal: .opacity.animation(.easeOut(duration: 0.08))))
            }
        }
        // Bottom-anchored, so while the dock's own height animates (the
        // text box after talking) its buttons stay put inside the glass.
        .frame(width: frame.width, height: frame.height, alignment: .bottom)
        .background(shape.fill(RelayGlass.panel.tint).opacity(filled ? 1 : 0))
        .glassEffect(RelayGlass.material, in: shape)
        .glassEffectID(Self.dockGlassID, in: glassMorph)
        .position(x: frame.midX, y: frame.midY)
        // When talking starts or stops, the place the Agents screen holds
        // jumps to its new size at once; move the glass with the dock's own
        // animation instead. Only then: between tabs the glass follows the
        // page as it moves, and chasing it with an animation made it lurch.
        .animation(RelayMotion.move, value: dock?.isTalking ?? false)
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

    /// Where the dock's glass waits away from Agents: inside the tab bar.
    private static func tucked(in bar: CGRect) -> CGRect {
        bar.insetBy(dx: 12, dy: 8)
    }

    #if DEBUG
    /// `--cycle-tabs=<seconds>`: steps Agents, Workspace, Agents, Settings on
    /// its own, so the dock's morph can be recorded in the simulator.
    private func cycleTabsForRecording() async {
        guard let every = LaunchOptions.current.cycleTabsEvery else { return }
        let order: [MainTab] = [.workspace, .agents, .settings, .agents]
        while !Task.isCancelled {
            for tab in order {
                try? await Task.sleep(for: .seconds(every))
                withAnimation(RelayMotion.move) { tabSelection.wrappedValue = tab }
            }
        }
    }
    #endif

    /// Sets the slide direction from the tab order before the selection
    /// changes, so the pages move the same way as the tab bar's pill.
    private var tabSelection: Binding<MainTab> {
        Binding(get: { selection }, set: { new in
            let all = MainTab.allCases
            let from = all.firstIndex(of: selection) ?? 0
            let to = all.firstIndex(of: new) ?? 0
            direction = to == from ? 0 : (to > from ? 1 : -1)
            selection = new
        })
    }
}
