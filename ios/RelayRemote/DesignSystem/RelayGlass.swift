import SwiftUI

/// The glass surfaces in the final Figma screens: each is Figma's Glass effect
/// (refraction 0.8, depth 20, light from the top left) under a translucent
/// neutral fill. On the phone that is iOS's own Liquid Glass with the same
/// fill laid over it, so the backdrop refracts and the rim catches the light
/// the way the designs show, instead of a flat blur.
enum RelayGlass {
    /// Panels, the dock and chat bubbles: #0c0f13, at 35% (the Figma's 50%
    /// read darker on the phone than the design).
    case panel
    /// The bottom tab bar: #0c0f13 at 55% (the Figma's 70%, lightened to match).
    case bar
    /// Secondary buttons: #171a1e at 75%.
    case control
    /// Selected tabs and pressed controls: #212529 at 75%.
    case selected
    /// The primary (white) button: white at 85% over the glass, so the
    /// backdrop's refraction and the glass rim still show at its edges.
    case primary
    /// The primary button pressed or active: the pressed grey at 85%.
    case primaryPressed

    /// The glass under every tint: iOS's clear Liquid Glass, as the desktop's
    /// shell glass is a blur with the material's own fill and tone removed.
    /// The regular glass frosts and darkens the backdrop on its own, so under
    /// these tints little of what is behind showed through.
    static let material = Glass.clear

    var tint: Color {
        switch self {
        case .panel: return RelayColor.neutral2.opacity(0.35)
        case .bar: return RelayColor.neutral2.opacity(0.55)
        case .control: return RelayColor.neutral3.opacity(0.75)
        case .selected: return RelayColor.neutral4.opacity(0.75)
        case .primary: return RelayColor.neutral10.opacity(0.85)
        case .primaryPressed: return RelayColor.primaryPressed.opacity(0.85)
        }
    }
}

/// The glass surface as a shape fill, for any container. `stroke` is the
/// hairline some surfaces carry in the designs (the tab bar at 6%, a selected
/// agent tab at 8%); most have none.
struct RelayGlassBackground<S: InsettableShape>: View {
    var glass: RelayGlass = .panel
    let shape: S
    var stroke: Double = 0
    @Environment(\.relayGlassFlat) private var flat

    var body: some View {
        Group {
            if flat {
                // Inside a glass surface that draws its own glass: the fill
                // only. The primary button is solid there, as in the Figma
                // dock, since no glass of its own lightens it.
                switch glass {
                case .primary: shape.fill(RelayColor.neutral10)
                case .primaryPressed: shape.fill(RelayColor.primaryPressed)
                default: shape.fill(glass.tint)
                }
            } else {
                Color.clear
                    .glassEffect(RelayGlass.material, in: shape)
                    .overlay(shape.fill(glass.tint))
            }
        }
        .overlay {
            if stroke > 0 { shape.strokeBorder(.white.opacity(stroke), lineWidth: 1) }
        }
        .environment(\.colorScheme, .dark)
        .animation(RelayMotion.press, value: glass)
    }
}

/// A control's surface (buttons, the talk button): the Figma fill only.
/// The Figma's controls carry a light 8 pt glass that barely shows on the
/// panels beneath them; iOS's Liquid Glass reads far stronger, so controls
/// draw the fill alone.
struct RelayGlassSurface<S: Shape>: ViewModifier {
    let glass: RelayGlass
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(fill)
            .animation(RelayMotion.press, value: glass)
    }

    @ViewBuilder
    private var fill: some View {
        switch glass {
        case .primary: shape.fill(RelayColor.neutral10)
        case .primaryPressed: shape.fill(RelayColor.primaryPressed)
        default: shape.fill(glass.tint)
        }
    }
}

extension EnvironmentValues {
    /// True inside a `GlassEffectContainer` whose surfaces carry the glass
    /// (the dock and the tab bar, RR-552). There a separate glass background
    /// view can draw over the text beside it, so controls draw their fill only.
    @Entry var relayGlassFlat = false
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
