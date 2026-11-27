import SwiftUI

/// The glass surfaces in the final Figma screens: each is Figma's Glass effect
/// (refraction 0.8, depth 20, light from the top left) with a translucent
/// neutral fill. On the phone that is iOS's own Liquid Glass, tinted with the
/// Figma fill, so the edges refract and catch the light the way the designs
/// show. A flat fill with a drawn rim read as no glass at all (user,
/// 2026-11-27).
enum RelayGlass {
    /// Panels, the dock and chat bubbles: #0c0f13 at 30% (Figma Final,
    /// clearer glass, user 2026-11-27).
    case panel
    /// The bottom tab bar and the Workspace project tabs container: #0c0f13 at 45%.
    case bar
    /// Secondary buttons and controls: #171a1e at 50%.
    case control
    /// Selected tabs and pressed controls: #212529 at 50%.
    case selected
    /// Solid cards and pills (Workspace ticket cards, the selected project
    /// tab): #171a1e at 60%.
    case card
    /// Other #212529 fills (the user's chat bubbles, a segmented control's
    /// selected segment): at 65%.
    case raised
    /// The primary (white) button: white at 85% over the glass, so the
    /// backdrop's refraction and the glass rim still show at its edges.
    case primary
    /// The primary button pressed or active: the pressed grey at 85%.
    case primaryPressed

    /// The glass under every tint: iOS's regular Liquid Glass, the more
    /// frosted of its two, nearer Figma's frost 48 (user, 2026-11-28).
    static let material = Glass.regular

    /// This surface's Liquid Glass: the clear glass tinted with its fill.
    var liquid: Glass { RelayGlass.material.tint(liquidTint) }

    /// The tint inside the glass. iOS's glass lightens what it tints, so the
    /// panels (the dock, chat bubbles) and bars (the tab bar, the Workspace
    /// project tabs) take a much stronger tint than their Figma fill to come
    /// out as dark as the designs on the phone (user, 2026-11-28).
    private var liquidTint: Color {
        switch self {
        case .panel: return RelayColor.neutral2.opacity(0.75)
        case .bar: return RelayColor.neutral2.opacity(0.88)
        // The user's chat bubbles: a shade lighter than the fill, so they
        // stand apart from the agent's dark bubbles (user, 2026-11-28).
        case .raised: return RelayColor.neutral5.opacity(0.65)
        default: return tint
        }
    }

    /// How bright the lit rim is: panels and bars carry Figma's 0.8 light,
    /// controls its 0.5, filled pills a little.
    var rimLight: Double {
        switch self {
        case .panel, .bar: return 0.8
        case .control, .selected: return 0.5
        case .card, .raised: return 0.35
        case .primary, .primaryPressed: return 0
        }
    }

    var tint: Color {
        switch self {
        case .panel: return RelayColor.neutral2.opacity(0.3)
        case .bar: return RelayColor.neutral2.opacity(0.45)
        case .control: return RelayColor.neutral3.opacity(0.5)
        case .selected: return RelayColor.neutral4.opacity(0.5)
        case .card: return RelayColor.neutral3.opacity(0.6)
        case .raised: return RelayColor.neutral4.opacity(0.65)
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
                    .glassEffect(glass.liquid, in: shape)
            }
        }
        .overlay {
            if stroke > 0 { shape.strokeBorder(.white.opacity(stroke), lineWidth: 1) }
        }
        .environment(\.colorScheme, .dark)
        .animation(RelayMotion.press, value: glass)
    }
}

/// A control's surface (buttons, the talk button): the Figma fill, with the
/// control glass's lit rim on secondary and danger buttons. The primary
/// button is solid white, as in Figma.
struct RelayGlassSurface<S: InsettableShape>: ViewModifier {
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
        // Secondary and danger buttons: the Figma control glass's lit edge.
        default: shape.fill(glass.tint).overlay(RelayGlassRim(shape: shape, light: glass.rimLight))
        }
    }
}

/// Figma's Glass light on a surface's edge: a 1 pt rim, brightest at the
/// top-left corner where the light falls, fading across the surface and
/// catching again faintly at the bottom-right, as a glass slab does. `light`
/// is Figma's light intensity.
struct RelayGlassRim<S: InsettableShape>: View {
    let shape: S
    var light: Double = 0.8

    var body: some View {
        shape.strokeBorder(
            LinearGradient(stops: [.init(color: .white.opacity(0.32 * light), location: 0),
                                   .init(color: .white.opacity(0.06 * light), location: 0.4),
                                   .init(color: .white.opacity(0.04 * light), location: 0.6),
                                   .init(color: .white.opacity(0.16 * light), location: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1)
        .allowsHitTesting(false)
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
