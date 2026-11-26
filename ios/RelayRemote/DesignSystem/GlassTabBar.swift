import SwiftUI

/// The app's three tabs, mirroring the desktop.
enum MainTab: String, CaseIterable, Identifiable {
    case agents, workspace, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: return "Agents"
        case .workspace: return "Workspace"
        case .settings: return "Settings"
        }
    }

    var icon: LucideIcon {
        switch self {
        case .agents: return .users
        case .workspace: return .squareKanban
        case .settings: return .settings
        }
    }
}

/// The glass bottom tab bar from `21-agents-ready.jpg`: a 66 pt glass bar
/// 16 pt in from each side and 30 pt above the bottom of the screen, with
/// the selected tab on a lighter inset pill. The tutorial shows the same
/// bar, dimmed, so it lives in the design system.
struct GlassTabBar: View {
    @Binding var selection: MainTab
    /// Tabs drawn at 30%, as the tutorial dims controls it is not teaching.
    var dimmed = false

    static let height: CGFloat = 66
    static let bottomOffset: CGFloat = 30
    static let cornerRadius: CGFloat = 33
    static let inset: CGFloat = 7
    /// How far the bar's top sits above the bottom safe-area edge on a phone
    /// with a home indicator (34 pt). Content above the bar insets by this.
    static let contentInset: CGFloat = height + bottomOffset - 34

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { tab in
                Button { selection = tab } label: { item(tab) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(tab == selection ? [.isSelected] : [])
            }
        }
        .padding(Self.inset)
        .frame(height: Self.height)
        .background(RelayGlassBackground(glass: .control,
                                         shape: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)))
        .opacity(dimmed ? 0.3 : 1)
        .padding(.horizontal, RelayMetrics.screenMargin)
    }

    private func item(_ tab: MainTab) -> some View {
        let selected = tab == selection
        return VStack(spacing: 4) {
            LucideImage(tab.icon, size: 22)
            Text(tab.title).font(.custom(RelayTextStyle.Weight.regular.postScriptName, fixedSize: 12))
        }
        .foregroundStyle(selected ? RelayColor.neutral10 : RelayColor.neutral7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if selected {
                RelayGlassBackground(glass: .selected,
                                     shape: RoundedRectangle(cornerRadius: Self.cornerRadius - Self.inset,
                                                             style: .continuous))
            }
        }
        .contentShape(Rectangle())
    }
}

extension View {
    /// Pins `bar` to the bottom of the screen, 30 pt above its edge, and
    /// insets this view's safe area so its content ends at the bar's top.
    func glassTabBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        ZStack(alignment: .bottom) {
            safeAreaPadding(.bottom, GlassTabBar.contentInset)
            bar()
                .padding(.bottom, GlassTabBar.bottomOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}
