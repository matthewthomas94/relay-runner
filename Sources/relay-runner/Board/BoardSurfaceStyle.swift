import AppKit
import SwiftUI

enum BoardSurfaceLayout {
    static let horizontalPadding: CGFloat = 8
    static let columnSpacing: CGFloat = 12
    static let navigationTopPadding: CGFloat = 7
    static let navigationHeight: CGFloat = 24
    static let navigationToPanelSpacing: CGFloat = 16
    static let columnTopPadding: CGFloat = navigationTopPadding + navigationHeight + navigationToPanelSpacing
    static let columnHeight: CGFloat = 667
}

enum BoardDarkSurfaceStyle {
    static let panelFillNSColor = NSColor(srgbRed: 9 / 255, green: 11 / 255, blue: 15 / 255, alpha: 1)
    static let contentFillNSColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let borderNSColor = NSColor(srgbRed: 17 / 255, green: 22 / 255, blue: 29 / 255, alpha: 1)

    static let panelFill = Color(nsColor: panelFillNSColor)
    static let contentFill = Color(nsColor: contentFillNSColor)
    static let border = Color(nsColor: borderNSColor)

    static let workspaceCornerRadius: CGFloat = 24
    static let columnCornerRadius: CGFloat = 16
    static let nestedCardCornerRadius: CGFloat = 14
    static let floatingPanelCornerRadius: CGFloat = 16
    static let shadowOpacity: Double = 0.08
    static let shadowRadius: CGFloat = 4
    static let shadowYOffset: CGFloat = 2
}

struct BoardDarkSurfaceBackground: View {
    let cornerRadius: CGFloat
    var fill: Color = BoardDarkSurfaceStyle.panelFill

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(BoardDarkSurfaceStyle.border, lineWidth: 1)
            )
    }
}

struct BoardDarkCapsuleBackground: View {
    var fill: Color = BoardDarkSurfaceStyle.contentFill
    var stroke: Color = BoardDarkSurfaceStyle.border

    var body: some View {
        Capsule()
            .fill(fill)
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
    }
}

struct BoardDarkCircleBackground: View {
    var fill: Color = BoardDarkSurfaceStyle.contentFill
    var stroke: Color = BoardDarkSurfaceStyle.border

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().stroke(stroke, lineWidth: 1))
    }
}
