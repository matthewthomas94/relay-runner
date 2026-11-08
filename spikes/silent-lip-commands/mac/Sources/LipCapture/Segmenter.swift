import Foundation

/// Cuts the continuous geometry stream into word-sized segments on articulation
/// energy (subvox CaptureController; mirrors segmenter.py).
final class Segmenter {
    static let calibrationSeconds = 2.0
    static let prerollSeconds = 0.3
    static let hangoverSeconds = 0.35
    static let maxAutoSeconds = 3.0

    var triggerRatio = 3.0
    var autoEnabled = false
    private(set) var energy = 0.0
    private(set) var noiseFloor: Double?
    private(set) var isCalibrating = false
    private(set) var isCapturing = false
    var onSegment: (([[Double]]) -> Void)?

    private var buffer: [(t: Double, g: [Double])] = []
    private var preroll: [(t: Double, g: [Double])] = []
    private var calibration: [Double] = []
    private var calibrationEnd: Double?
    private var quietSince: Double?
    private var last: [Double]?

    var threshold: Double? { noiseFloor.map { $0 * triggerRatio } }

    func calibrate() { calibration = []; calibrationEnd = nil; isCalibrating = true }

    func ingest(t: Double, g: [Double]) {
        let e = last.map { zip(g, $0).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot() } ?? 0
        last = g
        energy = energy * 0.6 + e * 0.4

        if isCalibrating {
            let end = calibrationEnd ?? t + Self.calibrationSeconds
            calibrationEnd = end
            calibration.append(energy)
            if t >= end {
                let s = calibration.sorted()
                noiseFloor = max(s[s.count / 2], 1e-5)
                isCalibrating = false
            }
        }

        preroll.append((t, g))
        while let f = preroll.first, f.t < t - Self.prerollSeconds { preroll.removeFirst() }

        if isCapturing {
            buffer.append((t, g))
            let duration = t - (buffer.first?.t ?? t)
            if let thr = threshold {
                if energy < thr * 0.7 {
                    let since = quietSince ?? t
                    quietSince = since
                    if t - since > Self.hangoverSeconds { finish() }
                } else {
                    quietSince = nil
                }
                if isCapturing, duration > Self.maxAutoSeconds { finish() }
            }
        } else if autoEnabled, !isCalibrating, let thr = threshold, energy > thr {
            isCapturing = true
            quietSince = nil
            buffer = preroll
        }
    }

    private func finish() {
        let seg = buffer
        buffer = []
        isCapturing = false
        quietSince = nil
        guard seg.count >= 4, let f = seg.first, let l = seg.last, l.t - f.t >= 0.15 else { return }
        onSegment?(seg.map(\.g))
    }
}
