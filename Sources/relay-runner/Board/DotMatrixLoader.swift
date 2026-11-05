import SwiftUI

/// A 5×5 dot-matrix "rings" loader: the ring cells (radius 1 and 2 from the
/// centre) pulse outward in a ripple-echo. Ported from the `DotmSquare11`
/// web component (pattern "rings", speed 1.25, opacity 0.12 / 0.42 / 1) so the
/// running-session indicator matches the design reference.
struct DotMatrixLoader: View {
    var size: CGFloat = 14
    var color: Color = ProgramBoardStyle.green
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animated && !reduceMotion {
            // 30 fps is plenty for a 1.2 s loop at this size and keeps idle CPU low.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                canvas(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvas(time: nil)
        }
    }

    private func canvas(time: TimeInterval?) -> some View {
        Canvas { context, canvasSize in
            let layout = DotMatrixLoaderModel.layout(span: min(canvasSize.width, canvasSize.height))
            for cell in DotMatrixLoaderModel.ringCells {
                let opacity = time.map { DotMatrixLoaderModel.opacity(cell: cell, time: $0) }
                    ?? DotMatrixLoaderModel.restingOpacity(cell: cell)
                let rect = CGRect(
                    x: CGFloat(cell.col) * (layout.dot + layout.gap),
                    y: CGFloat(cell.row) * (layout.dot + layout.gap),
                    width: layout.dot,
                    height: layout.dot
                )
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum DotMatrixLoaderModel {
    struct Cell: Equatable {
        let row: Int
        let col: Int
        /// Manhattan distance from the centre, clamped to 0…4.
        var ring: Int { min(4, abs(row - 2) + abs(col - 2)) }
    }

    static let matrixSize = 5
    /// One base loop is 1500 ms; speed 1.25 makes it 1200 ms.
    static let cycle: TimeInterval = 1.5 / 1.25
    static let opacityBase = 0.12
    static let opacityMid = 0.42
    static let opacityPeak = 1.0

    /// Cells whose rounded distance from the centre is 1 or 2 (no centre, no corners).
    static let ringCells: [Cell] = (0..<matrixSize).flatMap { row in
        (0..<matrixSize).compactMap { col -> Cell? in
            let radius = (Double(row - 2) * Double(row - 2) + Double(col - 2) * Double(col - 2)).squareRoot()
            let rounded = radius.rounded()
            return rounded == 1 || rounded == 2 ? Cell(row: row, col: col) : nil
        }
    }

    /// Dot size and gap keep the reference's 16:7 ratio (108 px box, 16 px dots).
    static func layout(span: CGFloat) -> (dot: CGFloat, gap: CGFloat) {
        let n = CGFloat(matrixSize)
        let dot = span / (n + (n - 1) * 7.0 / 16.0)
        return (dot, dot * 7.0 / 16.0)
    }

    /// The `dmx-ripple-echo` keyframes: low, peak at 28%, mid at 56%, echo at 78%.
    static let keyframes: [(at: Double, opacity: Double)] = [
        (0.0, 0.625 * opacityBase),
        (0.28, 0.98 * opacityPeak),
        (0.56, opacityMid),
        (0.78, 0.68 * opacityPeak + 0.32 * opacityMid),
        (1.0, 0.625 * opacityBase),
    ]

    static func opacity(cell: Cell, time: TimeInterval) -> Double {
        let delay = Double(cell.ring) * 0.14 + Double(cell.ring % 2) * 0.03
        var phase = (time / cycle - delay).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        return opacity(atPhase: phase)
    }

    static func opacity(atPhase phase: Double) -> Double {
        for index in 1..<keyframes.count where phase <= keyframes[index].at {
            let from = keyframes[index - 1], to = keyframes[index]
            let t = (phase - from.at) / (to.at - from.at)
            // CSS ease-in-out per keyframe segment, approximated with smoothstep.
            let eased = t * t * (3 - 2 * t)
            return from.opacity + (to.opacity - from.opacity) * eased
        }
        return keyframes[keyframes.count - 1].opacity
    }

    /// Reduced motion: the reference's static falloff from the centre.
    static func restingOpacity(cell: Cell) -> Double {
        0.2 + (1 - Double(cell.ring) / 4) * 0.72
    }
}
