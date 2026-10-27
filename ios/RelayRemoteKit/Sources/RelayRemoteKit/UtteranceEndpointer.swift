import Foundation

/// Hands-free end-of-utterance detection from microphone levels.
///
/// Pure and clock-free: the app feeds one `(level, time)` sample per audio
/// buffer, with `level` in dBFS. Speech starts when the level rises
/// `startMargin` dB above the tracked noise floor, and ends after
/// `trailingSilence` seconds without a sample `endMargin` dB above the floor.
/// An utterance shorter than `minSpeech` is reported as `discarded` (a click or
/// cough), and `maxUtterance` forces an end so a noisy room cannot record
/// forever. The noise floor adapts slowly while nobody is speaking.
public struct UtteranceEndpointer: Sendable {
    public struct Tuning: Sendable {
        public var startMargin: Float = 12
        public var endMargin: Float = 6
        public var minSpeech: TimeInterval = 0.25
        public var trailingSilence: TimeInterval = 0.9
        public var maxUtterance: TimeInterval = 20
        public var initialFloor: Float = -50
        public var floorAdaptation: Float = 0.05
        public var floorCeiling: Float = -25
        public init() {}
    }

    public enum Event: Equatable, Sendable {
        case none
        case started
        case ended
        case discarded
    }

    public let tuning: Tuning
    public private(set) var noiseFloor: Float
    public private(set) var isInSpeech = false
    private var speechStart: TimeInterval = 0
    private var lastLoud: TimeInterval = 0

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
        self.noiseFloor = tuning.initialFloor
    }

    public mutating func observe(level: Float, at time: TimeInterval) -> Event {
        if isInSpeech {
            if level > noiseFloor + tuning.endMargin {
                lastLoud = time
            }
            let tooLong = time - speechStart >= tuning.maxUtterance
            let silent = time - lastLoud >= tuning.trailingSilence
            guard tooLong || silent else { return .none }
            isInSpeech = false
            return lastLoud - speechStart >= tuning.minSpeech ? .ended : .discarded
        }
        if level > noiseFloor + tuning.startMargin {
            isInSpeech = true
            speechStart = time
            lastLoud = time
            return .started
        }
        noiseFloor = min(tuning.floorCeiling, noiseFloor + tuning.floorAdaptation * (level - noiseFloor))
        return .none
    }

    /// Forget any utterance in progress, keeping the learned noise floor.
    public mutating func reset() {
        isInSpeech = false
    }
}
