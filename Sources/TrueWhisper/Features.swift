import Foundation

/// Segment-level features. Mirrors the spike's python/lipspike/features.py exactly.
public enum Features {
    public static let channels = 6

    public static func velocity(_ f: [[Double]]) -> [[Double]] {
        guard let first = f.first else { return [] }
        var out: [[Double]] = [Array(repeating: 0, count: first.count)]
        for i in 1..<f.count { out.append(zip(f[i], f[i - 1]).map { $0 - $1 }) }
        return out
    }

    public static func energy(_ f: [[Double]]) -> [Double] {
        velocity(f).map { $0.reduce(0) { $0 + $1 * $1 }.squareRoot() }
    }

    public static func trim(_ frames: [[Double]], padding: Int = 2, minLen: Int = 5) -> [[Double]] {
        let n = frames.count
        guard n > 6 else { return frames }
        let e = energy(frames)
        let s = e.sorted()
        let floor = s[n / 5], peak = s[n - 1]
        guard peak > floor * 1.5 else { return frames }
        let thr = floor + 0.15 * (peak - floor)
        guard let first = e.firstIndex(where: { $0 > thr }), let last = e.lastIndex(where: { $0 > thr }) else { return frames }
        let lo = max(0, first - padding), hi = min(n - 1, last + padding)
        guard hi - lo + 1 >= minLen else { return frames }
        return Array(frames[lo...hi])
    }

    public static func segmentFeatures(_ frames: [[Double]], useVelocity: Bool = true) -> [[Double]] {
        let f = trim(frames)
        guard let dims = f.first?.count, dims == channels else { return [] }
        var mean = Array(repeating: 0.0, count: dims)
        for row in f { for d in 0..<dims { mean[d] += row[d] } }
        for d in 0..<dims { mean[d] /= Double(f.count) }
        let centred = f.map { row in (0..<dims).map { row[$0] - mean[$0] } }
        guard useVelocity else { return centred }
        let v = velocity(f)
        return zip(centred, v).map { $0 + $1 }
    }

    public static func channelScales(_ sequences: [[[Double]]]) -> [Double] {
        guard let dims = sequences.first?.first?.count else { return [] }
        var sum = Array(repeating: 0.0, count: dims), sumSq = sum, n = 0.0
        for s in sequences { for row in s { for d in 0..<dims { sum[d] += row[d]; sumSq[d] += row[d] * row[d] }; n += 1 } }
        guard n > 1 else { return Array(repeating: 1, count: dims) }
        return (0..<dims).map { d in
            let m = sum[d] / n
            return max((sumSq[d] / n - m * m).squareRoot(), 1e-6)
        }
    }

    public static func scaled(_ frames: [[Double]], by scales: [Double]) -> [[Double]] {
        frames.map { row in zip(row, scales).map { $0 / $1 } }
    }
}

/// Dynamic time warping with a Sakoe-Chiba band (as in subvox; mirrors dtw.py).
public enum DTW {
    public static func distance(_ a: [[Double]], _ b: [[Double]], bandFraction: Double = 0.25) -> Double {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return .infinity }
        let band = max(abs(n - m), Int(Double(max(n, m)) * bandFraction))
        var prev = [Double](repeating: .infinity, count: m + 1)
        var cur = prev
        prev[0] = 0
        for i in 1...n {
            for j in cur.indices { cur[j] = .infinity }
            let lo = max(1, i - band), hi = min(m, i + band)
            if lo <= hi {
                for j in lo...hi {
                    var c = 0.0
                    for k in 0..<min(a[i - 1].count, b[j - 1].count) { let d = a[i - 1][k] - b[j - 1][k]; c += d * d }
                    cur[j] = c.squareRoot() + min(prev[j], cur[j - 1], prev[j - 1])
                }
            }
            swap(&prev, &cur)
        }
        return prev[m] / Double(n + m)
    }
}
