import SwiftUI

struct BoardOverlayScrollView<Content: View>: View {
    let content: Content
    @State private var coordinateSpaceName = "boardOverlayScroll.\(UUID().uuidString)"
    @State private var scrollMetrics = BoardOverlayScrollMetrics()
    @State private var isHovering = false
    @State private var isScrollThumbVisible = false
    @State private var hideScrollThumbTask: Task<Void, Never>?

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { outerProxy in
            ZStack(alignment: .topTrailing) {
                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .padding(6)
                        .padding(.trailing, 12)
                        .background(
                            GeometryReader { contentProxy in
                                Color.clear.preference(
                                    key: BoardOverlayScrollMetricsKey.self,
                                    value: BoardOverlayScrollMetrics(
                                        offset: -contentProxy.frame(in: .named(coordinateSpaceName)).minY,
                                        contentHeight: contentProxy.size.height,
                                        viewportHeight: outerProxy.size.height
                                    )
                                )
                            }
                        )
                }
                .coordinateSpace(name: coordinateSpaceName)

                BoardOverlayScrollThumb(
                    metrics: scrollMetrics,
                    isVisible: isScrollThumbVisible || (isHovering && scrollMetrics.isScrollable)
                )
                .padding(.trailing, 2)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onHover { hovering in
            isHovering = hovering
            if hovering, scrollMetrics.isScrollable {
                revealScrollThumb()
            } else if !hovering {
                scheduleScrollThumbHide(delayNanoseconds: 250_000_000)
            }
        }
        .onPreferenceChange(BoardOverlayScrollMetricsKey.self) { updateScrollMetrics($0) }
        .onDisappear {
            hideScrollThumbTask?.cancel()
            hideScrollThumbTask = nil
        }
    }

    private func updateScrollMetrics(_ newMetrics: BoardOverlayScrollMetrics) {
        let oldMetrics = scrollMetrics
        scrollMetrics = newMetrics
        guard newMetrics.isScrollable else {
            hideScrollThumbTask?.cancel()
            hideScrollThumbTask = nil
            isScrollThumbVisible = false
            return
        }
        if isHovering, !isScrollThumbVisible {
            revealScrollThumb()
        }
        guard oldMetrics.isMeasured,
              abs(newMetrics.offset - oldMetrics.offset) > 0.25 else {
            return
        }
        revealScrollThumb()
    }

    private func revealScrollThumb() {
        hideScrollThumbTask?.cancel()
        withAnimation(.easeOut(duration: 0.10)) {
            isScrollThumbVisible = true
        }
        scheduleScrollThumbHide(delayNanoseconds: 850_000_000)
    }

    private func scheduleScrollThumbHide(delayNanoseconds: UInt64) {
        hideScrollThumbTask?.cancel()
        hideScrollThumbTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                isScrollThumbVisible = false
            }
            hideScrollThumbTask = nil
        }
    }
}

private struct BoardOverlayScrollThumb: View {
    let metrics: BoardOverlayScrollMetrics
    let isVisible: Bool

    var body: some View {
        if metrics.isScrollable {
            Capsule()
                .fill(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.58))
                .frame(width: 5, height: metrics.thumbHeight)
                .offset(y: metrics.thumbOffset)
                .opacity(isVisible ? 1 : 0)
        }
    }
}

private struct BoardOverlayScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    var isMeasured: Bool {
        contentHeight > 0 && viewportHeight > 0
    }

    var isScrollable: Bool {
        contentHeight > viewportHeight + 1
    }

    var thumbHeight: CGFloat {
        guard isScrollable else { return 0 }
        let trackHeight = max(0, viewportHeight - 12)
        return min(trackHeight, max(34, trackHeight * viewportHeight / contentHeight))
    }

    var thumbOffset: CGFloat {
        guard isScrollable else { return 0 }
        let trackHeight = max(0, viewportHeight - 12)
        let maxScroll = max(1, contentHeight - viewportHeight)
        let scroll = min(max(offset, 0), maxScroll)
        return 6 + (trackHeight - thumbHeight) * scroll / maxScroll
    }
}

private struct BoardOverlayScrollMetricsKey: PreferenceKey {
    static var defaultValue = BoardOverlayScrollMetrics()

    static func reduce(value: inout BoardOverlayScrollMetrics, nextValue: () -> BoardOverlayScrollMetrics) {
        value = nextValue()
    }
}
