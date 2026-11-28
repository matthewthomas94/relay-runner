import SwiftUI

/// To or from Settings, which has no panel, the panel above the tab bar (the
/// Agents dock or the Workspace project tabs) pushes out of the tab bar the
/// way the desktop's session wheel pushes its submenus out of the disc, and
/// sinks back into it (user, 2026-11-28; `SessionWheelSubmenuMotion.swift`
/// in the Mac app). It starts wholly inside the bar and pulls out of it on the
/// wheel's spring; while it moves, the bar and the panel are one black liquid
/// silhouette (blurred, then cut at an alpha threshold, as the wheel's
/// `SessionWheelLiquidBackdrop`), so the panel flows out of the bar rather
/// than sliding over it. Its controls emerge from behind the bar, blurring
/// most halfway and fading in once the panel is 30% out. Its width never
/// changes (user, 2026-11-28). Between Agents and Workspace the panel stays
/// out and morphs from one tab's panel into the other's: `place` animates too.
struct PanelPop: ViewModifier, Animatable {
    /// 0 inside the bar, 1 in place.
    var progress: Double
    var place: CGRect
    let bar: CGRect
    let radius: CGFloat

    var animatableData: AnimatablePair<Double, CGRect.AnimatableData> {
        get { AnimatablePair(progress, place.animatableData) }
        set { progress = newValue.first; place.animatableData = newValue.second }
    }

    /// The desktop wheel's submenu spring (`SessionWheelSubmenuPresentation.animation`).
    static let animation = Animation.spring(response: 0.2 + RelayMotion.tabGap, dampingFraction: 0.9)

    func body(content: Content) -> some View {
        let look = PanelPopPresentation(progress)
        let rect = look.rect(place: place, bar: bar)
        ZStack(alignment: .topLeading) {
            PanelLiquid(look: look, panel: rect, bar: bar, radius: radius)
            // Laid out in place and carried by the panel's top edge, so they
            // rise out from behind the bar with it. Bottom-anchored, so while
            // the dock's own height animates (the text box after talking) its
            // buttons stay put in the panel.
            content
                .frame(width: place.width, height: place.height, alignment: .bottom)
                .opacity(look.controlsOpacity)
                .blur(radius: look.blur)
                .position(x: place.midX, y: rect.minY + place.height / 2)
                // The controls emerge from behind the bar, never over it.
                .mask(alignment: .top) {
                    Rectangle().frame(height: look.progress > 0.999 ? nil : max(0, bar.minY))
                }
                .opacity(look.progress > 0.001 ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The panel's black surface, and while it moves the bar's too, as one
/// liquid silhouette (`PanelPop`). At rest the panel is the jet black
/// surface with its rim (`RelayJetBackground`); while it moves the rims fade
/// out, so no edge cuts across the join.
private struct PanelLiquid: View {
    let look: PanelPopPresentation
    let panel: CGRect
    let bar: CGRect
    let radius: CGFloat

    var body: some View {
        let blur = look.blur
        let moving = blur > 0.001
        // The rims show only once the motion has all but settled.
        let rims = 1 - min(blur / 1.5, 1)
        Canvas { context, _ in
            let panelPath = Path(roundedRect: panel, cornerRadius: min(radius, panel.height / 2), style: .continuous)
            let barPath = Path(roundedRect: bar, cornerRadius: GlassTabBar.cornerRadius, style: .continuous)
            guard look.progress > 0.001 else { return }
            context.drawLayer { liquid in
                if moving {
                    // Blur first, then sharpen its alpha into one joined surface.
                    liquid.addFilter(.alphaThreshold(min: 5.0 / 12.0, color: .black))
                    liquid.addFilter(.blur(radius: blur))
                }
                liquid.drawLayer { shapes in
                    if moving { shapes.fill(barPath, with: .color(.black)) }
                    shapes.fill(panelPath, with: .color(.black))
                }
            }
            guard rims > 0 else { return }
            context.opacity = rims
            if moving { context.stroke(barPath.rim, with: Self.rim(in: bar), lineWidth: 1) }
            context.opacity = rims * look.controlsOpacity
            context.stroke(panelPath.rim, with: Self.rim(in: panel), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// `RelayJetBackground.rim` across `rect`.
    private static func rim(in rect: CGRect) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: [.init(color: .white.opacity(0.09), location: 0),
                                         .init(color: .white.opacity(0.02), location: 0.5),
                                         .init(color: .white.opacity(0.05), location: 1)]),
                        startPoint: CGPoint(x: rect.minX, y: rect.minY),
                        endPoint: CGPoint(x: rect.maxX, y: rect.maxY))
    }
}

private extension Path {
    /// A 1 pt stroke along this path lies half outside it; inset it by half
    /// a point, as `strokeBorder` does.
    var rim: Path {
        let box = boundingRect
        guard box.width > 1, box.height > 1 else { return self }
        let scale = CGAffineTransform(translationX: box.midX, y: box.midY)
            .scaledBy(x: (box.width - 1) / box.width, y: (box.height - 1) / box.height)
            .translatedBy(x: -box.midX, y: -box.midY)
        return applying(scale)
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

    /// Where the panel is. Like the wheel's submenu, it starts wholly inside
    /// the bar, so nothing of it ever shows past the bar's edges: a sliver
    /// at its own width across the bar's middle, between the bar's rounded
    /// ends' curves (`seed`). It grows from there up into its place.
    func rect(place: CGRect, bar: CGRect) -> CGRect {
        let seed = Self.seed(place: place, bar: bar)
        let top = seed.minY + (place.minY - seed.minY) * progress
        let bottom = seed.maxY + (place.maxY - seed.maxY) * progress
        return CGRect(x: place.minX, y: top, width: place.width, height: max(0, bottom - top))
    }

    static func seed(place: CGRect, bar: CGRect) -> CGRect {
        let height = max(0, bar.height - 2 * GlassTabBar.cornerRadius)
        return CGRect(x: place.minX, y: bar.midY - height / 2, width: place.width, height: height)
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
