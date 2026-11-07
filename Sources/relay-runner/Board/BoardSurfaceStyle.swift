import AppKit
import SwiftUI

enum BoardSurfaceLayout {
    static let horizontalPadding: CGFloat = 8
    static let columnSpacing: CGFloat = 12
    static let navigationTopPadding: CGFloat = 7
    /// The kit's tab list: a 28-point trigger inside 4 points of padding.
    static let navigationHeight: CGFloat = 36
    static let navigationToPanelSpacing: CGFloat = 16
    static let columnTopPadding: CGFloat = navigationTopPadding + navigationHeight + navigationToPanelSpacing
    static let columnHeight: CGFloat = 667
}

enum BoardDarkSurfaceStyle {
    // Graphical "RR" theme: page neutral-1, panels neutral-2, raised cards and
    // hovered controls neutral-3, active cards neutral-4. Borders are zero width.
    static let panelFillNSColor = GraphicalTheme.neutral2NSColor
    static let contentFillNSColor = GraphicalTheme.neutral1NSColor
    static let hoverFillNSColor = GraphicalTheme.neutral3NSColor
    static let cardFillNSColor = GraphicalTheme.neutral3NSColor
    static let cardActiveFillNSColor = GraphicalTheme.neutral4NSColor
    static let borderNSColor = NSColor.clear

    static let panelFill = Color(nsColor: panelFillNSColor)
    static let contentFill = Color(nsColor: contentFillNSColor)
    static let hoverFill = Color(nsColor: hoverFillNSColor)
    static let cardFill = Color(nsColor: cardFillNSColor)
    static let cardActiveFill = Color(nsColor: cardActiveFillNSColor)
    static let border = Color(nsColor: borderNSColor)
    static let placeholderTextNSColor = GraphicalTheme.neutral6NSColor
    static let placeholderText = Color(nsColor: placeholderTextNSColor)

    static let workspaceCornerRadius: CGFloat = GraphicalTheme.radiusL
    static let columnCornerRadius: CGFloat = GraphicalTheme.radiusM
    static let nestedCardCornerRadius: CGFloat = GraphicalTheme.radiusS
    static let floatingPanelCornerRadius: CGFloat = GraphicalTheme.radiusM
    static let shadowOpacity: Double = 0
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

enum ProgramBoardInteractiveSurface {
    case projectCard
    case ticketCard
    case control
}

enum ProgramBoardInteractionAccent: Equatable {
    case neutral
    case selected
}

struct ProgramBoardInteractionPresentation: Equatable {
    let usesHoverFill: Bool
    let fillOverlayOpacity: Double
    let strokeOpacity: Double
    let foregroundOpacity: Double
    let animationDuration: Double
    let accent: ProgramBoardInteractionAccent

    static let motionDuration: Double = RelayMotion.hoverDuration

    /// Eases hover, focus, and selection chrome; none under Reduce Motion.
    var animation: Animation? {
        animationDuration == 0 ? nil : RelayMotion.changeCurve.animation(duration: animationDuration)
    }

    static func resolve(
        surface: ProgramBoardInteractiveSurface,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        isHovered: Bool = false,
        isFocused: Bool = false,
        isDraggingSource: Bool = false,
        reduceMotion: Bool = false
    ) -> ProgramBoardInteractionPresentation {
        guard isEnabled else {
            return ProgramBoardInteractionPresentation(
                usesHoverFill: false,
                fillOverlayOpacity: 0,
                strokeOpacity: 0,
                foregroundOpacity: 0.45,
                animationDuration: reduceMotion ? 0 : motionDuration,
                accent: .neutral
            )
        }

        let usesHoverFill = !isDraggingSource && isHovered
        let duration = reduceMotion ? 0 : motionDuration

        if isSelected {
            return ProgramBoardInteractionPresentation(
                usesHoverFill: true,
                fillOverlayOpacity: 0,
                strokeOpacity: surface == .projectCard ? 0.24 : 0.15,
                foregroundOpacity: 0.98,
                animationDuration: duration,
                accent: .selected
            )
        }

        if isDraggingSource {
            return ProgramBoardInteractionPresentation(
                usesHoverFill: false,
                fillOverlayOpacity: 0,
                strokeOpacity: 0,
                foregroundOpacity: 0.82,
                animationDuration: duration,
                accent: .neutral
            )
        }

        if isFocused {
            return ProgramBoardInteractionPresentation(
                usesHoverFill: usesHoverFill,
                fillOverlayOpacity: usesHoverFill ? 0 : 0.065,
                strokeOpacity: 0.24,
                foregroundOpacity: 0.96,
                animationDuration: duration,
                accent: .selected
            )
        }

        if isHovered {
            return ProgramBoardInteractionPresentation(
                usesHoverFill: true,
                fillOverlayOpacity: 0,
                strokeOpacity: surface == .control ? 0.08 : 0.07,
                foregroundOpacity: 0.95,
                animationDuration: duration,
                accent: .neutral
            )
        }

        return ProgramBoardInteractionPresentation(
            usesHoverFill: false,
            fillOverlayOpacity: 0,
            strokeOpacity: 0,
            foregroundOpacity: surface == .control ? 0.85 : 0.82,
            animationDuration: duration,
            accent: .neutral
        )
    }
}

// macOS native text fields ignore foreground colours supplied in SwiftUI prompts.
// Draw the placeholder separately while retaining the native field's editing behavior.
extension View {
    func appPlaceholder(_ title: String, when isEmpty: Bool, inset: CGFloat = 0) -> some View {
        modifier(AppPlaceholderModifier(title: title, isEmpty: isEmpty, inset: inset))
    }
}

private struct AppPlaceholderModifier: ViewModifier {
    let title: String
    let isEmpty: Bool
    let inset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                if isEmpty {
                    Text(title)
                        .foregroundStyle(BoardDarkSurfaceStyle.placeholderText)
                        .lineLimit(1)
                        .padding(.horizontal, inset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.relayText)
                }
            }
            .animation(RelayMotion.change(reduceMotion: reduceMotion), value: isEmpty)
        }
    }
}
