import SwiftUI

/// The desktop's attention shimmer (`FluxDotsBackground`, Mac
/// `Overlay/FluxDots.swift`): neutral-5 dots, 3 pt on a 5 pt grid, centred
/// in the view, whose opacity runs the skeleton loader's column snake. In
/// each column a bright head steps along a fifth of a 1.2 s cycle at a time,
/// alternate columns running opposite ways. Reduce Motion holds each dot at
/// its resting level. Clip it to the shape it fills; it takes no touches.
struct FluxDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let pitch: CGFloat = 5
    static let diameter: CGFloat = 3
    /// The Mac's `DotColumnSnakeAnimation.cycle`: 1.5 s at speed 1.25.
    static let cycle: TimeInterval = 1.5 / 1.25
    static let phases = 5
    /// The levels a dot steps through, from the snake's head back along its
    /// tail (the Mac's `DotColumnSnakeAnimation.levels`).
    static let levels: [Double] = {
        let base = 0.12, mid = 0.42, peak = 1.0
        return [0.6 * peak + 0.25 * mid + 0.15 * base,
                0.3 * peak + 0.5 * mid + 0.2 * base,
                0.6 * mid + 0.4 * base,
                0.2 * mid + 0.8 * base,
                0.625 * base]
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let columns = max(1, Int((size.width - Self.diameter) / Self.pitch) + 1)
                let rows = max(1, Int((size.height - Self.diameter) / Self.pitch) + 1)
                let left = size.width / 2 - CGFloat(columns - 1) * Self.pitch / 2
                let top = size.height / 2 - CGFloat(rows - 1) * Self.pitch / 2
                for row in 0..<rows {
                    for column in 0..<columns {
                        let opacity = Self.opacity(phase: Self.phase(column: column, row: row),
                                                   time: reduceMotion ? 0 : time)
                        let dot = CGRect(x: left + CGFloat(column) * Self.pitch - Self.diameter / 2,
                                         y: top + CGFloat(row) * Self.pitch - Self.diameter / 2,
                                         width: Self.diameter, height: Self.diameter)
                        context.fill(Path(ellipseIn: dot), with: .color(RelayColor.neutral5.opacity(opacity)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The dot's place along its column's snake: even columns run up, odd down.
    static func phase(column: Int, row: Int) -> Int {
        let raw = column % 2 == 0 ? -row - 1 : row
        return (raw % phases + phases) % phases
    }

    /// A dot glides from one level to the next each fifth of a cycle, starting
    /// a fifth of a cycle later per phase, so the loop is seamless.
    static func opacity(phase: Int, time: TimeInterval) -> Double {
        let raw = (time / cycle - Double(phase) / Double(phases)).truncatingRemainder(dividingBy: 1)
        let progress = raw < 0 ? raw + 1 : raw
        let position = progress * Double(phases)
        let step = Int(position) % phases
        let blend = position - Double(Int(position))
        return levels[step] + (levels[(step + 1) % phases] - levels[step]) * blend
    }
}
