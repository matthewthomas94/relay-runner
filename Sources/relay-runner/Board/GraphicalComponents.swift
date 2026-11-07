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

/// The kit's tooltip: a neutral-10 pill with text-xs neutral-1 copy, 4 by 8
/// points of padding, shown after a short hover in a panel that never takes
/// clicks. The text is also the element's accessibility hint.
private struct GraphicalTooltipModifier: ViewModifier {
    static let delay: TimeInterval = 0.6

    let text: String
    @State private var isShown = false
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                pending?.cancel()
                pending = nil
                guard hovering, !text.isEmpty else {
                    isShown = false
                    return
                }
                let show = DispatchWorkItem { isShown = true }
                pending = show
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: show)
            }
            .onDisappear {
                pending?.cancel()
                isShown = false
            }
            // Mounted only while shown, so idle controls carry no extra view.
            .background {
                if isShown { GraphicalTooltipPresenter(text: text) }
            }
            .accessibilityHint(text)
    }
}

struct GraphicalTooltipLabel: View {
    static let maxWidth: CGFloat = 280
    let text: String

    var body: some View {
        Text(text)
            .font(AppTypography.font(.caption))
            .foregroundStyle(GraphicalTheme.neutral1)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, GraphicalTheme.spaceXXS)
            .padding(.horizontal, GraphicalTheme.spaceXS)
            .background(GraphicalTheme.neutral10, in: RoundedRectangle(cornerRadius: GraphicalTheme.radiusS, style: .continuous))
            .frame(maxWidth: Self.maxWidth)
            .fixedSize()
    }
}

private struct GraphicalTooltipPresenter: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> GraphicalTooltipAnchorView { GraphicalTooltipAnchorView() }

    func updateNSView(_ view: GraphicalTooltipAnchorView, context: Context) {
        view.present(text)
    }

    static func dismantleNSView(_ view: GraphicalTooltipAnchorView, coordinator: ()) {
        view.hide()
    }
}

final class GraphicalTooltipAnchorView: NSView {
    private var panel: NSPanel?
    private var pendingText: String?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hide(animated: false)
        } else if let pendingText {
            present(pendingText)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let pendingText { present(pendingText) }
    }

    func present(_ text: String) {
        pendingText = text
        guard panel == nil, let window, bounds.width > 0 else { return }
        pendingText = nil
        let hosting = NSHostingView(rootView: GraphicalTooltipLabel(text: text))
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = window.level
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentView = hosting
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let gap: CGFloat = 6
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height)
        if let visible = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            if origin.y < visible.minY { origin.y = anchor.maxY + gap }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        RelayWindowMotion.present(panel, makeKey: false, style: .element)
    }

    func hide(animated: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        let close = {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if animated { RelayWindowMotion.dismiss(panel, completion: close) } else { close() }
    }
}

extension View {
    /// The kit's tooltip in place of the system `.help` tooltip.
    func graphicalTooltip(_ text: String) -> some View {
        modifier(GraphicalTooltipModifier(text: text))
    }
}
