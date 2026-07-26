import AppKit
import SwiftUI

enum BoardOverlayScrollContentInsets {
    static let standard = EdgeInsets(top: 28, leading: 6, bottom: 28, trailing: 18)
    static let columnAligned = EdgeInsets(top: 28, leading: 0, bottom: 28, trailing: 0)
}

struct BoardOverlayScrollBoundary {
    let topInset: CGFloat?
    let bottomInset: CGFloat?
}

protocol BoardOverlayScrollBoundaryProviding: AnyObject {
    var boardOverlayScrollBoundary: BoardOverlayScrollBoundary? { get }
}

struct BoardOverlayScrollView<Content: View>: NSViewRepresentable {
    let contentInsets: EdgeInsets
    let resetID: AnyHashable?
    let content: Content

    init(
        contentInsets: EdgeInsets = BoardOverlayScrollContentInsets.standard,
        resetID: AnyHashable? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.contentInsets = contentInsets
        self.resetID = resetID
        self.content = content()
    }

    func makeNSView(context: Context) -> BoardOverlayScrollContainer {
        BoardOverlayScrollContainer(rootView: AnyView(scrollContent), resetID: resetID)
    }

    func updateNSView(_ nsView: BoardOverlayScrollContainer, context: Context) {
        nsView.update(rootView: AnyView(scrollContent), resetID: resetID)
    }

    private var scrollContent: some View {
        content
            .padding(contentInsets)
    }
}

final class BoardOverlayScrollContainer: NSView {
    private let scrollView = BoardOverlayKeyboardScrollView()
    private let documentView = BoardOverlayScrollDocumentView()
    private let contentView = BoardOverlayScrollContentView()
    private let hostingView: BoardOverlayScrollHostingView
    private let thumbView = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var hideWorkItem: DispatchWorkItem?
    private var lastLaidOutWidth: CGFloat = 0
    private var lastViewportHeight: CGFloat = 0
    private var lastContentHeight: CGFloat = 0
    private var lastContentMinY: CGFloat = 0
    private var isPerformingLayout = false
    private var resetID: AnyHashable?

    init(rootView: AnyView, resetID: AnyHashable? = nil) {
        hostingView = BoardOverlayScrollHostingView(rootView: rootView)
        self.resetID = resetID
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        hostingView = BoardOverlayScrollHostingView(rootView: AnyView(EmptyView()))
        super.init(coder: coder)
        setup()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutDocument()
        updateThumbFrame()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        if isScrollable {
            revealThumb()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        scheduleHide(after: 0.25)
    }

    func update(rootView: AnyView, resetID: AnyHashable? = nil) {
        let shouldResetOffset = self.resetID != resetID
        self.resetID = resetID
        hostingView.rootView = rootView
        layoutDocument(force: true)
        if shouldResetOffset {
            scrollToTop()
        }
        updateThumbFrame()
    }

    private func setup() {
        wantsLayer = true
        hostingView.onLayout = { [weak self] in
            guard let self, !self.isPerformingLayout else { return }
            self.layoutDocument()
            self.updateThumbFrame()
        }

        scrollView.contentView = BoardOverlayScrollClipView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView
        addSubview(scrollView)

        documentView.addSubview(contentView)
        contentView.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = true

        thumbView.wantsLayer = true
        thumbView.layer?.backgroundColor = NSColor(
            srgbRed: 226 / 255,
            green: 232 / 255,
            blue: 240 / 255,
            alpha: 0.58
        ).cgColor
        thumbView.layer?.cornerRadius = 2.5
        thumbView.alphaValue = 0
        addSubview(thumbView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func layoutDocument() {
        layoutDocument(force: false)
    }

    private func layoutDocument(force: Bool) {
        guard !isPerformingLayout else { return }
        let viewport = scrollView.contentView.bounds.size
        guard viewport.width > 0 else { return }
        isPerformingLayout = true
        defer { isPerformingLayout = false }

        let proposedHeight = max(hostingView.frame.height, 1)
        let proposedFrame = CGRect(
            origin: .zero,
            size: CGSize(width: viewport.width, height: proposedHeight)
        )
        if hostingView.frame != proposedFrame {
            hostingView.frame = proposedFrame
        }
        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = max(hostingView.fittingSize.height, 1)
        let fittingFrame = CGRect(
            origin: .zero,
            size: CGSize(width: viewport.width, height: fittingHeight)
        )
        if hostingView.frame != fittingFrame {
            hostingView.frame = fittingFrame
        }
        hostingView.layoutSubtreeIfNeeded()
        let boundaryRange = hostingView.explicitContentBoundaryRange()
        let contentMinY = boundaryRange?.lowerBound ?? 0
        let contentMaxY = boundaryRange?.upperBound ?? fittingHeight
        let contentHeight = max(1, contentMaxY - contentMinY)

        if !force,
           abs(viewport.width - lastLaidOutWidth) < 0.5,
           abs(viewport.height - lastViewportHeight) < 0.5,
           abs(contentHeight - lastContentHeight) < 0.5,
           abs(contentMinY - lastContentMinY) < 0.5 {
            return
        }
        let documentHeight = max(viewport.height, contentHeight)
        let documentFrame = CGRect(
            origin: .zero,
            size: CGSize(width: viewport.width, height: documentHeight)
        )
        if documentView.frame != documentFrame {
            documentView.frame = documentFrame
        }
        let contentFrame = CGRect(
            origin: CGPoint(x: 0, y: -contentMinY),
            size: CGSize(width: viewport.width, height: documentHeight)
        )
        if contentView.frame != contentFrame {
            contentView.frame = contentFrame
        }
        let contentBounds = CGRect(
            origin: .zero,
            size: CGSize(width: viewport.width, height: documentHeight)
        )
        if contentView.bounds != contentBounds {
            contentView.bounds = contentBounds
        }
        clampScrollOffset(documentHeight: documentHeight, viewportHeight: viewport.height)
        lastLaidOutWidth = viewport.width
        lastViewportHeight = viewport.height
        lastContentHeight = contentHeight
        lastContentMinY = contentMinY
    }

    private func clampScrollOffset(documentHeight: CGFloat, viewportHeight: CGFloat) {
        let maxOffset = max(0, documentHeight - viewportHeight)
        let currentOrigin = scrollView.contentView.bounds.origin
        let clampedY = min(max(currentOrigin.y, 0), maxOffset)
        guard abs(currentOrigin.y - clampedY) > 0.5 || abs(currentOrigin.x) > 0.5 else {
            return
        }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scrollToTop() {
        let currentOrigin = scrollView.contentView.bounds.origin
        guard abs(currentOrigin.y) > 0.5 || abs(currentOrigin.x) > 0.5 else {
            return
        }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func contentBoundsDidChange() {
        updateThumbFrame()
        guard isScrollable else {
            hideThumb(immediate: true)
            return
        }
        revealThumb()
    }

    private var isScrollable: Bool {
        contentHeight > viewportHeight + 1
    }

    private var viewportHeight: CGFloat {
        scrollView.contentView.bounds.height
    }

    private var contentHeight: CGFloat {
        documentView.frame.height
    }

    private var scrollOffset: CGFloat {
        min(max(scrollView.documentVisibleRect.minY, 0), max(0, contentHeight - viewportHeight))
    }

    private func updateThumbFrame() {
        guard isScrollable else {
            thumbView.frame = .zero
            return
        }
        let trackInset: CGFloat = 6
        let width: CGFloat = 5
        let trackHeight = max(0, bounds.height - trackInset * 2)
        let height = min(trackHeight, max(34, trackHeight * viewportHeight / contentHeight))
        let maxScroll = max(1, contentHeight - viewportHeight)
        let y = trackInset + (trackHeight - height) * scrollOffset / maxScroll
        thumbView.frame = CGRect(
            x: bounds.maxX - width - 2,
            y: y,
            width: width,
            height: height
        )
    }

    private func revealThumb() {
        hideWorkItem?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            thumbView.animator().alphaValue = 1
        }
        scheduleHide(after: 0.85)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.hideThumb(immediate: false)
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func hideThumb(immediate: Bool) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard !isHovering || !isScrollable else { return }
        if immediate {
            thumbView.alphaValue = 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            thumbView.animator().alphaValue = 0
        }
    }

    deinit {
        hideWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}

final class BoardOverlayScrollHostingView: NSHostingView<AnyView> {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    func explicitContentBoundaryRange() -> ClosedRange<CGFloat>? {
        var top: CGFloat?
        var bottom: CGFloat?
        appendExplicitContentBoundaries(in: self, top: &top, bottom: &bottom)
        guard let top, let bottom, bottom > top else {
            return nil
        }
        return top...bottom
    }

    private func appendExplicitContentBoundaries(
        in view: NSView,
        top: inout CGFloat?,
        bottom: inout CGFloat?
    ) {
        for subview in view.subviews {
            if let provider = subview as? BoardOverlayScrollBoundaryProviding,
               let boundary = provider.boardOverlayScrollBoundary {
                let frame = subview.convert(subview.bounds, to: self)
                if let inset = boundary.topInset {
                    let candidate = frame.minY - inset
                    top = min(top ?? candidate, candidate)
                }
                if let inset = boundary.bottomInset {
                    let candidate = frame.maxY + inset
                    bottom = max(bottom ?? candidate, candidate)
                }
            }
            appendExplicitContentBoundaries(in: subview, top: &top, bottom: &bottom)
        }
    }
}

final class BoardOverlayScrollDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class BoardOverlayScrollContentView: NSView {
    override var isFlipped: Bool { true }
}

final class BoardOverlayKeyboardScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 115:
            scroll(toY: 0)
        case 119:
            scroll(toY: maxScrollOffset)
        case 116:
            scroll(toY: contentView.bounds.origin.y - contentView.bounds.height)
        case 121:
            scroll(toY: contentView.bounds.origin.y + contentView.bounds.height)
        case 126:
            scroll(toY: contentView.bounds.origin.y - 40)
        case 125:
            scroll(toY: contentView.bounds.origin.y + 40)
        default:
            super.keyDown(with: event)
        }
    }

    private var maxScrollOffset: CGFloat {
        max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
    }

    private func scroll(toY proposedY: CGFloat) {
        let y = min(max(proposedY, 0), maxScrollOffset)
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }
}

final class BoardOverlayScrollClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        rect.origin.x = 0
        rect.origin.y = min(max(rect.origin.y, 0), max(0, documentView.frame.height - rect.height))
        return rect
    }
}
