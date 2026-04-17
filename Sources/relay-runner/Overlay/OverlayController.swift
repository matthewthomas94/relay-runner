import AppKit
import Combine

/// Manages the overlay panel lifecycle, particle field, transcription pill,
/// and state observation. Bridges StateMachine -> visual output.
/// Always accessed from main thread.
final class OverlayController {

    private var panel: OverlayPanel?
    private let particleField = ParticleFieldRenderer()
    private let pill = TranscriptionPill(frame: .zero)
    private let mediaController = MediaController()
    private var stateObservation: Any?

    private var config: AwarenessConfig

    /// Timestamp when the `.sent` state was entered, for auto-dismiss.
    private var sentTimestamp: Date?

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

        // Attach particle field (blur view + dot layer)
        particleField.attach(to: contentView)
        particleField.setIntensity(config.glow_intensity)
        particleField.onFrameRendered = { [weak self] cgImage, frameInView in
            self?.pill.updateBackdrop(with: cgImage, particleFrame: frameInView)
        }

        // Attach pill
        contentView.addSubview(pill)

        p.orderFrontRegardless()
        self.panel = p

        // Observe state machine and track display changes at 30fps.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self, weak stateMachine] _ in
            guard let self, let sm = stateMachine else { return }
            self.trackDisplay()
            self.tickSentDismiss(sm)
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

        pill.hide(animated: false)
        particleField.transition(to: nil)

        panel?.orderOut(nil)
        panel = nil

        NSLog("[OverlayController] Stopped")
    }

    func updateConfig(_ newConfig: AwarenessConfig) {
        config = newConfig
        particleField.setIntensity(newConfig.glow_intensity)
    }

    // MARK: - Multi-display tracking

    /// Move the overlay panel to whichever screen the cursor is on.
    /// Called from the 30fps timer — no global event monitor (Accessibility) needed.
    private func trackDisplay() {
        guard let p = panel else { return }
        let mouseScreen = NSScreen.screens.first { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        }
        if let screen = mouseScreen, p.frame != screen.frame {
            p.reframe(to: screen)
            if let cv = p.contentView {
                particleField.layoutInBounds(cv.bounds)
            }
        }
    }

    // MARK: - Sent auto-dismiss

    private func tickSentDismiss(_ sm: StateMachine) {
        switch sm.state {
        case .sent, .cancelled(_):
            if sentTimestamp == nil {
                sentTimestamp = Date()
            } else if let ts = sentTimestamp, Date().timeIntervalSince(ts) >= 1.5 {
                sentTimestamp = nil
                sm.dismissSent()
            }
        case .sessionPrompt:
            if sentTimestamp == nil {
                sentTimestamp = Date()
            } else if let ts = sentTimestamp, Date().timeIntervalSince(ts) >= 5.0 {
                sentTimestamp = nil
                sm.dismissSessionPrompt()
            }
        default:
            sentTimestamp = nil
        }
    }

    // MARK: - State application

    private var lastAppliedState: OverlayState = .idle
    private var lastPartial: String = ""
    private var lastPreview: String?

    private func applyState(_ sm: StateMachine) {
        let state = sm.state
        let partial = sm.partialTranscription
        let preview = sm.messagePreview

        // Particle field
        if config.screen_glow {
            if state != lastAppliedState {
                particleField.transition(to: state.particleTheme)
            }
        } else {
            if lastAppliedState != .idle {
                particleField.transition(to: nil)
            }
        }

        // Pill
        switch state {
        case .listening:
            if state != lastAppliedState {
                pill.showCompact(title: "Listening...", theme: .stt)
            }

        case .recording:
            if state != lastAppliedState {
                // Always start with compact pill on recording entry
                pill.showCompact(title: "Recording...", theme: .stt)
            } else if !partial.isEmpty, config.live_transcription, partial != lastPartial {
                // Only expand to full once transcription arrives
                pill.showFull(title: "Recording \u{2014} Press Caps Lock to stop and send", body: partial, theme: .stt)
            }

        case .sent:
            if state != lastAppliedState {
                pill.showCompact(title: "Sent", theme: .stt)
            }

        case .cancelled(let source):
            if state != lastAppliedState {
                if source == .stt {
                    pill.showCompact(title: "Recording cancelled", theme: .stt)
                } else {
                    pill.showCompact(title: "Playback cancelled", theme: .tts)
                }
            }

        case .processing:
            if state != lastAppliedState {
                pill.showCompact(title: "Processing...", theme: .tts)
            }

        case .preparing:
            if state != lastAppliedState {
                pill.showCompact(title: "Preparing...", theme: .tts)
            }

        case .messageWaiting:
            if config.message_preview, let preview {
                if preview != lastPreview || state != lastAppliedState {
                    pill.showFull(title: "Message Queued \u{2014} Double tap Option to play", body: preview, theme: .tts)
                }
            } else if state != lastAppliedState {
                pill.showCompact(title: "Message Queued...", theme: .tts)
            }

        case .speaking:
            if config.message_preview, let preview {
                if state != lastAppliedState || preview != lastPreview {
                    pill.showFull(title: "Message Playing \u{2014} Double tap Control to cancel", body: preview, theme: .tts)
                }
            } else if state != lastAppliedState {
                pill.showCompact(title: "Message Playing...", theme: .tts)
            }

        case .sessionPrompt:
            if state != lastAppliedState {
                pill.showFull(
                    title: "No session running",
                    body: "Double tap Option to start a new session\nPress Caps Lock to dismiss",
                    theme: .stt,
                    suppressShadow: true
                )
            }

        default:
            if lastAppliedState != state || !lastPartial.isEmpty || lastPreview != nil {
                pill.hide()
            }
        }

        // Media control: pause during recording/speaking, resume after
        let wasActive = Self.isVoiceActive(lastAppliedState)
        let isActive = Self.isVoiceActive(state)
        if !wasActive && isActive {
            NSLog("[OverlayController] Voice active \u{2192} pausing media (state=\(state))")
            mediaController.pauseIfPlaying()
        } else if wasActive && !isActive {
            NSLog("[OverlayController] Voice inactive \u{2192} resuming media (state=\(state))")
            mediaController.resumeIfWePaused()
        }

        lastAppliedState = state
        lastPartial = partial
        lastPreview = preview
    }

    private static func isVoiceActive(_ state: OverlayState) -> Bool {
        switch state {
        case .recording, .speaking:
            return true
        default:
            return false
        }
    }
}
