import AppKit
import SwiftUI

/// The Graphical kit's input surface: black at rest, neutral-3 when
/// disabled, neutral-2 when read-only, with the soft white focus ring.
struct GraphicalInputSurface: View {
    var isFocused = false
    var isEnabled = true
    var isReadOnly = false
    var cornerRadius: CGFloat = GraphicalTheme.radiusS

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(fill)
            .overlay(
                shape.strokeBorder(GraphicalTheme.focusRing.opacity(isFocused && isEnabled ? 1 : 0),
                                   lineWidth: GraphicalTheme.focusRingWidth)
            )
    }

    private var fill: Color {
        if !isEnabled { return GraphicalTheme.neutral3 }
        return isReadOnly ? GraphicalTheme.neutral2 : GraphicalTheme.neutral1
    }
}

/// Draws a text field as the kit's input: 12 points of side padding, the
/// 36-point control height, and the input surface, focus ring included.
private struct GraphicalInputModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(AppTypography.font(.field))
            .foregroundStyle(isEnabled ? SettingsSurfaceColor.primaryText : SettingsSurfaceColor.disabledText)
            .lineLimit(1)
            .padding(.horizontal, GraphicalTheme.spaceS)
            .frame(minHeight: GraphicalTheme.controlHeight)
            .background(GraphicalInputSurface(isFocused: isFocused, isEnabled: isEnabled))
            .focused($isFocused)
            .animation(reduceMotion ? nil : RelayMotion.hover, value: isFocused)
    }
}

extension View {
    /// The kit's text input. Fields that bind their own focus keep it and
    /// use `GraphicalInputSurface` directly instead.
    func graphicalInput() -> some View {
        modifier(GraphicalInputModifier())
    }
}

/// The kit's progress bar: a neutral-3 track and a neutral-10 indicator,
/// both fully rounded. Indeterminate progress keeps the system spinner.
struct GraphicalProgressStyle: ProgressViewStyle {
    static let trackHeight: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        let fraction = min(max(configuration.fractionCompleted ?? 0, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(GraphicalTheme.neutral3)
                Capsule().fill(GraphicalTheme.neutral10)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: Self.trackHeight)
        .animation(RelayMotion.change, value: fraction)
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

extension ProgressViewStyle where Self == GraphicalProgressStyle {
    static var graphical: GraphicalProgressStyle { GraphicalProgressStyle() }
}

/// The kit's elevation (revision akv11dy4w50z). Each level is two black
/// layers as the kit's CSS renders them: a tight key shadow at #00000016 and
/// the token itself at #00000020. SwiftUI shadows have no spread, so each
/// layer's spread is folded into its blur radius.
enum GraphicalShadow {
    case s, m, l

    struct Layer {
        let y: CGFloat
        let blur: CGFloat
        let spread: CGFloat
        let alpha: Double
    }

    static let keyAlpha = Double(0x16) / 255
    static let ambientAlpha = Double(0x20) / 255

    var layers: [Layer] {
        let (y, blur, spread): (CGFloat, CGFloat, CGFloat) = switch self {
        case .s: (2, 4, 2)
        case .m: (4, 8, 4)
        case .l: (8, 16, 8)
        }
        return [
            Layer(y: y / 4, blur: blur / 4, spread: spread / 4, alpha: Self.keyAlpha),
            Layer(y: y, blur: blur, spread: spread, alpha: Self.ambientAlpha),
        ]
    }
}

private struct GraphicalShadowModifier: ViewModifier {
    let shadow: GraphicalShadow
    let isVisible: Bool

    func body(content: Content) -> some View {
        let layers = shadow.layers
        content
            .shadow(color: GraphicalTheme.neutral1.opacity(isVisible ? layers[0].alpha : 0),
                    radius: (layers[0].blur + layers[0].spread) / 2, x: 0, y: layers[0].y)
            .shadow(color: GraphicalTheme.neutral1.opacity(isVisible ? layers[1].alpha : 0),
                    radius: (layers[1].blur + layers[1].spread) / 2, x: 0, y: layers[1].y)
    }
}

extension View {
    /// The kit's s, m or l elevation; `isVisible` lets a state fade it in.
    func graphicalShadow(_ shadow: GraphicalShadow, isVisible: Bool = true) -> some View {
        modifier(GraphicalShadowModifier(shadow: shadow, isVisible: isVisible))
    }
}
