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
    /// Set by `MainTabView`, which puts the bar's glass (`MorphGlass`) and the
    /// panels' glass in one `GlassEffectContainer`, so the dock's glass can
    /// melt into it (RR-552). The bar then draws only its tabs.
    var morph: Namespace.ID?
    @Namespace private var pill

    static let morphID = "tabBar"

    static let height: CGFloat = 66
    static let bottomOffset: CGFloat = 30
    /// The Figma bar: radius 24; the selected tab inside it, radius 18.
    static let cornerRadius: CGFloat = 24
    static let inset: CGFloat = 7
    static let pillRadius: CGFloat = 18
    /// How far the bar's top sits above the bottom safe-area edge on a phone
    /// with a home indicator (34 pt). Content above the bar insets by this.
    static let contentInset: CGFloat = height + bottomOffset - 34

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { tab in
                Button {
                    withAnimation(RelayMotion.move) { selection = tab }
                } label: { item(tab) }
                    .buttonStyle(.relayPlain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(tab == selection ? [.isSelected] : [])
            }
        }
        .padding(Self.inset)
        .frame(height: Self.height)
        .modifier(BarGlass(morph: morph))
        .opacity(dimmed ? 0.3 : 1)
        .animation(RelayMotion.enter, value: dimmed)
        .padding(.horizontal, RelayMetrics.screenMargin)
    }

    private func item(_ tab: MainTab) -> some View {
        let selected = tab == selection
        return VStack(spacing: 4) {
            LucideImage(tab.icon, size: 22)
            Text(tab.title).font(.custom(RelayTextStyle.Weight.regular.postScriptName, fixedSize: 12))
        }
        .foregroundStyle(selected ? RelayColor.neutral10 : RelayColor.neutral7)
        .animation(RelayMotion.enter, value: selected)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // One pill that slides to the selected tab.
            if selected {
                RelayGlassBackground(glass: .selected,
                                     shape: RoundedRectangle(cornerRadius: Self.pillRadius, style: .continuous))
                    .matchedGeometryEffect(id: "pill", in: pill)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The bar's glass: behind it, or, under `MainTabView`, none here: the bar's
/// glass is `GlassTabBar.MorphGlass` in the tab view's `GlassEffectContainer`,
/// and the bar's tabs are drawn above that container. A panel's glass melting
/// into the bar then passes under the tabs; when the bar carried the glass
/// itself, the sinking glass was drawn over its icons and labels, a dark
/// flicker leaving Agents for Settings (user, 2026-11-27).
private struct BarGlass: ViewModifier {
    let morph: Namespace.ID?

    func body(content: Content) -> some View {
        if morph != nil {
            content.environment(\.relayGlassFlat, true)
        } else {
            content.background(RelayGlassBackground(glass: .bar, shape: GlassTabBar.shape))
        }
    }
}

extension GlassTabBar {
    static let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    /// The bar's glass alone, with its glass ID, for `MainTabView`'s
    /// `GlassEffectContainer`, so another surface can morph into it. The bar,
    /// given the same `morph`, draws its tabs over it.
    struct MorphGlass: View {
        let morph: Namespace.ID

        var body: some View {
            Color.clear
                .frame(height: GlassTabBar.height)
                .glassEffect(RelayGlass.bar.liquid, in: GlassTabBar.shape)
                .glassEffectID(GlassTabBar.morphID, in: morph)
                .glassEffectTransition(.materialize)
                .padding(.horizontal, RelayMetrics.screenMargin)
        }
    }
}

extension View {
    /// Pins `bar` to the bottom of the screen, 30 pt above its edge, and
    /// insets this view's safe area so its content ends at the bar's top.
    /// `hidden` (while the keyboard is up) takes the bar away, so the content
    /// sits straight on the keyboard.
    func glassTabBar<Bar: View>(hidden: Bool = false, @ViewBuilder _ bar: () -> Bar) -> some View {
        ZStack(alignment: .bottom) {
            safeAreaPadding(.bottom, hidden ? 0 : GlassTabBar.contentInset)
            if !hidden {
                bar()
                    .padding(.bottom, GlassTabBar.bottomOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(.opacity.combined(with: .offset(y: 16)))
            }
        }
        .animation(RelayMotion.enter, value: hidden)
    }
}
