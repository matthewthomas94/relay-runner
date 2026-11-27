import SwiftUI

/// To or from Settings, which has no panel, the panel above the tab bar (the
/// Agents dock or the Workspace project tabs) pushes out of the tab bar the
/// way the desktop's session wheel pushes its submenus out of the disc, and
/// sinks back into it (user, 2026-11-28; `SessionWheelSubmenuMotion.swift`
/// in the Mac app): it starts wholly inside the bar and pulls out of it on the
/// wheel's spring, blurring most halfway, its controls fading in once it is
/// 30% out; its glass and the bar's merge as one until it pulls clear. Its
/// width never changes (user, 2026-11-28). Between Agents and Workspace the
/// panel stays out and morphs from one tab's panel into the other's.
struct PanelPop: ViewModifier, Animatable {
    /// 0 inside the bar, 1 in place.
    var progress: Double
    let place: CGRect
    let bar: CGRect
    let glass: Glass
    let radius: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// The desktop wheel's submenu spring (`SessionWheelSubmenuPresentation.animation`).
    static let animation = Animation.spring(response: 0.2 + RelayMotion.tabGap, dampingFraction: 0.9)

    func body(content: Content) -> some View {
        let look = PanelPopPresentation(progress)
        let visible = look.visible(place: place, bar: bar)
        let shape = RoundedRectangle(cornerRadius: min(radius, visible.height / 2), style: .continuous)
        ZStack(alignment: .top) {
            // Bottom-anchored, so while the dock's own height animates (the
            // text box after talking) its buttons stay put inside the glass.
            content
                .frame(width: place.width, height: place.height, alignment: .bottom)
                .opacity(look.controlsOpacity)
                .blur(radius: look.blur)
        }
        .frame(width: visible.width, height: visible.height, alignment: .top)
        // The controls emerge from behind the bar, inside the glass.
        .clipShape(shape)
        .glassEffect(glass, in: shape)
        .opacity(look.progress > 0.001 ? 1 : 0)
        .position(x: visible.midX, y: visible.midY)
    }
}

/// One panel's look at `progress` (0 inside the bar, 1 in place), as the
/// desktop's `SessionWheelSubmenuPresentation`.
struct PanelPopPresentation {
    let progress: Double

    init(_ progress: Double) { self.progress = min(max(progress, 0), 1) }

    /// The blur peaks halfway out, 6 pt, and is gone at either end.
    var blur: CGFloat { progress > 0.999 ? 0 : 6 * sin(.pi * progress) }
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

/// The last panel each tab handed up and where it was, so a panel can sink
/// back into the bar after its page has gone. Only for that: while its page
/// is on screen the panel is always drawn from the page's live copy. A class:
/// the tab view writes it while it draws, without redrawing.
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
