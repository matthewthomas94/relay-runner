import SwiftUI

/// The Workspace terminal's panel. RR-445: one session, so no session tabs.
struct WorkspaceTerminalSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background {
                let shape = RoundedRectangle(cornerRadius: BoardDarkSurfaceStyle.columnCornerRadius, style: .continuous)
                shape.fill(BoardDarkSurfaceStyle.panelFill)
                    .overlay { shape.strokeBorder(BoardDarkSurfaceStyle.border, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
                    .allowsHitTesting(false)
            }
    }
}
