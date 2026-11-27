import SwiftUI

/// The glass panel a tab keeps just above the tab bar, handed up to
/// `MainTabView` (RR-552, RR-553): the Agents dock, or the Workspace's project
/// tabs. The tab keeps the panel's place with a hidden copy, and the tab view
/// draws the panel there in the same `GlassEffectContainer` as the tab bar, as
/// one glass that reshapes from one tab's panel into the next tab's, or melts
/// into the tab bar on a tab that has none.
struct HostedPanel {
    let tab: MainTab
    /// The place the panel takes in its tab.
    let anchor: Anchor<CGRect>
    /// The panel's contents, without its glass.
    let content: AnyView
    /// The fill over the glass.
    var glass: RelayGlass = .panel
    /// Talking or not: the one change that resizes the dock in place.
    var isTalking = false
}

/// Every tab's hosted panel, by tab: while one tab replaces another both are
/// on screen, and the tab view draws the selected one's.
struct HostedPanelKey: PreferenceKey {
    static let defaultValue: [MainTab: HostedPanel] = [:]

    static func reduce(value: inout [MainTab: HostedPanel], nextValue: () -> [MainTab: HostedPanel]) {
        value.merge(nextValue()) { current, _ in current }
    }
}

extension EnvironmentValues {
    /// True under `MainTabView`, which draws the tabs' panels (`HostedPanel`).
    @Entry var hostsPanels = false
}

extension View {
    /// Under `MainTabView`: keeps this panel's place with a hidden copy and
    /// hands the panel up to be drawn in the tab bar's glass container.
    /// Elsewhere: the panel as it is.
    @ViewBuilder
    func hostedPanel(_ tab: MainTab, hosted: Bool, glass: RelayGlass = .panel,
                     isTalking: Bool = false) -> some View {
        if hosted {
            hidden()
                .accessibilityHidden(true)
                .anchorPreference(key: HostedPanelKey.self, value: .bounds) {
                    [tab: HostedPanel(tab: tab, anchor: $0, content: AnyView(self), glass: glass,
                                      isTalking: isTalking)]
                }
        } else {
            self
        }
    }
}
