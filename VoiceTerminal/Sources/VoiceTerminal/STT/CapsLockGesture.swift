import CoreGraphics
import Foundation

/// Caps Lock gesture detection state machine.
/// Extracted from stt-sidecar/Sources/VoiceListen/main.swift:176-286.
///
/// Gesture vocabulary:
///   - Single press + hold: enter recording mode (LED on)
///   - Press again: stop recording, send text (LED off)
///   - Double-tap: play queued TTS / replay last
final class CapsLockGesture {

    enum Event {
        case startRecording
        case stopRecording(text: String)
        case interrupt
        case play
    }

    /// Threshold before a held caps lock counts as "recording" (not a tap)
    private let recordThresholdSec: Double = 0.3
    /// Maximum gap between taps in a multi-tap gesture
    private let tapWindowSec: Double = 0.6
    /// Wait after last transition before firing gesture
    private let settleMs: Double = 0.7

    private var prevCapsOn: Bool
    private var recording = false
    private var transitions: [Date] = []

    init() {
        self.prevCapsOn = Self.isCapsLockOn()
    }

    static func isCapsLockOn() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.contains(.maskAlphaShift)
    }

    /// Poll the caps lock state and return any gesture event detected.
    /// Call this at ~50ms intervals.
    func poll(currentSegment: String) -> Event? {
        let capsOn = Self.isCapsLockOn()
        let now = Date()

        // Detect state transition
        if capsOn != prevCapsOn {
            let isRapid = transitions.last.map { now.timeIntervalSince($0) < tapWindowSec } ?? true
            if isRapid && !recording {
                transitions.append(now)
            } else if !recording {
                transitions = [now]
            }

            // Caps Lock just turned ON — clear audio for fresh recording
            if capsOn {
                prevCapsOn = capsOn
                return .startRecording
            }

            // Caps Lock just turned OFF while recording — send text
            if !capsOn && recording {
                recording = false
                transitions.removeAll()
                prevCapsOn = capsOn
                if !currentSegment.isEmpty {
                    return .stopRecording(text: currentSegment)
                } else {
                    return .interrupt
                }
            }

            prevCapsOn = capsOn
            return nil
        }

        // Check if a rapid tap sequence has settled
        if !transitions.isEmpty && !recording {
            if let last = transitions.last, now.timeIntervalSince(last) > settleMs {
                let count = transitions.count

                if count >= 2 {
                    transitions.removeAll()
                    return .play
                }
            }
        }

        // If caps is off, nothing to do
        if !capsOn { return nil }

        // Enter recording mode once held past tap threshold
        if !recording {
            if let first = transitions.first, now.timeIntervalSince(first) >= recordThresholdSec {
                recording = true
                transitions.removeAll()
                // No event here — recording state is tracked internally,
                // STTEngine checks isRecording
            }
        }

        return nil
    }

    var isRecording: Bool { recording }

    func reset() {
        recording = false
        transitions.removeAll()
        prevCapsOn = Self.isCapsLockOn()
    }
}
