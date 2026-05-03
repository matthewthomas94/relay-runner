import AppKit
import QuartzCore

// Purple glow around the perimeter of every connected screen while
// `OverlayState.computerVision` is active. Pulses brighter when an
// `awaitingConfirmation` prompt is surfaced — visual signal that the
// user needs to double-tap Option (yes) or Control (no).
//
// Architecture:
// - One NSPanel per NSScreen, screen-saver level, click-through, transparent.
// - Each panel hosts a PerimeterView with four CAGradientLayer bands (top /
//   bottom / left / right) that fade from edge-opaque to inward-transparent.
//   GPU-accelerated, no filters or off-screen passes.
// - Color matches ParticleFieldRenderer.Theme.tts (hue 0.68 / sat 0.80) so the
//   perimeter feels visually identical to the existing reply state.
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
    private let perimeterView = PerimeterView()

    init(for screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
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
        setFrame(screen.frame, display: false)

        perimeterView.frame = NSRect(origin: .zero, size: screen.frame.size)
        contentView = perimeterView
    }

    func setVisible(_ visible: Bool, pulsing: Bool) {
        // Crossfade the panel; PerimeterView handles internal pulse.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = visible ? 1.0 : 0.0
        }
        perimeterView.setPulsing(pulsing)
    }
}

// MARK: - View

private final class PerimeterView: NSView {

    /// Band thickness in points. Spec calls for ~24pt.
    private let bandThickness: CGFloat = 24

    // .tts theme color from ParticleFieldRenderer (hue 0.68 / sat 0.80, value
    // chosen to read clearly against typical dark and light backgrounds).
    private let bandColor = NSColor(hue: 0.68, saturation: 0.80, brightness: 0.95, alpha: 1.0)

    private let topBand = CAGradientLayer()
    private let bottomBand = CAGradientLayer()
    private let leftBand = CAGradientLayer()
    private let rightBand = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configureBands()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layoutBands()
    }

    override var isFlipped: Bool { false }   // origin bottom-left, matches AppKit

    private func configureBands() {
        let opaque = bandColor.cgColor
        let clear = bandColor.withAlphaComponent(0).cgColor

        for band in [topBand, bottomBand, leftBand, rightBand] {
            band.colors = [opaque, clear]
            band.locations = [0.0, 1.0]
            // Subtle ease — start strong, fall off quickly. Most of the visual
            // weight lives in the first ~25% of the band.
            band.startPoint = .zero
            band.endPoint = .zero
            layer?.addSublayer(band)
        }

        // Direction per band: each fades from the edge inward.
        // (start → end goes solid → transparent)
        topBand.startPoint = CGPoint(x: 0.5, y: 1.0)        // top edge (in bottom-left origin)
        topBand.endPoint   = CGPoint(x: 0.5, y: 0.0)
        bottomBand.startPoint = CGPoint(x: 0.5, y: 0.0)     // bottom edge
        bottomBand.endPoint   = CGPoint(x: 0.5, y: 1.0)
        leftBand.startPoint = CGPoint(x: 0.0, y: 0.5)
        leftBand.endPoint   = CGPoint(x: 1.0, y: 0.5)
        rightBand.startPoint = CGPoint(x: 1.0, y: 0.5)
        rightBand.endPoint   = CGPoint(x: 0.0, y: 0.5)
    }

    private func layoutBands() {
        let b = bounds
        let t = bandThickness
        // Side bands span the full height; top/bottom bands span only the
        // middle so the corners aren't double-painted (the side gradient
        // already handles them).
        topBand.frame = NSRect(x: 0, y: b.height - t, width: b.width, height: t)
        bottomBand.frame = NSRect(x: 0, y: 0, width: b.width, height: t)
        leftBand.frame = NSRect(x: 0, y: 0, width: t, height: b.height)
        rightBand.frame = NSRect(x: b.width - t, y: 0, width: t, height: b.height)
    }

    func setPulsing(_ pulsing: Bool) {
        // Implementation: animate layer opacity between two values. Removes any
        // running animation first so toggling on/off doesn't compound.
        for band in [topBand, bottomBand, leftBand, rightBand] {
            band.removeAnimation(forKey: "pulse")
        }

        if pulsing {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.55
            pulse.toValue = 1.0
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for band in [topBand, bottomBand, leftBand, rightBand] {
                band.add(pulse, forKey: "pulse")
            }
        } else {
            // Steady state: a calmer 0.65 opacity so it reads as "active but
            // not demanding action." Set as the model value so it sticks once
            // any in-flight animation finishes.
            for band in [topBand, bottomBand, leftBand, rightBand] {
                band.opacity = 0.65
            }
        }
    }
}
