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
    static let hoverFillNSColor = NSColor(srgbRed: 18 / 255, green: 22 / 255, blue: 30 / 255, alpha: 1)
    static let borderNSColor = NSColor(srgbRed: 17 / 255, green: 22 / 255, blue: 29 / 255, alpha: 1)

    static let panelFill = Color(nsColor: panelFillNSColor)
    static let contentFill = Color(nsColor: contentFillNSColor)
    static let hoverFill = Color(nsColor: hoverFillNSColor)
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

    static let motionDuration: Double = 0.15

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
                strokeOpacity: surface == .projectCard ? 0.48 : 0.30,
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
                strokeOpacity: surface == .control ? 0.16 : 0.14,
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
