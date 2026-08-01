import Foundation

/// A pending Relay Actions confirmation surfaced by `propose_action` in the
/// RelayActionsMCP server. While a prompt is non-nil, the modifier double-tap
/// gestures (Option/Control) are repurposed as yes/no instead of play/cancel.
struct ConfirmationPrompt: Equatable {
    /// Human-readable summary, e.g. "Click 'Send' in Slack".
    let summary: String
    /// "low" | "medium" | "high". `low` is auto-confirmed before the prompt is
    /// surfaced, so any value reaching the UI is medium or high.
    let risk: String
    /// Opaque correlation id from the MCP server — round-tripped back so the
    /// MCP server matches the reply to the right outstanding request.
    let requestId: String
}

/// Possible overlay states, driven by STT engine (in-process) and Python services (via socket).
enum OverlayState: Equatable {
    case idle
    case listening
    case recording
    case sent          // Brief confirmation after recording stops
    case cancelled(CancelSource)  // User cancelled recording or TTS

    enum CancelSource: Equatable {
        case stt   // Cancelled during recording
        case tts   // Cancelled during playback/response
    }
    case processing
    case acknowledgement(text: String, autoDismiss: TimeInterval)
    case messageWaiting(preview: String?)
    case preparing
    case speaking
    case speechFailed
    case paused
    case sessionPrompt   // No session running — prompt user to start one
    case sessionReady
    case programStatus(title: String, body: String)
    /// RelayActionsMCP has fired at least one tool recently. Triggers the
    /// purple perimeter overlay. `awaitingConfirmation` is non-nil while a
    /// `propose_action(risk: medium|high)` is blocked waiting on the user's
    /// double-tap response.
    case actionGlow(awaitingConfirmation: ConfirmationPrompt?)

    /// Which particle field theme to show on the bottom-of-screen overlay
    /// (nil = hidden). The .actionGlow state intentionally returns nil
    /// here — its dot pattern lives in PerimeterParticleField, rendered
    /// around the screen edges by PerimeterOverlay, not at the bottom.
    var particleTheme: ParticleFieldRenderer.Theme? {
        switch self {
        case .idle, .paused, .sent, .cancelled(_), .acknowledgement, .speechFailed,
             .sessionPrompt, .actionGlow:
            return nil
        case .listening, .recording:
            return .stt
        case .processing, .messageWaiting, .preparing, .speaking, .sessionReady, .programStatus:
            return .tts
        }
    }

    /// Which pill color theme to use.
    var pillTheme: TranscriptionPill.Theme {
        switch self {
        case .recording, .sent, .cancelled(.stt):
            return .stt
        case .cancelled(.tts):
            return .tts
        case .processing, .acknowledgement, .messageWaiting, .preparing, .speaking,
             .speechFailed, .sessionReady, .programStatus, .actionGlow:
            return .tts
        default:
            return .tts
        }
    }
}

/// Central state machine. Consumes events from STTEngine (in-process) and StateEventBus (Python).
/// Always accessed from main thread (timers, StateEventBus MainActor dispatch).
@Observable
final class StateMachine: @unchecked Sendable {
    static let sentAutoDismissDuration: TimeInterval = 1.5
    static let acknowledgementDelayAfterSent: TimeInterval = 1.0
    static let workingProgressFreshnessDuration: TimeInterval = 12.0

    private struct PendingAcknowledgement {
        let text: String
        let autoDismiss: TimeInterval
        let presentAt: Date
    }

    private(set) var state: OverlayState = .idle
    private(set) var partialTranscription: String = ""
    private(set) var messagePreview: String?
    private(set) var workingProgress: String?
    private(set) var workingProgressUpdatedAt: Date?

    private let now: () -> Date
    private var stateBeforeIdle: OverlayState = .idle
    private var lastIdleTransitionTime: Date = .distantPast
    private var sentEnteredAt: Date?
    private var pendingAcknowledgement: PendingAcknowledgement?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Called by AppState when STT engine state changes.
    func updateSTT(isRecording: Bool, partial: String) {
        partialTranscription = partial

        if isRecording {
            state = .recording
        } else if case .recording = state {
            // Stopped recording — show brief "Sent" confirmation.
            state = .sent
            sentEnteredAt = now()
            partialTranscription = ""
        }
    }

    /// Called by StateEventBus when Python services send state updates.
    func handleServiceEvent(source: String, newState: String, text: String?, autoDismiss: TimeInterval? = nil) {
        switch (source, newState) {
        case ("tts", "message_waiting"):
            pendingAcknowledgement = nil
            clearWorkingProgress()
            let preview = normalizedMessagePreview(text) ?? messagePreview
            guard preview != nil else { break }
            messagePreview = preview
            switch state {
            case .preparing, .speaking:
                break
            default:
                state = .messageWaiting(preview: preview)
            }

        case ("tts", "preparing"):
            pendingAcknowledgement = nil
            clearWorkingProgress()
            if let preview = normalizedMessagePreview(text) {
                messagePreview = preview
            }
            state = .preparing

        case ("tts", "speaking"):
            pendingAcknowledgement = nil
            clearWorkingProgress()
            if let preview = normalizedMessagePreview(text) {
                messagePreview = preview
            }
            state = .speaking

        case ("tts", "failed"):
            pendingAcknowledgement = nil
            clearWorkingProgress()
            if let preview = normalizedMessagePreview(text) {
                messagePreview = preview
            }
            state = .speechFailed

        case ("tts", "idle"):
            switch state {
            case .speaking, .preparing, .messageWaiting:
                stateBeforeIdle = state
                lastIdleTransitionTime = now()
                state = .idle
                messagePreview = nil
            default:
                break
            }

        case ("bridge", "processing"):
            switch state {
            case .recording, .cancelled(_):
                break  // don't override these transient states
            default:
                // .sent → .processing is intentional: surfaces "Thinking…" the
                // moment STT finalizes, instead of waiting on the .sent timer.
                state = .processing
            }

        case ("bridge", "working"):
            workingProgress = Self.normalizedWorkingProgress(text)
            workingProgressUpdatedAt = workingProgress == nil ? nil : now()

        case ("bridge", "acknowledgement"):
            let acknowledgement = acknowledgementState(
                text: text,
                autoDismiss: autoDismiss
            )
            switch state {
            case .sent:
                let presentAt = max(
                    now(),
                    (sentEnteredAt ?? now())
                        .addingTimeInterval(
                            Self.sentAutoDismissDuration + Self.acknowledgementDelayAfterSent
                        )
                )
                pendingAcknowledgement = PendingAcknowledgement(
                    text: acknowledgement.text,
                    autoDismiss: acknowledgement.autoDismiss,
                    presentAt: presentAt
                )
            case .idle, .processing, .acknowledgement:
                applyAcknowledgement(acknowledgement)
            default:
                break
            }

        case ("bridge", "idle"):
            clearWorkingProgress()
            if case .processing = state {
                stateBeforeIdle = state
                lastIdleTransitionTime = now()
                state = .idle
            }

        default:
            break
        }
    }

    /// Transition from sent/cancelled → idle after the confirmation period.
    func dismissSent() {
        switch state {
        case .sent:
            state = .idle
            sentEnteredAt = nil
        case .cancelled(_):
            state = .idle
            sentEnteredAt = nil
            messagePreview = nil
        default:
            break
        }
    }

    /// Transition from processing → idle after the brief "Thinking…" window.
    /// The pill reappears on its own when TTS messageWaiting/preparing/speaking
    /// events arrive, so dropping back to .idle here only hides the indicator
    /// during the dead air between STT finalize and the LLM's first output.
    func dismissProcessing() {
        if case .processing = state {
            stateBeforeIdle = state
            lastIdleTransitionTime = now()
            state = .idle
        }
    }

    func dismissAcknowledgement() {
        if case .acknowledgement = state {
            stateBeforeIdle = state
            lastIdleTransitionTime = now()
            state = .idle
        }
    }

    /// Immediately acknowledge a valid Option gesture while speech is retained.
    func setPlaybackRequested() {
        if case .messageWaiting = state {
            state = .preparing
        }
    }

    func promotePendingAcknowledgementIfReady() {
        guard let pendingAcknowledgement,
              now() >= pendingAcknowledgement.presentAt else { return }
        switch state {
        case .idle, .processing, .acknowledgement:
            applyAcknowledgement((pendingAcknowledgement.text, pendingAcknowledgement.autoDismiss))
            self.pendingAcknowledgement = nil
        case .messageWaiting, .preparing, .speaking:
            self.pendingAcknowledgement = nil
        default:
            break
        }
    }

    /// User cancelled the current recording or TTS.
    func setCancelled() {
        let referenceState: OverlayState
        if state == .idle {
            if now().timeIntervalSince(lastIdleTransitionTime) < 0.5 {
                referenceState = stateBeforeIdle
            } else {
                return // Purely idle, do not pop a cancelled pill
            }
        } else {
            referenceState = state
        }

        // Determine source based on what state we're cancelling from
        let source: OverlayState.CancelSource
        switch referenceState {
        case .recording:
            source = .stt
        case .processing, .acknowledgement, .messageWaiting, .preparing, .speaking,
             .speechFailed:
            source = .tts
        default:
            source = .stt
        }
        state = .cancelled(source)
        partialTranscription = ""
    }

    func showSessionPrompt() {
        state = .sessionPrompt
        partialTranscription = ""
    }

    func dismissSessionPrompt() {
        if case .sessionPrompt = state {
            state = .idle
        }
    }

    func showSessionReady() {
        switch state {
        case .idle, .paused:
            state = .sessionReady
            partialTranscription = ""
            messagePreview = nil
        default:
            break
        }
    }

    func dismissSessionReady() {
        if case .sessionReady = state {
            state = .idle
        }
    }

    func showProgramStatus(title: String, body: String) {
        state = .programStatus(title: title, body: body)
        partialTranscription = ""
        messagePreview = nil
    }

    func dismissProgramStatus() {
        if case .programStatus = state {
            state = .idle
        }
    }

    // MARK: - ActionGlow

    /// Enter or refresh the .actionGlow state. Called by ActionsConfirmBus
    /// on every MCP tool firing (refreshes the decay window) and on
    /// propose_action requests (sets `prompt` non-nil).
    ///
    /// While `prompt` is non-nil, `pendingConfirmation` returns it and
    /// CapsLockGesture resolves Option/Control double-taps as yes/no.
    func setActionGlow(awaitingConfirmation prompt: ConfirmationPrompt?) {
        state = .actionGlow(awaitingConfirmation: prompt)
    }

    /// Exit the .actionGlow state. Called when the 10s decay window
    /// expires or the bus is torn down. No-op when not in ActionGlow.
    func clearActionGlow() {
        if case .actionGlow = state {
            state = .idle
        }
    }

    /// The currently pending confirmation, if any. CapsLockGesture polls this
    /// to decide whether to repurpose double-tap Option/Control.
    var pendingConfirmation: ConfirmationPrompt? {
        if case .actionGlow(let prompt) = state {
            return prompt
        }
        return nil
    }

    /// Reset to idle (services stopped).
    func reset() {
        state = .idle
        partialTranscription = ""
        messagePreview = nil
        clearWorkingProgress()
        sentEnteredAt = nil
        pendingAcknowledgement = nil
    }

    func currentWorkingProgress(now: Date = Date()) -> String? {
        guard let workingProgress, let workingProgressUpdatedAt else { return nil }
        guard now.timeIntervalSince(workingProgressUpdatedAt) <= Self.workingProgressFreshnessDuration else {
            return nil
        }
        return workingProgress
    }

    private func clearWorkingProgress() {
        workingProgress = nil
        workingProgressUpdatedAt = nil
    }

    private static func normalizedWorkingProgress(_ text: String?) -> String? {
        let words = (text ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let normalized = words.joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        guard isPublicWorkingProgress(normalized) else { return nil }
        if normalized.count <= 180 { return normalized }
        let clipped = String(normalized.prefix(177))
        return clipped.trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func isPublicWorkingProgress(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("transcript")
            || lower.contains("source_text")
            || lower.contains("tool log")
            || lower.contains("reasoning")
            || lower.contains("scratchpad")
            || lower.contains("secret")
            || lower.contains("password")
            || lower.contains("token")
            || lower.contains("api key") {
            return false
        }
        if lower.contains("waiting for voice input")
            || lower.contains("waiting for voice command")
            || lower.contains("waiting for next relay command")
            || lower.contains("relay mode waiting")
            || lower.contains("heartbeat")
            || lower.contains("monitoring bridge") {
            return false
        }
        return !looksLikeRawCommand(text)
    }

    private static func looksLikeRawCommand(_ text: String) -> Bool {
        let lower = text.lowercased()
        if text.contains(";")
            || text.contains("&&")
            || text.contains("||")
            || text.contains("|")
            || text.contains("$(")
            || text.contains("`") {
            return true
        }
        let commandPrefixes = [
            "bash ", "cat ", "curl ", "git ", "grep ", "npm ", "pnpm ",
            "python ", "python3 ", "sh ", "swift ", "xcodebuild ", "yarn ", "zsh "
        ]
        return commandPrefixes.contains { lower.hasPrefix($0) }
    }

    private func acknowledgementState(
        text: String?,
        autoDismiss: TimeInterval?
    ) -> (text: String, autoDismiss: TimeInterval) {
        let acknowledgement = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            acknowledgement.flatMap { $0.isEmpty ? nil : $0 } ?? "Got it. I'm on it.",
            autoDismiss ?? 3.0
        )
    }

    private func applyAcknowledgement(_ acknowledgement: (text: String, autoDismiss: TimeInterval)) {
        pendingAcknowledgement = nil
        state = .acknowledgement(
            text: acknowledgement.text,
            autoDismiss: acknowledgement.autoDismiss
        )
        partialTranscription = ""
        messagePreview = nil
    }

    private func normalizedMessagePreview(_ text: String?) -> String? {
        let preview = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.flatMap { $0.isEmpty ? nil : $0 }
    }
}
