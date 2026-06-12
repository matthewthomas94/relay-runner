import Foundation

/// Thread-safe audio sample buffer. Direct port from stt-sidecar/Sources/VoiceListen/main.swift:73-103.
final class AudioBuffer: @unchecked Sendable {
    static let defaultMaxSamples = 16000 * 30

    private var samples: [Float] = []
    private let lock = NSLock()

    /// Maximum buffer size (30s at 16kHz). Prevents unbounded growth when
    /// the audio tap runs between recording sessions.
    private var maxSamples: Int? = AudioBuffer.defaultMaxSamples

    /// When false, `append` is a no-op. Set by STTEngine to avoid
    /// accumulating audio while idle in caps-lock-toggle mode.
    var accepting = true

    func append(_ newSamples: [Float]) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        samples.append(contentsOf: newSamples)
        if let maxSamples, samples.count > maxSamples {
            samples = Array(samples.suffix(maxSamples))
        }
        lock.unlock()
    }

    func setMaxSamples(_ newMaxSamples: Int?) {
        lock.lock()
        maxSamples = newMaxSamples
        if let maxSamples, samples.count > maxSamples {
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

    func discardPrefix(upTo sampleCount: Int, keeping keepCount: Int) {
        lock.lock()
        let coveredSamples = min(max(sampleCount, 0), samples.count)
        let dropCount = max(coveredSamples - max(keepCount, 0), 0)
        if dropCount > 0 {
            samples.removeFirst(dropCount)
        }
        lock.unlock()
    }
}
