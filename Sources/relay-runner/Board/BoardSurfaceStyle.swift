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
    /// The session wheel's tiles: neutral-3 at 50% over its pure black
    /// backdrop (neutral-4 when active), as solid colours, so a tile that
    /// leaves the backdrop mid-animation never lets the desktop through.
    static let wheelTileFill = Color(.sRGB, red: 11.5 / 255, green: 13 / 255, blue: 15 / 255, opacity: 1)
    static let wheelTileActiveFill = Color(.sRGB, red: 16.5 / 255, green: 18.5 / 255, blue: 20.5 / 255, opacity: 1)
    /// The terminal's New tab button, a surface-level square.
    static let tabActionFill = GraphicalTheme.neutral3.opacity(surfaceOpacity)
    static let tabActionHoverFill = GraphicalTheme.neutral4.opacity(surfaceOpacity)
    static let contentFill = Color(nsColor: contentFillNSColor)
    static let hoverFill = Color(nsColor: hoverFillNSColor)
    static let cardFill = Color(nsColor: cardFillNSColor)
    static let cardActiveFill = Color(nsColor: cardActiveFillNSColor)
    static let border = Color(nsColor: borderNSColor)
    /// The primary (white) action at 85%, borderless, and its lighter hover.
    static let primaryActionFill = GraphicalTheme.neutral10.opacity(0.85)
    static let primaryActionHoverFill = GraphicalTheme.neutral10.opacity(0.9)
    /// Hairlines on black controls: selects neutral-4, text fields neutral-5.
    static let selectStroke = GraphicalTheme.neutral4.opacity(0.5)
    static let fieldStroke = GraphicalTheme.neutral5.opacity(0.5)
    /// The light a glass edge catches: strongest at the top left, fading
    /// across the face and returning at the bottom right.
    static let glassRimStops: [Gradient.Stop] = [
        .init(color: Color.white.opacity(0.09), location: 0),
        .init(color: Color.white.opacity(0.02), location: 0.5),
        .init(color: Color.white.opacity(0.05), location: 1),
    ]
    static let glassRim = LinearGradient(stops: glassRimStops, startPoint: .topLeading, endPoint: .bottomTrailing)
    /// The same edge on a white glass fill, where it has to be brighter to show.
    static let glassRimOnLightStops: [Gradient.Stop] = [
        .init(color: Color.white.opacity(0.35), location: 0),
        .init(color: Color.white.opacity(0.1), location: 0.5),
        .init(color: Color.white.opacity(0.225), location: 1),
    ]
    /// The shell's black, solid under the notch and 75% at its foot.
    static let shellFill = LinearGradient(
        stops: [
            .init(color: GraphicalTheme.neutral1, location: 0.096),
            .init(color: GraphicalTheme.neutral1.opacity(actionOpacity), location: 1),
        ],
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
/// A `blurRadius` gives Figma's glass instead: a set
/// blur with no tint of its own, so the shell's gradient alone sets how
/// much of the desktop shows through.
struct LiquidGlassBackdrop: NSViewRepresentable {
    /// Figma's untinted glass at this blur; nil keeps the stock material.
    var blurRadius: CGFloat?

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = blurRadius.map { ShellGlassEffectView(blurRadius: $0) } ?? NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Figma's shell glass: an 8pt blur of the desktop without the material's
/// own fill, tone and tint, which darken it well past the design. AppKit has
/// no API for blur strength, so this adjusts the effect view's private layers
/// by name each time AppKit rebuilds them. If a macOS release renames them,
/// nothing matches and the stock material shows instead.
final class ShellGlassEffectView: NSVisualEffectView {
    /// Figma's glass depths: each layer stacked on the shell frosts more.
    static let shellBlurRadius: CGFloat = 8
    static let panelBlurRadius: CGFloat = 48
    static let floatingBlurRadius: CGFloat = 64
    private static let tintLayerNames: Set<String> = ["fill", "tone", "desktop tint"]

    let blurRadius: CGFloat

    init(blurRadius: CGFloat = shellBlurRadius) {
        self.blurRadius = blurRadius
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyShellGlass()
        // AppKit builds the material's layers after joining the window.
        DispatchQueue.main.async { [weak self] in self?.applyShellGlass() }
    }

    override func updateLayer() {
        super.updateLayer()
        applyShellGlass()
    }

    override func layout() {
        super.layout()
        applyShellGlass()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func applyShellGlass() {
        guard let layer else { return }
        Self.apply(to: layer, blurRadius: blurRadius)
    }

    static func apply(to layer: CALayer, blurRadius: CGFloat = shellBlurRadius) {
        if layer.name == "backdrop", layer.filters?.isEmpty == false {
            layer.setValue(blurRadius, forKeyPath: "filters.gaussianBlur.inputRadius")
        }
        if let name = layer.name, tintLayerNames.contains(name) {
            layer.isHidden = true
        }
        layer.sublayers?.forEach { apply(to: $0, blurRadius: blurRadius) }
    }
}

/// A panel on the shell (a column, the terminal) frosts the desktop more
/// than the shell does, then lays the shell's black gradient over it at the
/// panel's own position, so it reads as the same glass, only blurrier.
/// `PanelGlassUnderlay` for AppKit views: the skeleton loader's panels.
/// `shellTop` is the panel's top edge measured from the shell's top.
final class PanelGlassNSView: NSView {
    private let glass = ShellGlassEffectView(blurRadius: ShellGlassEffectView.panelBlurRadius)
    private let tint = FlippedTintView()
    private let gradient = CAGradientLayer()
    private let belowShell = CALayer()
    var shellTop: CGFloat = 0 { didSet { needsLayout = true } }

    override var isFlipped: Bool { true }

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        addSubview(glass)
        tint.wantsLayer = true
        gradient.colors = [
            GraphicalTheme.neutral1NSColor.cgColor,
            GraphicalTheme.neutral1NSColor.cgColor,
            GraphicalTheme.neutral1NSColor.withAlphaComponent(BoardDarkSurfaceStyle.actionOpacity).cgColor,
        ]
        gradient.locations = [0, 0.096, 1]
        belowShell.backgroundColor = GraphicalTheme.neutral1NSColor
            .withAlphaComponent(BoardDarkSurfaceStyle.actionOpacity).cgColor
        tint.layer?.addSublayer(gradient)
        tint.layer?.addSublayer(belowShell)
        addSubview(tint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        glass.frame = bounds
        tint.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The tint view's layer is flipped with this view, so y grows downward.
        let shellHeight = ProgramBoardBackdropStyle.backdropHeight
        gradient.frame = CGRect(x: 0, y: -shellTop, width: bounds.width, height: shellHeight)
        let below = shellHeight - shellTop
        belowShell.frame = CGRect(x: 0, y: below, width: bounds.width, height: max(0, bounds.height - below))
        CATransaction.commit()
    }
}

private final class FlippedTintView: NSView {
    override var isFlipped: Bool { true }
}

struct PanelGlassUnderlay: View {
    static let coordinateSpace = "programBoard"

    var body: some View {
        LiquidGlassBackdrop(blurRadius: ShellGlassEffectView.panelBlurRadius)
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    let top = proxy.frame(in: .named(Self.coordinateSpace)).minY
                    VStack(spacing: 0) {
                        BoardDarkSurfaceStyle.shellFill
                            .frame(height: ProgramBoardBackdropStyle.backdropHeight)
                        GraphicalTheme.neutral1.opacity(BoardDarkSurfaceStyle.actionOpacity)
                    }
                    .frame(height: ProgramBoardBackdropStyle.backdropHeight + max(0, top) + proxy.size.height)
                    .offset(y: -top)
                }
            }
    }
}

struct BoardDarkSurfaceBackground: View {
    let cornerRadius: CGFloat
    var fill: Color = BoardDarkSurfaceStyle.panelFill
    /// A surface that floats over other content (a menu, a dialog) brings its
    /// own blur and the shell's black under its fill, so it matches the same
    /// fill drawn on the board: the panel fill for a dialog, by default.
    var floating = false
    /// A panel sitting on the shell, frosted one step past it.
    var panelGlass = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(fill)
            .background {
                if floating {
                    LiquidGlassBackdrop(blurRadius: ShellGlassEffectView.floatingBlurRadius)
                        .overlay(BoardDarkSurfaceStyle.floatingBaseFill)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                } else if panelGlass {
                    PanelGlassUnderlay()
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
