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
    /// Its page's bounds, set by the tab view's swipe (`PageSwipe`): the
    /// panel stays put while its page slides away under it.
    var page: Anchor<CGRect>? = nil
    /// The panel's contents, without its glass.
    let content: AnyView
    /// The fill over the glass.
    var glass: RelayGlass = .panel
    /// What the dock's text box holds (the draft or the transcript): when it
    /// changes, the dock can resize in place, and its glass follows.
    var textKey = ""
}

/// Every tab's hosted panel, by tab: while one tab replaces another both are
/// on screen, and the tab view draws the selected one's.
struct HostedPanelKey: PreferenceKey {
    static let defaultValue: [MainTab: HostedPanel] = [:]

    static func reduce(value: inout [MainTab: HostedPanel], nextValue: () -> [MainTab: HostedPanel]) {
        value.merge(nextValue()) { current, _ in current }
    }
}

extension HostedPanel {
    /// Where the panel sits with its page at rest: the page's swipe offset
    /// taken back out, so the dock and the project tabs hold still and keep
    /// morphing while the pages slide (user, 2026-11-28).
    /// Rounded to the half point: the swipe redraws the tab view every
    /// frame, and a place a hair off the last one (378.00000000000006 wide),
    /// set without animation, cut the morph between the dock and the project
    /// tabs short, so it snapped (user, 2026-11-28).
    func place(in proxy: GeometryProxy) -> CGRect {
        var frame = proxy[anchor]
        if let page { frame.origin.x -= proxy[page].minX }
        func round(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
        return CGRect(x: round(frame.minX), y: round(frame.minY),
                      width: round(frame.width), height: round(frame.height))
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
                     textKey: String = "") -> some View {
        if hosted {
            hidden()
                .accessibilityHidden(true)
                .anchorPreference(key: HostedPanelKey.self, value: .bounds) {
                    [tab: HostedPanel(tab: tab, anchor: $0, content: AnyView(self), glass: glass,
                                      textKey: textKey)]
                }
        } else {
            self
        }
    }
}
