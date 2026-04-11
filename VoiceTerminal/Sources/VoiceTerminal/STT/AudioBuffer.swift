import Foundation

/// Thread-safe audio sample buffer. Direct port from stt-sidecar/Sources/VoiceListen/main.swift:73-103.
final class AudioBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    /// Maximum buffer size (30s at 16kHz). Prevents unbounded growth when
    /// the audio tap runs between recording sessions.
    private let maxSamples = 16000 * 30

    /// When false, `append` is a no-op. Set by STTEngine to avoid
    /// accumulating audio while idle in caps-lock-toggle mode.
    var accepting = true

    func append(_ newSamples: [Float]) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        samples.append(contentsOf: newSamples)
        if samples.count > maxSamples {
            samples = Array(samples.suffix(maxSamples))
        }
        lock.unlock()
    }

    func get() -> [Float] {
        lock.lock()
        let copy = samples
        lock.unlock()
        return copy
    }

    func clear() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    func clearExceptKeep(_ keepCount: Int) {
        lock.lock()
        if samples.count > keepCount {
            samples = Array(samples.suffix(keepCount))
        }
        lock.unlock()
    }
}
