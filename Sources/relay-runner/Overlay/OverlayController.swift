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
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?

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

        // Attach particle field behind the solid pill surfaces.
        particleField.attach(to: contentView)
        particleField.setIntensity(config.glow_intensity)

        // Attach pill
        contentView.addSubview(pill)

        p.orderFrontRegardless()
        self.panel = p
        panelIgnoresMouseEvents = true
        installPointerMonitors()

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
        removePointerMonitors()

        pill.hide(animated: false)
        particleField.transition(to: nil)

        panel?.orderOut(nil)
        panel = nil
        panelIgnoresMouseEvents = true

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

    /// Pointer monitors update this immediately when the cursor moves. The
    /// 30fps state timer also calls it so pill animation, resize, display
    /// changes, or hiding under a stationary cursor cannot leave stale
    /// interception behind.
    private func tickPanelClickThrough() {
        reconcilePanelClickThrough(at: NSEvent.mouseLocation)
    }

    private func reconcilePanelClickThrough(at screenPoint: NSPoint) {
        guard let panel else { return }
        let shouldIgnore = Self.shouldIgnoreMouseEvents(
            at: screenPoint,
            manualScrollFrame: pill.manualScrollFrameOnScreen()
        )
        if panelIgnoresMouseEvents != shouldIgnore {
            panel.ignoresMouseEvents = shouldIgnore
            panelIgnoresMouseEvents = shouldIgnore
        }
    }

    static func shouldIgnoreMouseEvents(
        at screenPoint: NSPoint,
        manualScrollFrame: NSRect?
    ) -> Bool {
        guard let manualScrollFrame else { return true }
        return !manualScrollFrame.contains(screenPoint)
    }

    private func installPointerMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.reconcilePanelClickThrough(at: Self.screenLocation(for: event))
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.reconcilePanelClickThrough(at: Self.screenLocation(for: event))
            return event
        }
    }

    private static func screenLocation(for event: NSEvent) -> NSPoint {
        guard let window = event.window else {
            // Global monitor events report locationInWindow in screen space.
            return event.locationInWindow
        }
        let pointRect = NSRect(origin: event.locationInWindow, size: .zero)
        return window.convertToScreen(pointRect).origin
    }

    private func removePointerMonitors() {
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
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
        case .sessionReady:
            sm.dismissSessionReady()
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
        case .sessionReady:
            return 2.0
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

    static func pillStatusTitle(for state: OverlayState) -> String? {
        NotchActivityLabelPlanner.label(for: state)
    }

    static func compactPillTitle(for state: OverlayState, suffix: String = "") -> String? {
        switch state {
        case .listening, .recording:
            return "Start speaking"
        case .sessionReady:
            return "Hello, what would you like to work on?"
        default:
            break
        }
        guard let title = pillStatusTitle(for: state) else { return nil }
        return title + suffix
    }

    static func fullPillTitle(for state: OverlayState, actionHint: String) -> String? {
        guard pillStatusTitle(for: state) != nil else { return nil }
        return actionHint
    }

    static func previewBody(
        for state: OverlayState,
        messagePreview: String?,
        messagePreviewEnabled: Bool
    ) -> String? {
        _ = messagePreviewEnabled
        guard let messagePreview else { return nil }
        switch state {
        case .messageWaiting, .preparing, .speaking, .speechFailed, .cancelled(.tts):
            return messagePreview
        default:
            return nil
        }
    }

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
            if state != lastAppliedState,
               let title = Self.compactPillTitle(for: state, suffix: "...") {
                pill.showCompact(title: title, theme: .stt)
            }

        case .recording:
            if state != lastAppliedState {
                // Always start with compact pill on recording entry
                if let title = Self.compactPillTitle(for: state, suffix: "...") {
                    pill.showCompact(title: title, theme: .stt)
                }
            } else if !partial.isEmpty, config.live_transcription, partial != lastPartial {
                // Only expand to full once transcription arrives
                if let title = Self.fullPillTitle(for: state, actionHint: "Press Caps Lock to stop and send") {
                    pill.showFull(title: title, body: partial, theme: .stt)
                }
            }

        case .sent:
            if state != lastAppliedState,
               let title = Self.compactPillTitle(for: state) {
                pill.showCompact(title: title, theme: .stt)
            }

        case .cancelled(let source):
            if state != lastAppliedState {
                if let preview = Self.previewBody(
                    for: state,
                    messagePreview: preview,
                    messagePreviewEnabled: config.message_preview
                ), let title = Self.fullPillTitle(for: state, actionHint: "Response cancelled") {
                    pill.showFull(title: title, body: preview, theme: .tts)
                } else if let title = Self.compactPillTitle(for: state) {
                    pill.showCompact(title: title, theme: source == .stt ? .stt : .tts)
                }
            }

        case .speechFailed:
            if state != lastAppliedState || preview != lastPreview {
                if let preview = Self.previewBody(
                    for: state,
                    messagePreview: preview,
                    messagePreviewEnabled: config.message_preview
                ), let title = Self.fullPillTitle(for: state, actionHint: "Speech unavailable") {
                    pill.showFull(title: title, body: preview, theme: .tts)
                } else if let title = Self.compactPillTitle(for: state) {
                    pill.showCompact(title: title, theme: .tts)
                }
            }

        case .processing:
            if state != lastAppliedState,
               let title = Self.compactPillTitle(for: state, suffix: "\u{2026}") {
                pill.showCompact(title: title, theme: .tts)
            }

        case .acknowledgement:
            if state != lastAppliedState {
                pill.hide()
            }

        case .preparing:
            if let preview = Self.previewBody(
                for: state,
                messagePreview: preview,
                messagePreviewEnabled: config.message_preview
            ) {
                if state != lastAppliedState || preview != lastPreview,
                   let title = Self.fullPillTitle(for: state, actionHint: "Preparing speech...") {
                    pill.showFull(title: title, body: preview, theme: .tts)
                }
            } else if state != lastAppliedState,
                      let title = Self.compactPillTitle(for: state, suffix: "...") {
                pill.showCompact(title: title, theme: .tts)
            }

        case .messageWaiting:
            if let preview = Self.previewBody(
                for: state,
                messagePreview: preview,
                messagePreviewEnabled: config.message_preview
            ) {
                if preview != lastPreview || state != lastAppliedState,
                   let title = Self.fullPillTitle(for: state, actionHint: "Double tap Option to play") {
                    pill.showFull(title: title, body: preview, theme: .tts)
                }
            } else if state != lastAppliedState,
                      let title = Self.compactPillTitle(for: state, suffix: "...") {
                pill.showCompact(title: title, theme: .tts)
            }

        case .speaking:
            if let preview = Self.previewBody(
                for: state,
                messagePreview: preview,
                messagePreviewEnabled: config.message_preview
            ) {
                if state != lastAppliedState || preview != lastPreview,
                   let title = Self.fullPillTitle(for: state, actionHint: "Double tap Control to cancel") {
                    pill.showFull(title: title, body: preview, theme: .tts)
                }
            } else if state != lastAppliedState,
                      let title = Self.compactPillTitle(for: state, suffix: "...") {
                pill.showCompact(title: title, theme: .tts)
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

        case .sessionReady:
            if state != lastAppliedState,
               let title = Self.compactPillTitle(for: state) {
                pill.showCompact(title: title, theme: .tts)
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
