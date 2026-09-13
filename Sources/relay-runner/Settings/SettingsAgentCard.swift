import AppKit
import SwiftUI

struct SettingsAgentPresentation: Equatable {
    let name: String
    let subtitle: String

    static func voiceName(_ config: TtsConfig, customName: String?) -> String {
        if config.custom_voice_id != nil {
            let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "George" : name
        }
        let parts = config.voice.split(separator: "_", maxSplits: 1)
        let name = parts.count == 2 ? String(parts[1]) : config.voice
        return name.isEmpty ? "Agent" : name.prefix(1).uppercased() + name.dropFirst()
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

enum SettingsAgentCardLayout {
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 12

    static func width(availableWidth: CGFloat) -> CGFloat {
        min(480, max(220, (availableWidth - spacing) * 480 / 1672))
    }
}

struct SettingsAgentCard: View {
    let presentation: SettingsAgentPresentation
    let handoff: AgentParticleHandoff
    var intensity: Double = AwarenessConfig().glow_intensity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            BoardDarkSurfaceStyle.panelFill
            SettingsAgentParticleView(
                handoff: handoff,
                departure: handoff.cardDeparture,
                blurRadius: handoff.cardBlurRadius,
                intensity: intensity,
                reduceMotion: reduceMotion
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(spacing: 11) {
                Text(presentation.name)
                    .font(AppTypography.font(.appTitle, size: 24))
                    .tracking(-0.5)
                    .foregroundStyle(SettingsSurfaceColor.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(presentation.subtitle)
                    .font(AppTypography.font(.settingsDescription, size: 12))
                    .foregroundStyle(SettingsSurfaceColor.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 61)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: SettingsAgentCardLayout.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsAgentCardLayout.cornerRadius)
                .strokeBorder(BoardDarkSurfaceStyle.border, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Orchestrator, \(presentation.name)")
        .accessibilityValue(presentation.subtitle)
    }
}

private struct SettingsAgentParticleView: NSViewRepresentable {
    let handoff: AgentParticleHandoff
    let departure: CGFloat
    let blurRadius: CGFloat
    let intensity: Double
    let reduceMotion: Bool

    func makeNSView(context: Context) -> SettingsAgentParticleHostView {
        SettingsAgentParticleHostView(handoff: handoff)
    }

    func updateNSView(_ nsView: SettingsAgentParticleHostView, context: Context) {
        nsView.update(departure: departure, blurRadius: blurRadius,
                      reduceMotion: reduceMotion, intensity: intensity)
    }

    static func dismantleNSView(_ nsView: SettingsAgentParticleHostView, coordinator: ()) {
        nsView.stop()
    }
}

final class SettingsAgentParticleHostView: NSView {
    private let renderer = ParticleFieldRenderer(coverage: .agentCard)
    private let handoff: AgentParticleHandoff
    private let cardID = UUID()
    private var windowObservation: NSObjectProtocol?
    private var departure: CGFloat = 0
    private var reduceMotion = false

    init(handoff: AgentParticleHandoff) {
        self.handoff = handoff
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        renderer.attach(to: self)
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

    func update(departure: CGFloat, blurRadius: CGFloat = 0, reduceMotion: Bool,
                intensity: Double = AwarenessConfig().glow_intensity) {
        self.departure = departure
        self.reduceMotion = reduceMotion
        renderer.setIntensity(intensity)
        renderer.setDeparture(departure, blurRadius: blurRadius)
        needsLayout = true
        refreshVisibility()
    }

    func stop() {
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        handoff.setCardVisible(false, id: cardID)
        renderer.transition(to: nil)
    }

    private func refreshVisibility() {
        let visible = window?.isVisible == true
            && window?.isMiniaturized == false
            && !isHiddenOrHasHiddenAncestor
        handoff.setCardVisible(visible, id: cardID)
        renderer.transition(to: visible && departure < 1 ? .tts : nil, reduceMotion: reduceMotion)
    }

    var isAnimationRunning: Bool { renderer.isAnimationRunning }
}
