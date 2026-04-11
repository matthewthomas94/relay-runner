import Foundation

/// Possible overlay states, driven by STT engine (in-process) and Python services (via socket).
enum OverlayState: Equatable {
    case idle
    case listening
    case recording
    case processing
    case messageWaiting(preview: String?)
    case preparing
    case speaking
    case paused

    /// Color hue for the glow (0-1 range, maps to HSB).
    var glowHue: Double {
        switch self {
        case .idle:                return 0
        case .listening:           return 0.58   // warm blue
        case .recording:           return 0.58   // same blue, brighter
        case .processing:          return 0.58   // blue, fading
        case .messageWaiting:      return 0.30   // amber/green
        case .preparing:           return 0.30   // amber, same as messageWaiting
        case .speaking:            return 0.42   // teal
        case .paused:              return 0       // gray (saturation 0)
        }
    }

    var glowSaturation: Double {
        switch self {
        case .idle:     return 0
        case .paused:   return 0
        default:        return 0.8
        }
    }

    var glowOpacity: Double {
        switch self {
        case .idle:            return 0
        case .listening:       return 0.4
        case .recording:       return 0.7
        case .processing:      return 0.2
        case .messageWaiting:  return 0.5
        case .preparing:       return 0.4
        case .speaking:        return 0.5
        case .paused:          return 0.15
        }
    }

    var shouldBreath: Bool {
        switch self {
        case .listening, .recording: return true
        case .messageWaiting:        return true
        case .preparing:             return true
        default:                     return false
        }
    }

    /// Text to show in the pill for this state (nil = hide pill).
    var pillText: String? {
        switch self {
        case .preparing: return "Preparing response..."
        default:         return nil
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

    /// Called by AppState when STT engine state changes.
    func updateSTT(isRecording: Bool, partial: String) {
        partialTranscription = partial

        if isRecording {
            state = .recording
        } else if case .recording = state {
            // Stopped recording — transition to processing (bridge will pick it up)
            state = .processing
        }
    }

    /// Called when STT engine is listening but not recording.
    func setListening() {
        switch state {
        case .recording, .processing, .messageWaiting, .preparing, .speaking:
            return
        default:
            state = .listening
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
                state = .listening
                messagePreview = nil
            default:
                break
            }

        case ("bridge", "processing"):
            if case .recording = state { break }  // don't override active recording
            state = .processing

        case ("bridge", "idle"):
            if case .processing = state {
                state = .listening
            }

        default:
            break
        }
    }

    /// Reset to idle (services stopped).
    func reset() {
        state = .idle
        partialTranscription = ""
        messagePreview = nil
    }
}
