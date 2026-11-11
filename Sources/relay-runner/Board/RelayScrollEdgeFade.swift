import AppKit
import SwiftUI

/// How far content fades at a scroll edge it has passed under. Each edge fades
/// only as far as there is content beyond it, so a list at rest keeps its
/// first and last rows solid and the fade grows in as it scrolls.
enum RelayScrollEdgeFade {
    static let length: CGFloat = 32

    static func lengths(
        offset: CGFloat,
        contentLength: CGFloat,
        viewportLength: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        let overflow = contentLength - viewportLength
        guard viewportLength > 0, overflow > 1 else { return (0, 0) }
        let clampedOffset = min(max(offset, 0), overflow)
        return (
            leading: min(length, clampedOffset),
            trailing: min(length, overflow - clampedOffset)
        )
    }
}

/// Where a scroller sits along its axis: how far it has scrolled, and the
/// lengths of its content and viewport.
struct RelayScrollExtent: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0

    var fades: (leading: CGFloat, trailing: CGFloat) {
        RelayScrollEdgeFade.lengths(offset: offset, contentLength: content, viewportLength: viewport)
    }

    @available(macOS 15.0, *)
    init(_ geometry: ScrollGeometry, axis: Axis) {
        let insets = geometry.contentInsets
        switch axis {
        case .vertical:
            offset = geometry.contentOffset.y + insets.top
            content = geometry.contentSize.height + insets.top + insets.bottom
            viewport = geometry.containerSize.height
        case .horizontal:
            offset = geometry.contentOffset.x + insets.leading
            content = geometry.contentSize.width + insets.leading + insets.trailing
            viewport = geometry.containerSize.width
        }
    }

    init(offset: CGFloat = 0, content: CGFloat = 0, viewport: CGFloat = 0) {
        self.offset = offset
        self.content = content
        self.viewport = viewport
    }
}

/// A `ScrollView` whose content fades out at the edges instead of being cut off.
/// Used wherever the board's `BoardOverlayScrollView` is not. The fade follows
/// the scroll view's own geometry, which macOS 14 cannot report, so there it
/// scrolls without one.
struct RelayFadingScrollView<Content: View>: View {
    let axis: Axis
    let showsIndicators: Bool
    @ViewBuilder let content: () -> Content
    @State private var extent = RelayScrollExtent()

    init(_ axis: Axis = .vertical, showsIndicators: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.axis = axis
        self.showsIndicators = showsIndicators
        self.content = content
    }

    var body: some View {
        let scrollView = ScrollView(axis == .vertical ? .vertical : .horizontal, showsIndicators: showsIndicators) {
            content()
        }
        if #available(macOS 15.0, *) {
            scrollView
                .onScrollGeometryChange(for: RelayScrollExtent.self) { RelayScrollExtent($0, axis: axis) }
                    action: { _, extent in self.extent = extent }
                .mask(RelayScrollEdgeFadeMask(axis: axis, fades: extent.fades))
        } else {
            scrollView
        }
    }
}

extension View {
    /// Fades the edges of a view that scrolls inside AppKit, such as a
    /// `TextEditor`, whose scrolling SwiftUI's scroll geometry doesn't report.
    func relayAppKitScrollEdgeFade() -> some View {
        modifier(RelayAppKitScrollEdgeFade())
    }
}

private struct RelayAppKitScrollEdgeFade: ViewModifier {
    @State private var extent = RelayScrollExtent()

    func body(content: Content) -> some View {
        content
            .background(RelayAppKitScrollObserver { extent = $0 })
            .mask(RelayScrollEdgeFadeMask(axis: .vertical, fades: extent.fades))
    }
}

/// Finds the `NSScrollView` that fills this view's frame and reports its
/// extent whenever it scrolls or its content grows.
private struct RelayAppKitScrollObserver: NSViewRepresentable {
    let onChange: (RelayScrollExtent) -> Void

    func makeNSView(context: Context) -> RelayAppKitScrollObserverView {
        // Set before the view joins a window, so its first report isn't lost.
        let view = RelayAppKitScrollObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: RelayAppKitScrollObserverView, context: Context) {
        view.onChange = onChange
        view.attach()
    }
}

final class RelayAppKitScrollObserverView: NSView {
    var onChange: (RelayScrollExtent) -> Void = { _ in }
    private weak var scrollView: NSScrollView?
    private var reported: RelayScrollExtent?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    override func layout() {
        super.layout()
        attach()
    }

    func attach() {
        guard scrollView == nil, let root = window?.contentView else { return report() }
        let frame = convert(bounds, to: nil)
        guard frame.width > 0, frame.height > 0,
              let match = Self.scrollView(in: root, filling: frame) else { return }
        scrollView = match
        match.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: match.contentView)
        if let document = match.documentView {
            document.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                                   name: NSView.frameDidChangeNotification, object: document)
        }
        report()
    }

    @objc private func scrolled() { report() }

    private func report() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let content = document.frame.height
        let offset = document.isFlipped ? clip.bounds.minY : content - clip.bounds.maxY
        let extent = RelayScrollExtent(offset: offset, content: content, viewport: clip.bounds.height)
        guard extent != reported else { return }
        reported = extent
        // Scroll notifications can arrive mid-update; state changes wait for the next turn.
        DispatchQueue.main.async { [onChange] in onChange(extent) }
    }

    private static func scrollView(in view: NSView, filling frame: CGRect) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
           abs(scrollView.convert(scrollView.bounds, to: nil).minX - frame.minX) <= 1,
           abs(scrollView.convert(scrollView.bounds, to: nil).minY - frame.minY) <= 1,
           abs(scrollView.bounds.width - frame.width) <= 1,
           abs(scrollView.bounds.height - frame.height) <= 1 {
            return scrollView
        }
        for subview in view.subviews {
            if let match = scrollView(in: subview, filling: frame) { return match }
        }
        return nil
    }
}

/// Clears each edge over its fade length and keeps the middle solid.
private struct RelayScrollEdgeFadeMask: View {
    let axis: Axis
    let fades: (leading: CGFloat, trailing: CGFloat)

    var body: some View {
        switch axis {
        case .vertical:
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: fades.leading)
                Rectangle().fill(Color.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: fades.trailing)
            }
        case .horizontal:
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fades.leading)
                Rectangle().fill(Color.black)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fades.trailing)
            }
        }
    }
}
