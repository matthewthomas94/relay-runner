import Foundation

/// Thread-safe audio sample buffer. Direct port from stt-sidecar/Sources/VoiceListen/main.swift:73-103.
final class AudioBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ newSamples: [Float]) {
        lock.lock()
        samples.append(contentsOf: newSamples)
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
