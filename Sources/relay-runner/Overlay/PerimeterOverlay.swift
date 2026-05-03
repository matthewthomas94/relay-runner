import AppKit
import QuartzCore

// Halftone-dot perimeter around every connected screen while
// `OverlayState.computerVision` is active. Pulses brighter when an
// `awaitingConfirmation` prompt is surfaced — visual signal that the
// user needs to double-tap Option (yes) or Control (no).
//
// Architecture:
// - One NSPanel per NSScreen, screen-saver level, click-through, transparent.
// - Each panel hosts a PerimeterParticleField — same dot grid + animation as
//   ParticleFieldRenderer, but the visibility mask favors dots within ~90pt
//   of any edge instead of along the bottom. Identical color palette to the
//   .tts reply state so the two surfaces feel like one effect.
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
            // Hidden by default — applyState() shows when state warrants it.
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        // Re-apply current state so a screen attach during computer-vision
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
        case .computerVision(let prompt):
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

        let field = PerimeterParticleField(theme: .tts)
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
        // Same level as OverlayPanel so we sit above full-screen apps. Using
        // .screenSaver (highest non-system level) means notification banners
        // and Spotlight still appear on top — appropriate, since those are
        // user-initiated UI.
        level = .screenSaver
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
