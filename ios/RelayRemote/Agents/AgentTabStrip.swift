import SwiftUI

/// The horizontally scrollable agent tabs, the top row of the dock's message
/// panel (RR-553), styled like the desktop terminal tabs: the name, then the agent's status glyph. The
/// selected tab sits on a glass panel. No blob or glow inside the tabs.
struct AgentTabStrip: View {
    let tabs: [AgentsScreenState.Tab]
    let selected: String
    let onSelect: (String) -> Void
    @Namespace private var pill

    static let height: CGFloat = 36
    /// The desktop terminal tabs' label size.
    static let label = RelayTextStyle(weight: .regular, size: 13, lineHeight: 16)
    static let markedLabel = RelayTextStyle(weight: .semiBold, size: 13, lineHeight: 16)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        Button {
                            withAnimation(RelayMotion.move) { onSelect(tab.slug) }
                        } label: { item(tab) }
                            .buttonStyle(.relayPlain)
                            .id(tab.slug)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(tab.name), \(StatusGlyph.accessibilityLabel(tab.glyph))"
                                                + (tab.marked ? ", new reply" : ""))
                            .accessibilityAddTraits(tab.slug == selected ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
            .horizontalEdgeFade()
            .onChange(of: selected) { _, slug in
                withAnimation(RelayMotion.move) { proxy.scrollTo(slug, anchor: .center) }
            }
        }
        .frame(height: Self.height)
    }

    private func item(_ tab: AgentsScreenState.Tab) -> some View {
        let isSelected = tab.slug == selected
        return HStack(spacing: 8) {
            Text(tab.name)
                .relayTextStyle(tab.marked && !isSelected ? Self.markedLabel : Self.label)
                .foregroundStyle(isSelected || tab.marked ? RelayColor.neutral10 : RelayColor.neutral7)
                .animation(RelayMotion.enter, value: isSelected)
            StatusGlyph(state: tab.glyph)
        }
        .padding(.leading, 15)
        .padding(.trailing, 12)
        .frame(height: Self.height)
        .background {
            // One glass tab (with the Figma 8% hairline) that slides to the selection.
            if isSelected {
                RelayGlassBackground(glass: .panel, shape: RoundedRectangle(cornerRadius: 12, style: .continuous),
                                     stroke: 0.08)
                    .matchedGeometryEffect(id: "pill", in: pill)
            }
        }
        .contentShape(Rectangle())
    }
}

extension View {
    /// For a horizontal scroll view: its left and right edges fade out over
    /// `width` points, each only while there is more content past it, so
    /// tabs soften into the edge instead of being cut off by it (user,
    /// 2026-11-27). The vertical `EdgeFade` in `RelayModal`, turned sideways.
    func horizontalEdgeFade(_ width: CGFloat = 24) -> some View {
        modifier(HorizontalEdgeFade(width: width))
    }
}

private struct HorizontalEdgeFade: ViewModifier {
    let width: CGFloat
    @State private var fade = Fade()

    struct Fade: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Fade.self) { geometry in
                let overflow = geometry.contentSize.width + geometry.contentInsets.leading
                    + geometry.contentInsets.trailing - geometry.containerSize.width
                guard overflow > 1 else { return Fade() }
                let offset = min(max(geometry.contentOffset.x + geometry.contentInsets.leading, 0), overflow)
                return Fade(leading: min(width, offset), trailing: min(width, overflow - offset))
            } action: { _, new in
                fade = new
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade.leading)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade.trailing)
                }
            }
    }
}
