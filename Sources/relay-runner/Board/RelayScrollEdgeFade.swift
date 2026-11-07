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

/// A `ScrollView` whose content fades out at the edges instead of being cut off.
/// Used wherever the board's `BoardOverlayScrollView` is not.
struct RelayFadingScrollView<Content: View>: View {
    let axis: Axis
    let showsIndicators: Bool
    @ViewBuilder let content: () -> Content
    @State private var contentFrame: CGRect = .zero
    @State private var viewport: CGSize = .zero

    private static var spaceName: String { "RelayFadingScrollView" }

    init(_ axis: Axis = .vertical, showsIndicators: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.axis = axis
        self.showsIndicators = showsIndicators
        self.content = content
    }

    var body: some View {
        ScrollView(axis == .vertical ? .vertical : .horizontal, showsIndicators: showsIndicators) {
            content()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ContentFrameKey.self,
                            value: proxy.frame(in: .named(Self.spaceName))
                        )
                    }
                )
        }
        .coordinateSpace(name: Self.spaceName)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ViewportKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(ContentFrameKey.self) { contentFrame = $0 }
        .onPreferenceChange(ViewportKey.self) { viewport = $0 }
        .mask(fadeMask)
    }

    private var fades: (leading: CGFloat, trailing: CGFloat) {
        switch axis {
        case .vertical:
            return RelayScrollEdgeFade.lengths(
                offset: -contentFrame.minY,
                contentLength: contentFrame.height,
                viewportLength: viewport.height
            )
        case .horizontal:
            return RelayScrollEdgeFade.lengths(
                offset: -contentFrame.minX,
                contentLength: contentFrame.width,
                viewportLength: viewport.width
            )
        }
    }

    @ViewBuilder
    private var fadeMask: some View {
        let fades = fades
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

    private struct ContentFrameKey: PreferenceKey {
        static var defaultValue: CGRect { .zero }
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
    }

    private struct ViewportKey: PreferenceKey {
        static var defaultValue: CGSize { .zero }
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
    }
}
