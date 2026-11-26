import SwiftUI

/// The glass surfaces on the styles board: a blurred backdrop under a
/// translucent neutral, with a faint hairline that is lighter at the top.
enum RelayGlass {
    /// Panels: #0c0f13 at 50%.
    case panel
    /// Secondary buttons and bars: #171a1e at 75%.
    case control
    /// Selected tabs and items: #212529.
    case selected

    var tint: Color {
        switch self {
        case .panel: return RelayColor.neutral2.opacity(0.5)
        case .control: return RelayColor.neutral3.opacity(0.75)
        case .selected: return RelayColor.neutral4
        }
    }
}

/// The glass surface as a shape fill, for any container.
struct RelayGlassBackground<S: InsettableShape>: View {
    var glass: RelayGlass = .panel
    let shape: S

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(glass.tint))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            )
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Puts the glass surface behind the view, clipped to a rounded rectangle.
    func relayGlass(_ glass: RelayGlass = .panel, cornerRadius: CGFloat = RelayMetrics.panelRadius) -> some View {
        background(RelayGlassBackground(glass: glass,
                                        shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }
}

/// A glass panel (radius 16) holding its content.
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .relayGlass(.panel)
    }
}

/// Shared sizes from the styles board.
enum RelayMetrics {
    static let panelRadius: CGFloat = 16
    static let buttonRadius: CGFloat = 12
    /// Touch controls grow from the desktop's 36 pt to 44 pt.
    static let controlHeight: CGFloat = 44
    /// The onboarding primary button.
    static let largeControlHeight: CGFloat = 52
    static let screenMargin: CGFloat = 16
}
