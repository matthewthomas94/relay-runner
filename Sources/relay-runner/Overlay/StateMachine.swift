import Foundation

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
    case messageWaiting(preview: String?)
    case preparing
    case speaking
    case paused
    case sessionPrompt   // No session running — prompt user to start one

    /// Which particle field theme to show (nil = hidden).
    var particleTheme: ParticleFieldRenderer.Theme? {
        switch self {
        case .idle, .paused, .sent, .cancelled(_), .sessionPrompt:
            return nil
        case .listening, .recording:
            return .stt
        case .processing, .messageWaiting, .preparing, .speaking:
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
        case .processing, .messageWaiting, .preparing, .speaking:
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

    private(set) var state: OverlayState = .idle
    private(set) var partialTranscription: String = ""
    private(set) var messagePreview: String?

    private var stateBeforeIdle: OverlayState = .idle
    private var lastIdleTransitionTime: Date = .distantPast

    /// Called by AppState when STT engine state changes.
    func updateSTT(isRecording: Bool, partial: String) {
        partialTranscription = partial

        if isRecording {
            state = .recording
        } else if case .recording = state {
            // Stopped recording — show brief "Sent" confirmation.
            state = .sent
            partialTranscription = ""
        }
    }

    /// Called by StateEventBus when Python services send state updates.
    func handleServiceEvent(source: String, newState: String, text: String?) {
        switch (source, newState) {
        case ("tts", "message_waiting"):
            messagePreview = text
            state = .messageWaiting(preview: text)

        case ("tts", "preparing"):
            state = .preparing

        case ("tts", "speaking"):
            state = .speaking

        case ("tts", "idle"):
            switch state {
            case .speaking, .preparing, .messageWaiting:
                stateBeforeIdle = state
                lastIdleTransitionTime = Date()
                state = .idle
                messagePreview = nil
            default:
                break
            }

        case ("bridge", "processing"):
            switch state {
            case .recording, .sent, .cancelled(_):
                break  // don't override these transient states
            default:
                state = .processing
            }

        case ("bridge", "idle"):
            if case .processing = state {
                stateBeforeIdle = state
                lastIdleTransitionTime = Date()
                state = .idle
            }

        default:
            break
        }
    }

    /// Transition from sent/cancelled → idle after the confirmation period.
    func dismissSent() {
        switch state {
        case .sent, .cancelled(_):
            state = .idle
        default:
            break
        }
    }

    /// User cancelled the current recording or TTS.
    func setCancelled() {
        let referenceState: OverlayState
        if state == .idle {
            if Date().timeIntervalSince(lastIdleTransitionTime) < 0.5 {
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
        case .processing, .messageWaiting, .preparing, .speaking:
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

    /// Reset to idle (services stopped).
    func reset() {
        state = .idle
        partialTranscription = ""
        messagePreview = nil
    }
}
