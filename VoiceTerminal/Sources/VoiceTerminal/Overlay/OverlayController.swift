import AppKit
import Combine

/// Manages the overlay panel lifecycle, glow rendering, transcription pill,
/// and state observation. Bridges StateMachine -> visual output.
/// Always accessed from main thread.
final class OverlayController {

    private var panel: OverlayPanel?
    private let glowRenderer = GlowRenderer()
    private let pill = TranscriptionPill(frame: .zero)
    private var displayTracker: Any?  // global mouse monitor
    private var stateObservation: Any?

    private var config: AwarenessConfig

    init(config: AwarenessConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start(stateMachine: StateMachine) {
        guard panel == nil else { return }

        let p = OverlayPanel()

        // Set up layer-backed content view
        let contentView = NSView(frame: p.frame)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = contentView

        // Attach glow
        if let layer = contentView.layer {
            glowRenderer.attach(to: layer)
            glowRenderer.setIntensity(config.glow_intensity)
        }

        // Attach pill
        contentView.addSubview(pill)

        p.orderFrontRegardless()
        self.panel = p

        // Track cursor for multi-display
        displayTracker = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, let p = self.panel else { return }
            let mouseScreen = NSScreen.screens.first { screen in
                NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
            }
            if let screen = mouseScreen, p.frame != screen.frame {
                p.reframe(to: screen)
                if let layer = p.contentView?.layer {
                    self.glowRenderer.layoutLayers(in: layer.bounds)
                }
            }
        }

        // Observe state machine with a polling timer (Observation framework
        // doesn't have a direct KVO-like callback for non-SwiftUI usage,
        // so we poll at display-refresh rate).
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self, weak stateMachine] _ in
            guard let self, let sm = stateMachine else { return }
            self.applyState(sm)
        }
        RunLoop.main.add(timer, forMode: .common)
        stateObservation = timer

        NSLog("[OverlayController] Started")
    }

    func stop() {
        if let timer = stateObservation as? Timer {
            timer.invalidate()
        }
        stateObservation = nil

        if let monitor = displayTracker {
            NSEvent.removeMonitor(monitor)
        }
        displayTracker = nil

        pill.hide(animated: false)
        glowRenderer.transition(to: .idle)

        panel?.orderOut(nil)
        panel = nil

        NSLog("[OverlayController] Stopped")
    }

    func updateConfig(_ newConfig: AwarenessConfig) {
        config = newConfig
        glowRenderer.setIntensity(newConfig.glow_intensity)
    }

    // MARK: - State application

    private var lastAppliedState: OverlayState = .idle
    private var lastPartial: String = ""
    private var lastPreview: String?

    private func applyState(_ sm: StateMachine) {
        let state = sm.state
        let partial = sm.partialTranscription
        let preview = sm.messagePreview

        // Glow
        if config.screen_glow {
            if state != lastAppliedState {
                glowRenderer.transition(to: state)
            }
        } else {
            if lastAppliedState != .idle {
                glowRenderer.transition(to: .idle)
            }
        }

        // Pill: show transcription during recording, preparing status, or message preview
        if case .recording = state, config.live_transcription {
            if partial != lastPartial {
                pill.update(text: partial.isEmpty ? nil : partial)
            }
        } else if case .preparing = state {
            if state != lastAppliedState {
                pill.update(text: "Preparing response\u{2026}")
            }
        } else if case .messageWaiting = state, config.message_preview {
            if preview != lastPreview {
                pill.update(text: preview)
            }
        } else {
            if lastAppliedState != state || !lastPartial.isEmpty || lastPreview != nil {
                pill.hide()
            }
        }

        lastAppliedState = state
        lastPartial = partial
        lastPreview = preview
    }
}
