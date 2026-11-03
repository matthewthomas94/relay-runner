import Foundation

/// One recorded take: its label and per-frame lip geometry. Never images.
public struct Template: Codable, Equatable {
    public var label: String
    public var frames: [[Double]]

    public init(label: String, frames: [[Double]]) {
        self.label = label
        self.frames = frames
    }
}

public struct Prediction {
    public var ranked: [(label: String, distance: Double)]
    public var confidence: Double
    public var accepted: Bool
    public var best: String? { ranked.first?.label }
}

/// Nearest-neighbour DTW over user-recorded templates (mirrors the spike's classifier.py).
public struct TemplateClassifier {
    public let useVelocity: Bool
    public let band: Double
    private let entries: [(label: String, frames: [[Double]])]
    private let scales: [Double]

    public var labels: [String] { Array(Set(entries.map(\.label))).sorted() }

    public init?(templates: [Template], useVelocity: Bool = true, band: Double = 0.25) {
        guard Set(templates.map(\.label)).count >= 2 else { return nil }
        let raw = templates.map { Features.segmentFeatures($0.frames, useVelocity: useVelocity) }
        let scales = Features.channelScales(raw)
        self.useVelocity = useVelocity
        self.band = band
        self.scales = scales
        self.entries = zip(templates, raw).map { ($0.label, Features.scaled($1, by: scales)) }
    }

    public func rank(_ frames: [[Double]]) -> [(label: String, distance: Double)] {
        let q = Features.scaled(Features.segmentFeatures(frames, useVelocity: useVelocity), by: scales)
        var best: [String: Double] = [:]
        for e in entries {
            let d = DTW.distance(q, e.frames, bandFraction: band)
            best[e.label] = min(best[e.label] ?? .infinity, d)
        }
        return best.map { ($0.key, $0.value) }.sorted { $0.1 < $1.1 }
    }

    public static func margin(_ sorted: [Double]) -> Double {
        guard sorted.count >= 2, sorted[1] > 0 else { return 0 }
        return max(0, 1 - sorted[0] / sorted[1])
    }

    public func predict(_ frames: [[Double]], maxDistance: Double, minConfidence: Double) -> Prediction {
        let ranked = rank(frames)
        let conf = Self.margin(ranked.map(\.distance))
        let accepted = (ranked.first?.distance ?? .infinity) <= maxDistance && conf >= minConfidence
        return Prediction(ranked: ranked, confidence: conf, accepted: accepted)
    }
}

/// Leave-one-out accuracy plus a label-permutation test (mirrors Evaluation in classifier.py).
public struct Evaluation {
    public var labels: [String]
    public var confusion: [[Int]]
    public var accuracy: Double
    public var chance: Double
    public var permutationMean: Double
    public var permutationP95: Double
    public var pValue: Double
    public var permutations: Int
    public var templateCount: Int

    public static func run(templates: [Template], useVelocity: Bool = true, band: Double = 0.25, permutations: Int = 500) -> Evaluation? {
        let labels = Array(Set(templates.map(\.label))).sorted()
        let counts = Dictionary(grouping: templates, by: \.label).mapValues(\.count)
        guard labels.count >= 2, counts.values.allSatisfy({ $0 >= 2 }) else { return nil }
        let raw = templates.map { Features.segmentFeatures($0.frames, useVelocity: useVelocity) }
        let scales = Features.channelScales(raw)
        let seqs = raw.map { Features.scaled($0, by: scales) }
        let n = seqs.count

        var distance = [[Double]](repeating: [Double](repeating: .infinity, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                let d = DTW.distance(seqs[i], seqs[j], bandFraction: band)
                distance[i][j] = d
                distance[j][i] = d
            }
        }
        let index = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        let truth = templates.map { index[$0.label]! }
        let L = labels.count

        func leaveOneOut(_ assign: [Int]) -> [Int] {
            (0..<n).map { i in
                var best = [Double](repeating: .infinity, count: L)
                for j in 0..<n where j != i { best[assign[j]] = min(best[assign[j]], distance[i][j]) }
                return best.indices.min { best[$0] < best[$1] }!
            }
        }
        func accuracy(_ p: [Int], _ a: [Int]) -> Double { Double(zip(p, a).filter { $0 == $1 }.count) / Double(n) }

        let predicted = leaveOneOut(truth)
        var confusion = [[Int]](repeating: [Int](repeating: 0, count: L), count: L)
        for (p, a) in zip(predicted, truth) { confusion[a][p] += 1 }
        let observed = accuracy(predicted, truth)

        var g = SystemRandomNumberGenerator()
        var null: [Double] = []
        for _ in 0..<permutations {
            let shuffled = truth.shuffled(using: &g)
            null.append(accuracy(leaveOneOut(shuffled), shuffled))
        }
        null.sort()
        let atLeast = null.filter { $0 >= observed }.count
        return Evaluation(
            labels: labels, confusion: confusion, accuracy: observed,
            chance: Double(counts.values.max()!) / Double(n),
            permutationMean: null.reduce(0, +) / Double(max(permutations, 1)),
            permutationP95: null.isEmpty ? 0 : null[Int(Double(null.count - 1) * 0.95)],
            pValue: Double(atLeast + 1) / Double(permutations + 1),
            permutations: permutations, templateCount: n)
    }

    public var report: String {
        var lines = [
            "templates=\(templateCount) labels=\(labels.count)",
            String(format: "leave-one-out accuracy=%.3f chance=%.3f", accuracy, chance),
            String(format: "permutation null mean=%.3f p95=%.3f p=%.4f", permutationMean, permutationP95, pValue),
            "confusion rows=actual cols=predicted, labels: \(labels)",
        ]
        for (k, row) in confusion.enumerated() { lines.append("  \(labels[k].padding(toLength: 10, withPad: " ", startingAt: 0)) \(row)") }
        lines.append(pValue < 0.05
            ? "RESULT: lip geometry separates these words better than chance (p < 0.05)."
            : "RESULT: not distinguishable from chance. Record more takes, or articulate more.")
        return lines.joined(separator: "\n")
    }
}
