import AppKit
import SwiftUI

/// RR-522: one agent's card in Settings: its name and its work style. The
/// status is read to VoiceOver and shown by how the orb moves, not as text.
struct SettingsAgentPresentation: Equatable {
    let agent: SessionAgent
    let status: String
    let activity: ParticleFieldRenderer.OrbActivity
    let workStyle: ProjectWorkStyle
    let isActive: Bool
    /// The state and description at the card's bottom-left. Nil before the
    /// agent's first session.
    var work: SettingsAgentWorkBlock? = nil

    /// From the agent definition, not the voice setting.
    var name: String { agent.name }

    /// The four cards in table order.
    static func cards(
        statuses: [SessionAgent.Status],
        agents: AgentsConfig,
        state: OverlayState,
        hasWorkingProgress: Bool,
        lastProjects: [SessionAgent: String] = [:],
        workDescriptions: [SessionAgent: SettingsAgentWorkDescription] = [:],
        sessionStarts: [SessionAgent: Date] = [:]
    ) -> [SettingsAgentPresentation] {
        statuses.map { agentStatus in
            SettingsAgentPresentation(
                agent: agentStatus.agent,
                status: status(agentStatus, state: state, hasWorkingProgress: hasWorkingProgress),
                activity: activity(agentStatus, state: state, hasWorkingProgress: hasWorkingProgress),
                workStyle: agents[agentStatus.agent].workStyle,
                isActive: agentStatus.isActive,
                work: workBlock(
                    isRunning: agentStatus.isRunning,
                    sessionStartedAt: sessionStarts[agentStatus.agent],
                    description: workDescriptions[agentStatus.agent],
                    lastProject: lastProjects[agentStatus.agent]
                )
            )
        }
    }

    /// RR-528: the card's state line is the app's, never the agent's: it is
    /// "Currently working on" only while the agent runs and it set its
    /// description during that session. The description is what the agent
    /// said, else its last project; with neither the card shows no block.
    static func workBlock(
        isRunning: Bool,
        sessionStartedAt: Date?,
        description: SettingsAgentWorkDescription?,
        lastProject: String?
    ) -> SettingsAgentWorkBlock? {
        if let description {
            var current = false
            if isRunning, let setAt = description.setAt, let start = sessionStartedAt { current = setAt >= start }
            return SettingsAgentWorkBlock(
                state: current ? SettingsAgentWorkBlock.currentState : SettingsAgentWorkBlock.lastState,
                description: description.text
            )
        }
        return lastProject.map { SettingsAgentWorkBlock(state: SettingsAgentWorkBlock.lastState, description: $0) }
    }

    /// Each agent's last project: the one its most recently active session
    /// ran in. An agent that has never had a session has none.
    static func lastProjects(bindings: [AssistantSessionStore.Binding]) -> [SessionAgent: String] {
        var latest: [SessionAgent: AssistantSessionStore.Binding] = [:]
        for binding in bindings {
            guard let agent = SessionAgent(tab: binding.context.tab) else { continue }
            if let current = latest[agent], current.lastActivity >= binding.lastActivity { continue }
            latest[agent] = binding
        }
        return latest.mapValues(\.context.displayName)
    }

    /// A stopped agent is not running. The active agent describes the voice
    /// overlay's state; another running agent is standing by, because the app
    /// does not track whether a session it is not showing is mid-turn.
    static func status(_ agentStatus: SessionAgent.Status, state: OverlayState, hasWorkingProgress: Bool) -> String {
        guard agentStatus.isRunning else { return "Not running" }
        guard agentStatus.isActive else { return "Standing by" }
        return subtitle(state: state, hasActiveSession: true, hasWorkingProgress: hasWorkingProgress)
    }

    /// How the card's orb moves, by the same rules as `status`.
    static func activity(
        _ agentStatus: SessionAgent.Status, state: OverlayState, hasWorkingProgress: Bool
    ) -> ParticleFieldRenderer.OrbActivity {
        guard agentStatus.isRunning else { return .stopped }
        guard agentStatus.isActive else { return .standingBy }
        switch state {
        case .listening, .recording: return .listening
        case .speaking, .preparing: return .responding
        case .processing, .actionGlow: return .thinking
        default: return hasWorkingProgress ? .thinking : .standingBy
        }
    }

    static func subtitle(
        state: OverlayState,
        hasActiveSession: Bool,
        hasWorkingProgress: Bool
    ) -> String {
        switch state {
        case .listening, .recording: return "Listening"
        case .speaking: return "Responding"
        case .preparing: return "Preparing response"
        case .speechFailed: return "Speech unavailable"
        case .paused: return "Paused"
        default: break
        }
        guard hasActiveSession else { return "No active session" }
        switch state {
        case .processing: return "Thinking"
        case .messageWaiting: return "Response ready"
        case .replayWaiting: return "Ready to replay"
        case .sent: return "Message received"
        case .cancelled: return "Cancelled"
        case .actionGlow(let prompt):
            return prompt == nil ? "Taking action" : "Waiting for confirmation"
        default: return hasWorkingProgress ? "Working" : "Standing by"
        }
    }
}

/// What an agent said it is working on, and when it said it (nil for a
/// description saved before the date was recorded).
struct SettingsAgentWorkDescription: Equatable {
    let text: String
    var setAt: Date? = nil
}

/// The two lines at a card's bottom-left: the app's state line above the
/// agent's description.
struct SettingsAgentWorkBlock: Equatable {
    static let currentState = "Currently working on"
    static let lastState = "Last worked on"

    let state: String
    let description: String
}

enum SettingsAgentCardLayout {
    static let spacing: CGFloat = 8
    /// The Settings panels' radius, so the card's corners line up with theirs.
    static let cornerRadius: CGFloat = BoardDarkSurfaceStyle.columnCornerRadius
    /// The Settings window's agent column.
    static let windowWidth: CGFloat = 280
    /// The same inset from a card's top, leading and trailing edges.
    static let contentInset: CGFloat = GraphicalTheme.spaceS
    /// The least room kept between the name and the Work style picker.
    static let contentGap: CGFloat = GraphicalTheme.spaceXS
    static let cardsPerRow = 2

    static func width(availableWidth: CGFloat) -> CGFloat {
        min(480, max(220, (availableWidth - spacing) * 480 / 1672))
    }

    /// The agent column's width: fixed in the Settings window, scaled in the Workspace.
    static func frameWidth(inWindow: Bool, availableWidth: CGFloat) -> CGFloat {
        inWindow ? windowWidth : width(availableWidth: availableWidth)
    }

    /// The four cards' frames, in table order row by row, as a two-by-two
    /// grid that fills `size`: the frame the single agent card used to fill.
    static func gridFrames(in size: CGSize, spacing: CGFloat) -> [CGRect] {
        let columns = CGFloat(cardsPerRow)
        let rows = CGFloat((SessionAgent.allCases.count + cardsPerRow - 1) / cardsPerRow)
        let width = max(0, (size.width - spacing * (columns - 1)) / columns)
        let height = max(0, (size.height - spacing * (rows - 1)) / rows)
        return SessionAgent.allCases.indices.map { index in
            CGRect(
                x: CGFloat(index % cardsPerRow) * (width + spacing),
                y: CGFloat(index / cardsPerRow) * (height + spacing),
                width: width,
                height: height
            )
        }
    }

    /// The bottom of the orb, which is centred in the card and as large as
    /// the card's width or height allows (`ParticleFieldRenderer.buildOrbGrid`).
    /// Half its height reserve lies below it, clear of the work block.
    static func orbBottom(cardSize: CGSize) -> CGFloat {
        let orb = min(
            max(1, cardSize.width - 24),
            max(1, cardSize.height - ParticleFieldRenderer.orbVerticalReserve)
        )
        return cardSize.height / 2 + orb / 2
    }

    /// Between the work block's state line and description.
    static let workBlockLineSpacing: CGFloat = 2

    /// The work block at the card's bottom-left: in line with the name, and
    /// as far from the bottom and trailing edges as the name is from the leading one.
    static func workBlockFrame(cardSize: CGSize, blockHeight: CGFloat) -> CGRect {
        CGRect(
            x: contentInset,
            y: cardSize.height - contentInset - blockHeight,
            width: max(0, cardSize.width - contentInset * 2),
            height: blockHeight
        )
    }

    /// Inside every card, whichever column: the name at the left and the
    /// picker at the top-right, the name centred on the picker's height. The
    /// picker keeps its width while it fits; the name truncates before reaching it.
    static func contentFrames(
        cardSize: CGSize,
        textSize: CGSize,
        pickerSize: CGSize
    ) -> (text: CGRect, picker: CGRect) {
        let inner = max(0, cardSize.width - contentInset * 2)
        let pickerWidth = min(pickerSize.width, inner)
        let picker = CGRect(
            x: cardSize.width - contentInset - pickerWidth,
            y: contentInset,
            width: pickerWidth,
            height: pickerSize.height
        )
        let textWidth = max(0, min(textSize.width, picker.minX - contentGap - contentInset))
        let text = CGRect(
            x: contentInset,
            y: picker.midY - textSize.height / 2,
            width: textWidth,
            height: textSize.height
        )
        return (text, picker)
    }
}

/// The four agent cards in the frame the single agent card filled.
struct SettingsAgentGrid: View {
    let cards: [SettingsAgentPresentation]
    /// The live overlay theme, for the active agent's orb.
    var theme: ParticleFieldRenderer.Theme = .idle
    let spacing: CGFloat
    var panelGlass = false
    let onSelectWorkStyle: (SessionAgent, ProjectWorkStyle) -> Void

    var body: some View {
        GeometryReader { geometry in
            let frames = SettingsAgentCardLayout.gridFrames(in: geometry.size, spacing: spacing)
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(cards, frames)), id: \.0.agent) { card, frame in
                    SettingsAgentCard(
                        presentation: card,
                        theme: card.isActive ? theme : .idle,
                        panelGlass: panelGlass
                    ) { onSelectWorkStyle(card.agent, $0) }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
    }
}

struct SettingsAgentCard: View {
    let presentation: SettingsAgentPresentation
    var theme: ParticleFieldRenderer.Theme = .idle
    /// In the Workspace the card is a panel on the shell, frosted like one.
    var panelGlass = false
    let onSelectWorkStyle: (ProjectWorkStyle) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if panelGlass { PanelGlassUnderlay() }
            BoardDarkSurfaceStyle.panelFill
            SettingsAgentParticleView(
                theme: theme,
                activity: presentation.activity,
                phase: Double(presentation.agent.order) * 2.3,
                reduceMotion: reduceMotion
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if let work = presentation.work {
                SettingsAgentWorkBlockLayout {
                    SettingsAgentWorkBlockView(block: work)
                }
            }

            SettingsAgentCardContentLayout {
                RelaySwap(presentation.name, style: .text, alignment: .leading) { name in
                    Text(name)
                        .font(AppTypography.font(.appTitle, size: 18))
                        .tracking(-0.3)
                        .foregroundStyle(SettingsSurfaceColor.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                }
                .accessibilityHidden(true)

                SettingsAgentWorkStylePicker(
                    agent: presentation.agent,
                    style: presentation.workStyle,
                    onSelect: onSelectWorkStyle
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: SettingsAgentCardLayout.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsAgentCardLayout.cornerRadius, style: .continuous)
                .strokeBorder(BoardDarkSurfaceStyle.glassRim, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.name)
        .accessibilityValue(presentation.status)
    }
}

/// Places a card's two parts by `SettingsAgentCardLayout.contentFrames`.
private struct SettingsAgentCardContentLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let frames = SettingsAgentCardLayout.contentFrames(
            cardSize: bounds.size,
            textSize: subviews[0].sizeThatFits(.unspecified),
            pickerSize: subviews[1].sizeThatFits(.unspecified)
        )
        for (subview, frame) in zip(subviews, [frames.text, frames.picker]) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}

/// Places the work block by `SettingsAgentCardLayout.workBlockFrame`.
private struct SettingsAgentWorkBlockLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let block = subviews.first else { return }
        let width = SettingsAgentCardLayout.workBlockFrame(cardSize: bounds.size, blockHeight: 0).width
        let height = block.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let frame = SettingsAgentCardLayout.workBlockFrame(cardSize: bounds.size, blockHeight: height)
        block.place(
            at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: frame.width, height: frame.height)
        )
    }
}

/// The state line and the agent's description, one left-aligned line each.
/// VoiceOver reads them together as part of the card.
struct SettingsAgentWorkBlockView: View {
    let block: SettingsAgentWorkBlock

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsAgentCardLayout.workBlockLineSpacing) {
            RelaySwap(block.state, style: .text, alignment: .leading) { state in
                Text(state)
                    .foregroundStyle(SettingsSurfaceColor.secondaryText)
            }
            RelaySwap(block.description, style: .text, alignment: .leading) { description in
                Text(description)
                    .foregroundStyle(SettingsSurfaceColor.primaryText)
            }
        }
        .font(AppTypography.font(.caption))
        .lineLimit(1)
        .truncationMode(.tail)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(block.state) \(block.description)")
    }
}

/// The agent's Work style, built like the Workspace's Add project control:
/// the current style, a divider and a chevron, and a click that always opens
/// the menu at the button's trailing edge. The menu checks the current style.
struct SettingsAgentWorkStylePicker: View {
    let agent: SessionAgent
    let style: ProjectWorkStyle
    let onSelect: (ProjectWorkStyle) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isPresented = false

    /// The Add project control's divider and chevron segment.
    static let disclosureWidth: CGFloat = 32
    static let dividerWidth: CGFloat = 1
    static let dividerOpacity: Double = 0.14
    static let menuMinWidth: CGFloat = 300

    private var palette: SharedActionButtonPalette { .settingsSecondary }

    private var presentation: SettingsActionPresentation {
        SettingsActionPresentation.resolve(
            isEnabled: true,
            isHovered: isHovered,
            isFocused: false,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(alignment: .center, spacing: 0) {
                RelaySwap(style.title, style: .text, alignment: .center) { title in
                    Text(title)
                        .font(AppTypography.font(.programAction))
                        .lineLimit(1)
                }
                .padding(.horizontal, SharedActionButtonMetrics.horizontalPadding)
                .frame(height: SharedActionButtonMetrics.controlHeight)
                Rectangle()
                    .fill(palette.foreground.opacity(Self.dividerOpacity))
                    .frame(width: Self.dividerWidth, height: SharedActionButtonMetrics.controlHeight)
                LucideImage(.chevronDown, size: 12)
                    .frame(width: Self.disclosureWidth, height: SharedActionButtonMetrics.controlHeight)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(palette.foreground.opacity(presentation.foregroundOpacity))
            .frame(height: SharedActionButtonMetrics.controlHeight)
            .background(
                SharedActionButtonSurface(
                    prominence: .secondary,
                    presentation: presentation,
                    palette: palette
                )
            )
            .contentShape(
                RoundedRectangle(cornerRadius: SharedActionButtonMetrics.cornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.graphicalPress)
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: presentation.animationDuration), value: presentation)
        .accessibilityLabel(Self.accessibilityLabel(agent))
        .accessibilityValue(style.title)
        .notchHint("Change \(agent.name)'s work style")
        .background {
            SettingsDropdownPresenter(isPresented: $isPresented, minWidth: Self.menuMinWidth, alignsTrailing: true) {
                SettingsMenuOptions(
                    title: Self.accessibilityLabel(agent),
                    selection: Binding(get: { style }, set: { onSelect($0) }),
                    options: ProjectWorkStyle.allCases.map { ($0.title, $0) },
                    subtitle: { $0.detail }
                ) { isPresented = false }
                .environment(\.colorScheme, .dark)
            }
        }
    }

    static func accessibilityLabel(_ agent: SessionAgent) -> String {
        "\(agent.name)'s work style"
    }
}

private struct SettingsAgentParticleView: NSViewRepresentable {
    let theme: ParticleFieldRenderer.Theme
    let activity: ParticleFieldRenderer.OrbActivity
    /// Where this agent's orb starts in its cycle, so the four do not move in step.
    let phase: Double
    let reduceMotion: Bool

    func makeNSView(context: Context) -> SettingsAgentParticleHostView {
        SettingsAgentParticleHostView(phase: phase)
    }

    func updateNSView(_ nsView: SettingsAgentParticleHostView, context: Context) {
        nsView.update(theme: theme, activity: activity, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ nsView: SettingsAgentParticleHostView, coordinator: ()) {
        nsView.stop()
    }
}

final class SettingsAgentParticleHostView: NSView {
    private let renderer = ParticleFieldRenderer(coverage: .agentOrb)
    private var windowObservation: NSObjectProtocol?
    private var theme: ParticleFieldRenderer.Theme = .idle
    private var reduceMotion = false
    private(set) var showsField = false

    init(phase: Double = 0) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        renderer.attach(to: self)
        renderer.setOrbPhase(phase)
        // The card's white core is opaque; overlay intensity applies to the screen field.
        renderer.setIntensity(1)
    }

    required init?(coder: NSCoder) { nil }

    deinit { stop() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layoutInBounds(bounds, backingScale: window?.backingScaleFactor)
        CATransaction.commit()
        refreshVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        if let window {
            windowObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.refreshVisibility() }
        }
        needsLayout = true
        refreshVisibility()
    }

    override func viewDidHide() { super.viewDidHide(); refreshVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshVisibility() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(
        theme: ParticleFieldRenderer.Theme,
        activity: ParticleFieldRenderer.OrbActivity = .standingBy,
        reduceMotion: Bool
    ) {
        self.theme = theme
        self.reduceMotion = reduceMotion
        renderer.setOrbActivity(activity)
        needsLayout = true
        refreshVisibility()
    }

    func stop() {
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        renderer.transition(to: nil)
    }

    private func refreshVisibility() {
        let visible = window?.isVisible == true
            && window?.isMiniaturized == false
            && !isHiddenOrHasHiddenAncestor
        renderer.transition(to: visible ? theme : nil, reduceMotion: reduceMotion)
        guard visible != showsField else { return }
        showsField = visible
        if visible { revealField() }
    }

    /// The orb rises into the card as it sharpens. Its blur filter is only
    /// attached for the entrance because the field redraws every frame.
    private func revealField() {
        RelayLayerMotion.animateIn(self, style: .surface) { [weak self] in
            guard let layer = self?.layer, self?.showsField == true else { return }
            layer.filters = layer.filters?.filter {
                ($0 as? CIFilter)?.name != RelayLayerMotion.blurFilterName
            }
        }
    }

    var isAnimationRunning: Bool { renderer.isAnimationRunning }
}
