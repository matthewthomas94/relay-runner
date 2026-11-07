import SwiftUI

/// The wheel's centre button: a cross that closes the wheel.
struct SessionWheelCloseGlyph: View {
    var body: some View {
        Canvas { context, _ in
            var path = Path()
            for corner in NotchContentMotion.coreCenters {
                path.move(to: CGPoint(x: 12, y: 12))
                path.addLine(to: CGPoint(x: 12 + (corner.x - 12) * 1.6, y: 12 + (corner.y - 12) * 1.6))
            }
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
