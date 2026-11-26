import SwiftUI

/// The horizontally scrollable agent tabs above the dock, styled like the
/// desktop terminal tabs: the name, then the agent's status glyph. The
/// selected tab sits on a glass panel. No blob or glow inside the tabs.
struct AgentTabStrip: View {
    let tabs: [AgentsScreenState.Tab]
    let selected: String
    let onSelect: (String) -> Void

    static let height: CGFloat = 36
    /// The desktop terminal tabs' label size.
    static let label = RelayTextStyle(weight: .regular, size: 13, lineHeight: 16)
    static let markedLabel = RelayTextStyle(weight: .semiBold, size: 13, lineHeight: 16)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        Button { onSelect(tab.slug) } label: { item(tab) }
                            .buttonStyle(.plain)
                            .id(tab.slug)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(tab.name), \(StatusGlyph.accessibilityLabel(tab.glyph))"
                                                + (tab.marked ? ", new reply" : ""))
                            .accessibilityAddTraits(tab.slug == selected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: selected) { _, slug in
                withAnimation(RelayMotion.change) { proxy.scrollTo(slug, anchor: .center) }
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
            StatusGlyph(state: tab.glyph)
        }
        .padding(.leading, 15)
        .padding(.trailing, 12)
        .frame(height: Self.height)
        .background {
            if isSelected {
                RelayGlassBackground(glass: .panel, shape: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .contentShape(Rectangle())
    }
}
