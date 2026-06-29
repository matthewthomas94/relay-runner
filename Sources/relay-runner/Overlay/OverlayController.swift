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

    /// Timestamp when the currently-auto-dismissing state was entered.
    /// Reset whenever the state changes so each state gets its own window.
    private var autoDismissTimestamp: Date?
    /// The state being timed by `autoDismissTimestamp`. Used to detect state
    /// changes within the auto-dismiss family — e.g. .sent → .processing —
    /// so we restart the clock instead of carrying over the .sent elapsed.
    private var autoDismissState: OverlayState?

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
            self.tickAutoDismiss(sm)
            self.applyState(sm)
            self.tickPanelClickThrough()
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

    // MARK: - Selective click-through

    /// Last applied click-through state — skips redundant property writes
    /// most ticks (the panel is click-through 99% of the time).
    private var panelIgnoresMouseEvents: Bool = true

    /// Polled at 30fps from the same timer that drives state observation.
    /// Default: panel is click-through (events pass through to underlying
    /// apps). When the cursor enters the pill's screen-space frame, the
    /// panel temporarily intercepts events so the pill's scrollWheel
    /// handler can drive manual body scroll. ~33ms transition latency is
    /// imperceptible in practice and avoids the overhead of NSEvent
    /// global/local monitor pairs.
    private func tickPanelClickThrough() {
        guard let panel else { return }
        let cursorOverPill: Bool
        if let pillRect = pill.pillFrameOnScreen() {
            cursorOverPill = pillRect.contains(NSEvent.mouseLocation)
        } else {
            cursorOverPill = false
        }
        let shouldIgnore = !cursorOverPill
        if panelIgnoresMouseEvents != shouldIgnore {
            panel.ignoresMouseEvents = shouldIgnore
            panelIgnoresMouseEvents = shouldIgnore
        }
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

    // MARK: - Auto-dismiss

    /// Drives the pill toward .idle for states that should fade themselves out
    /// after a fixed window. User-message acknowledgements use an explicit
    /// state so substantive TTS responses are not dismissed by this path.
    private func tickAutoDismiss(_ sm: StateMachine) {
        sm.promotePendingAcknowledgementIfReady()
        let state = sm.state
        guard let timeout = Self.autoDismissTimeout(for: state) else {
            autoDismissTimestamp = nil
            autoDismissState = nil
            return
        }

        if autoDismissState != state {
            // State just entered (or switched between auto-dismiss states) —
            // restart the clock so each state gets its full window.
            autoDismissTimestamp = Date()
            autoDismissState = state
            return
        }

        guard let ts = autoDismissTimestamp,
              Date().timeIntervalSince(ts) >= timeout else { return }

        autoDismissTimestamp = nil
        autoDismissState = nil

        switch state {
        case .sent, .cancelled(_):
            sm.dismissSent()
        case .acknowledgement:
            sm.dismissAcknowledgement()
        case .processing:
            sm.dismissProcessing()
        case .sessionPrompt:
            sm.dismissSessionPrompt()
        case .programStatus:
            sm.dismissProgramStatus()
        default:
            break
        }
    }

    private static func autoDismissTimeout(for state: OverlayState) -> TimeInterval? {
        switch state {
        case .acknowledgement(_, let autoDismiss):
            return autoDismiss
        case .sent, .cancelled(_):
            return StateMachine.sentAutoDismissDuration
        case .processing:
            return 1.0
        case .sessionPrompt:
            return 5.0
        case .programStatus:
            return 6.0
        default:
            return nil
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
                pill.showCompact(title: "Thinking\u{2026}", theme: .tts)
            }

        case .acknowledgement(let text, _):
            if state != lastAppliedState {
                pill.showAcknowledgement(text: text, theme: .tts)
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

        case .programStatus(let title, let body):
            if state != lastAppliedState {
                pill.showFull(title: title, body: body, theme: .tts)
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
