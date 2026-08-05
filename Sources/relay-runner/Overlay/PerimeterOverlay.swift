import AppKit
import QuartzCore

enum RelayVisionOverlayWindowPolicy {
    static let actionGlowWindowTitle = "Relay Runner ActionGlow"
    static let windowLevel = NSWindow.Level(
        rawValue: NSWindow.Level.screenSaver.rawValue + 2
    )

    static func configure(_ window: NSWindow) {
        window.level = windowLevel
        window.sharingType = .none
        window.title = actionGlowWindowTitle
    }

    static func shouldExcludeFromCapture(
        ownerProcessID: pid_t?,
        windowLayer: Int,
        title: String?
    ) -> Bool {
        guard ownerProcessID == getpid() else { return false }
        return windowLayer == Int(windowLevel.rawValue)
            || title == actionGlowWindowTitle
    }
}

// Halftone-dot perimeter around every connected screen while
// `OverlayState.actionGlow` is active. Pulses brighter when an
// `awaitingConfirmation` prompt is surfaced — visual signal that the
// user needs to double-tap Option (yes) or Control (no).
//
// Architecture:
// - One NSPanel per NSScreen, above every Relay Runner surface, click-through,
//   transparent, and excluded from capture.
// - Each panel hosts a PerimeterParticleField — same dot grid + animation as
//   ParticleFieldRenderer, but the visibility mask favors dots within ~90pt
//   of any edge instead of along the bottom. Uses the `.stt` color palette
//   because ActionGlow means "the agent is reading the screen" — a recording
//   surface, conceptually, not a playback one.
// - Rebuilds on NSApplication.didChangeScreenParametersNotification so screen
//   add/remove takes effect immediately.
//
// Threading: NSPanel manipulation must happen on the main thread. The timer-
// based state observation (mirroring OverlayController's pattern) runs on the
// main run loop, so all panel operations naturally land on main.

final class PerimeterOverlayManager {

    private var panels: [PerimeterPanel] = []
    private var stateTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    private weak var stateMachine: StateMachine?

    /// Last applied (visible, pulsing) tuple. Used to skip redundant updates
    /// in the 30Hz timer — most ticks are no-ops.
    private var lastVisible = false
    private var lastPulsing = false

    func start(stateMachine: StateMachine) {
        self.stateMachine = stateMachine

        rebuildPanels()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildPanels()
        }

        // 30Hz observation matches OverlayController's cadence — fast enough
        // for the pulse animation, cheap enough to leave on always.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.applyState()
        }
        RunLoop.main.add(timer, forMode: .common)
        stateTimer = timer
    }

    func stop() {
        stateTimer?.invalidate()
        stateTimer = nil
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }

    private func rebuildPanels() {
        // Tear down everything — NSScreen identity isn't stable across changes
        // (screens can swap order), and the cost of recreating ~3 panels is
        // negligible.
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()

        for screen in NSScreen.screens {
            let panel = PerimeterPanel(for: screen)
            // Panel itself stays at full alpha — visibility is controlled
            // entirely by the particle field's layer opacity, which fades
            // between 0 (hidden) / 0.75 (steady CV) / pulse-animated (waiting).
            // Earlier this was alphaValue=0 with the intention of crossfading
            // the whole panel, but the refactor moved opacity control into
            // PerimeterParticleField — leaving the panel at 0 made the
            // overlay invisible regardless of state. The field starts hidden
            // (active=false), so nothing renders until applyState() flips it.
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        // Re-apply current state so a screen attach during ActionGlow
        // mode doesn't leave the new screen dark.
        lastVisible = false
        lastPulsing = false
        applyState()
    }

    private func applyState() {
        let state = stateMachine?.state ?? .idle
        let visible: Bool
        let pulsing: Bool
        switch state {
        case .actionGlow(let prompt):
            visible = true
            pulsing = (prompt != nil)
        default:
            visible = false
            pulsing = false
        }

        if visible == lastVisible && pulsing == lastPulsing {
            return
        }
        lastVisible = visible
        lastPulsing = pulsing

        // Diagnostic — surfaces in Console.app so it's easy to confirm the
        // bus → state → overlay chain works without watching for visual cues.
        NSLog("[PerimeterOverlay] state=\(state) → visible=\(visible) pulsing=\(pulsing) (panels: \(panels.count))")

        for panel in panels {
            panel.setVisible(visible, pulsing: pulsing)
        }
    }
}

// MARK: - Panel

private final class PerimeterPanel: NSPanel {
    private let hostView: NSView
    private let particleField: PerimeterParticleField

    init(for screen: NSScreen) {
        let frame = screen.frame
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        self.hostView = view

        let field = PerimeterParticleField(theme: .stt)
        // Match the host screen's backing scale before attach so the bitmap
        // context is sized correctly — multi-display setups can mix 1× and 2×.
        field.setBackingScale(screen.backingScaleFactor)
        self.particleField = field

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        RelayVisionOverlayWindowPolicy.configure(self)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true       // click-through (spec requirement)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        setFrame(frame, display: false)

        contentView = hostView
        particleField.attach(to: hostView)
    }

    func setVisible(_ visible: Bool, pulsing: Bool) {
        // PerimeterParticleField handles its own opacity transitions and
        // pulse animation — the panel itself stays fully opaque so the
        // dot rendering controls every visible byte.
        particleField.setActive(visible, pulsing: pulsing)
    }
}
