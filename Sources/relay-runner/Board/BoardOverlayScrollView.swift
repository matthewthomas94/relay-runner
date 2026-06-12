import AppKit
import SwiftUI

struct BoardOverlayScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> BoardOverlayScrollContainer {
        BoardOverlayScrollContainer(rootView: AnyView(scrollContent))
    }

    func updateNSView(_ nsView: BoardOverlayScrollContainer, context: Context) {
        nsView.update(rootView: AnyView(scrollContent))
    }

    private var scrollContent: some View {
        content
            .padding(6)
            .padding(.trailing, 12)
    }
}

final class BoardOverlayScrollContainer: NSView {
    private let scrollView = NSScrollView()
    private let documentView = BoardOverlayScrollDocumentView()
    private let hostingView: NSHostingView<AnyView>
    private let thumbView = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var hideWorkItem: DispatchWorkItem?
    private var lastLaidOutWidth: CGFloat = 0
    private var lastViewportHeight: CGFloat = 0
    private var lastLaidOutHeight: CGFloat = 0
    private let verticalContentInset: CGFloat = 28

    init(rootView: AnyView) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
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

    func update(rootView: AnyView) {
        hostingView.rootView = rootView
        layoutDocument(force: true)
        updateThumbFrame()
    }

    private func setup() {
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView
        addSubview(scrollView)

        documentView.addSubview(hostingView)
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
        let viewport = scrollView.contentView.bounds.size
        guard viewport.width > 0 else { return }
        if !force,
           abs(viewport.width - lastLaidOutWidth) < 0.5,
           abs(viewport.height - lastViewportHeight) < 0.5,
           lastLaidOutHeight > 0 {
            return
        }
        hostingView.frame = CGRect(origin: .zero, size: CGSize(width: viewport.width, height: 1))
        let fittingHeight = hostingView.fittingSize.height
        let contentHeight = fittingHeight + verticalContentInset * 2
        let documentHeight = max(viewport.height, contentHeight)
        documentView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: viewport.width, height: documentHeight)
        )
        hostingView.frame = CGRect(
            origin: CGPoint(x: 0, y: verticalContentInset),
            size: CGSize(width: viewport.width, height: fittingHeight)
        )
        lastLaidOutWidth = viewport.width
        lastViewportHeight = viewport.height
        lastLaidOutHeight = documentHeight
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

final class BoardOverlayScrollDocumentView: NSView {
    override var isFlipped: Bool { true }
}
