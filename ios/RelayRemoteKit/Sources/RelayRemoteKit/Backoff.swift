/// Reconnect delays: exponential growth with equal jitter, so attempt `n`
/// waits a uniform random time in `[ceiling / 2, ceiling]` where
/// `ceiling = min(cap, base * 2^n)`. The floor keeps a flapping Mac from
/// being hammered; the jitter keeps retries from synchronising.
public struct Backoff: Sendable {
    public var base: Double
    public var cap: Double
    public private(set) var attempt = 0

    public init(base: Double = 0.5, cap: Double = 30) {
        self.base = base
        self.cap = cap
    }

    public mutating func nextDelay(random: (ClosedRange<Double>) -> Double) -> Double {
        let ceiling = min(cap, base * Double(1 << min(attempt, 20)))
        attempt += 1
        return random(ceiling / 2...ceiling)
    }

    public mutating func reset() {
        attempt = 0
    }
}
