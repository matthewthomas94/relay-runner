import SwiftUI

/// The panels above the tab bar (the Agents dock, the Workspace project tabs)
/// push out of the tab bar the way the desktop's session wheel pushes its
/// submenus out of the disc (user, 2026-11-28; `SessionWheelSubmenuMotion.swift`
/// in the Mac app): each panel has its own spring, so one sinks back into the
/// bar while the next pushes out; it starts wholly inside the bar and pulls
/// out of it, blurring most halfway, its controls fading in once it is 30%
/// out; its glass and the bar's merge as one until it pulls clear, and its
/// controls emerge from behind the bar rather than over it. Its width never
/// changes (user, 2026-11-28).
struct PanelPopProgress: VectorArithmetic {
    var agents = 0.0
    var workspace = 0.0

    init(agents: Double = 0, workspace: Double = 0) {
        self.agents = agents
        self.workspace = workspace
    }

    /// Fully out for `tab`'s panel, in for every other.
    init(showing tab: MainTab) {
        self.init(agents: tab == .agents ? 1 : 0, workspace: tab == .workspace ? 1 : 0)
    }

    subscript(tab: MainTab) -> Double {
        switch tab {
        case .agents: return agents
        case .workspace: return workspace
        case .settings: return 0
        }
    }

    static var zero: Self { .init() }
    var magnitudeSquared: Double { agents * agents + workspace * workspace }
    static func + (lhs: Self, rhs: Self) -> Self { .init(agents: lhs.agents + rhs.agents, workspace: lhs.workspace + rhs.workspace) }
    static func - (lhs: Self, rhs: Self) -> Self { .init(agents: lhs.agents - rhs.agents, workspace: lhs.workspace - rhs.workspace) }
    mutating func scale(by rhs: Double) { agents *= rhs; workspace *= rhs }

    /// The desktop wheel's submenu spring (`SessionWheelSubmenuPresentation.animation`).
    static let animation = Animation.spring(response: 0.2 + RelayMotion.tabGap, dampingFraction: 0.9)
}

/// One panel's look at `progress` (0 inside the bar, 1 in place), as the
/// desktop's `SessionWheelSubmenuPresentation`.
struct PanelPopPresentation {
    let progress: Double

    init(_ progress: Double) { self.progress = min(max(progress, 0), 1) }

    /// The blur peaks halfway out, 6 pt, and is gone at either end.
    var blur: CGFloat { 6 * sin(.pi * progress) }
    /// The controls fade in from 30% out, on a smoothstep.
    var controlsOpacity: Double {
        let reveal = min(max((progress - 0.3) / 0.65, 0), 1)
        return reveal * reveal * (3 - 2 * reveal)
    }

    /// Where the panel is: `place` moved down until its top is just inside the bar.
    func rect(place: CGRect, bar: CGRect) -> CGRect {
        let travel = bar.minY + 6 - place.minY
        return place.offsetBy(dx: 0, dy: (1 - progress) * travel)
    }

    /// The part of the panel out of the bar (and a little of it inside,
    /// where its glass merges with the bar's): what is drawn.
    func visible(place: CGRect, bar: CGRect) -> CGRect {
        let rect = rect(place: place, bar: bar)
        let bottom = min(rect.maxY, bar.minY + 14)
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, bottom - rect.minY))
    }
}

/// Retargets the springs from where they are when tabs change quickly.
struct PanelPopAnimation<Content: View>: View, Animatable {
    var progress: PanelPopProgress
    @ViewBuilder var content: (PanelPopProgress) -> Content

    var animatableData: PanelPopProgress {
        get { progress }
        set { progress = newValue }
    }

    var body: some View { content(progress) }
}

/// Each panel's last place and contents, so a panel can sink back into the
/// bar after its page has gone. A class: the tab view writes it while it
/// draws, without redrawing.
final class PanelPopCache {
    struct Entry {
        var panel: HostedPanel
        var frame: CGRect
    }

    private(set) var entries: [MainTab: Entry] = [:]

    func remember(_ panel: HostedPanel, at frame: CGRect) {
        entries[panel.tab] = Entry(panel: panel, frame: frame)
    }
}
