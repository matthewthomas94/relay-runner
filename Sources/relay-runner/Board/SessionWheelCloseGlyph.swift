import SwiftUI

/// The wheel's centre button: a cross that closes the wheel, or an arrow that steps back from a nested wheel.
struct SessionWheelCloseGlyph: View {
    var isBack = false

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            if isBack {
                path.move(to: CGPoint(x: 12, y: 7))
                path.addLine(to: CGPoint(x: 7, y: 12))
                path.addLine(to: CGPoint(x: 12, y: 17))
                path.move(to: CGPoint(x: 7, y: 12))
                path.addLine(to: CGPoint(x: 17, y: 12))
            } else {
                for corner in NotchContentMotion.coreCenters {
                    path.move(to: CGPoint(x: 12, y: 12))
                    path.addLine(to: CGPoint(x: 12 + (corner.x - 12) * 1.6, y: 12 + (corner.y - 12) * 1.6))
                }
            }
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
