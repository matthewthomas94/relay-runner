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

    /// The Workspace board's columns: Projects and the four ticket lanes.
    static let boardColumnCount = ProgramBoardLane.allCases.count + 1

    /// The width of one Workspace board column, the Projects panel, in a row
    /// `rowWidth` wide. Notes, History and Settings give their left panel
    /// this width so every page lines up with the board.
    static func boardColumnWidth(rowWidth: CGFloat) -> CGFloat {
        let count = CGFloat(boardColumnCount)
        return max(0, (rowWidth - columnSpacing * (count - 1)) / count)
    }
}

enum BoardDarkSurfaceStyle {
    // Liquid glass, three levels. Background: the black shell that drops from
    // the notch. Surface: panels, neutral-2 at 50% over the shell's blur.
    // Action: anything clickable, neutral-3 at 75%, one neutral step lighter
    // on hover or when selected. Fields stay black with a hairline.
    static let surfaceOpacity: CGFloat = 0.5
    static let actionOpacity: CGFloat = 0.75
    static let panelFillNSColor = GraphicalTheme.neutral2NSColor.withAlphaComponent(surfaceOpacity)
    static let contentFillNSColor = GraphicalTheme.neutral1NSColor
    static let hoverFillNSColor = GraphicalTheme.neutral3NSColor.withAlphaComponent(actionOpacity)
    static let cardFillNSColor = GraphicalTheme.neutral3NSColor.withAlphaComponent(actionOpacity)
    static let cardActiveFillNSColor = GraphicalTheme.neutral4NSColor.withAlphaComponent(actionOpacity)
    static let borderNSColor = NSColor.clear

    static let panelFill = Color(nsColor: panelFillNSColor)
    /// Under a floating surface's fill: the shell's black, so a dialog reads
    /// as a board panel and a menu as a ticket on the board.
    static let floatingBaseFill = GraphicalTheme.neutral1.opacity(actionOpacity)
    /// The session wheel's tiles, on its pure black backdrop.
    static let wheelTileFill = GraphicalTheme.neutral3.opacity(surfaceOpacity)
    static let wheelTileActiveFill = GraphicalTheme.neutral4.opacity(surfaceOpacity)
    /// The terminal's New tab button, a surface-level square.
    static let tabActionFill = GraphicalTheme.neutral3.opacity(surfaceOpacity)
    static let tabActionHoverFill = GraphicalTheme.neutral4.opacity(surfaceOpacity)
    static let contentFill = Color(nsColor: contentFillNSColor)
    static let hoverFill = Color(nsColor: hoverFillNSColor)
    static let cardFill = Color(nsColor: cardFillNSColor)
    static let cardActiveFill = Color(nsColor: cardActiveFillNSColor)
    static let border = Color(nsColor: borderNSColor)
    /// The primary (white) action and its lighter hover.
    static let primaryActionFill = GraphicalTheme.neutral10.opacity(actionOpacity)
    static let primaryActionHoverFill = GraphicalTheme.neutral10.opacity(0.9)
    /// Hairlines on black controls: selects neutral-4, text fields neutral-5.
    static let selectStroke = GraphicalTheme.neutral4.opacity(0.5)
    static let fieldStroke = GraphicalTheme.neutral5.opacity(0.5)
    /// The light a glass edge catches: strongest at the top left, fading
    /// across the face and returning at the bottom right.
    static let glassRim = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(0.18), location: 0),
            .init(color: Color.white.opacity(0.04), location: 0.5),
            .init(color: Color.white.opacity(0.1), location: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// The same edge on a white glass fill, where it has to be brighter to show.
    static let glassRimOnLight = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(0.7), location: 0),
            .init(color: Color.white.opacity(0.2), location: 0.5),
            .init(color: Color.white.opacity(0.45), location: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// The shell's black, solid under the notch and 75% at its foot.
    static let shellFill = LinearGradient(
        colors: [GraphicalTheme.neutral1, GraphicalTheme.neutral1.opacity(actionOpacity)],
        startPoint: .top,
        endPoint: .bottom
    )
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

/// The desktop behind the window, blurred: what every glass level sits on.
struct LiquidGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct BoardDarkSurfaceBackground: View {
    let cornerRadius: CGFloat
    var fill: Color = BoardDarkSurfaceStyle.panelFill
    /// A surface that floats over other content (a menu, a dialog) brings its
    /// own blur and the shell's black under its fill, so it matches the same
    /// fill drawn on the board: the panel fill for a dialog, by default.
    var floating = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(fill)
            .background {
                if floating {
                    LiquidGlassBackdrop()
                        .overlay(BoardDarkSurfaceStyle.floatingBaseFill)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(BoardDarkSurfaceStyle.glassRim, lineWidth: 1)
            )
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
