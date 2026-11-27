import SwiftUI

/// The panel above the tab bar (the Agents dock, the Workspace project tabs)
/// as liquid glass that pours out of the tab bar and back into it (user,
/// 2026-11-28: "look like it's actually coming out of the navigational
/// tabs", like the gooey reference).
///
/// The motion follows Jakub Antalik's liquid-gooey (libraries.dev,
/// github.com/Jakubantalik/Libraries.dev at dafcfc0,
/// `packages/liquid-gooey/src/observer.ts`), with its bounce at 0 (no
/// rebound, user 2026-11-27):
/// - the liquid's centre travels on a quicker spring than its size, so it
///   leaves as a small droplet and swells into place, or shrinks as it pours
///   back in;
/// - while it moves its corners round towards a droplet, gliding back as it
///   settles;
/// - a neck of glass ties it to the tab bar while it rises or sinks, and
///   thins until it snaps;
/// - the panel's contents sharpen and fade in as the liquid reaches its
///   shape, and blur while it changes.
///
/// It is iOS's own glass: the panel, the neck and the bar share one
/// `GlassEffectContainer`, so where they touch they merge.
struct GooeyPanelGlass: View {
    let panel: HostedPanel?
    /// Where the liquid is headed: the panel's place, or tucked inside the bar.
    let target: CGRect
    let bar: CGRect
    let radius: CGFloat
    @State private var liquid = GooeyLiquid()
    @State private var settled = false

    var body: some View {
        TimelineView(.animation(paused: settled && liquid.rests(at: target))) { context in
            let state = liquid.step(to: target, at: context.date, bar: bar, pouringIn: panel == nil)
            ZStack {
                if let neck = state.neck(to: bar) {
                    Color.clear
                        .frame(width: neck.width, height: neck.height)
                        .glassEffect(panel?.glass.liquid ?? RelayGlass.material,
                                     in: RoundedRectangle(cornerRadius: neck.width / 2, style: .continuous))
                        .position(x: neck.midX, y: neck.midY)
                        .allowsHitTesting(false)
                }
                liquidBody(state)
            }
            // The springs place the liquid every frame; the tab switch's own
            // animation must not chase those frames as well.
            .transaction { $0.animation = nil }
            .onChange(of: state.settled) { _, now in settled = now }
        }
        .onChange(of: target) { _, _ in settled = false }
    }

    private func liquidBody(_ state: GooeyLiquid.State) -> some View {
        let shape = RoundedRectangle(cornerRadius: state.radius(base: radius), style: .continuous)
        let shown = state.contentOpacity(toward: target)
        return ZStack {
            if let panel {
                panel.content
                    // Laid out at its own size, so it never reflows; the
                    // liquid around it reveals it as it swells.
                    .frame(width: target.width, height: target.height, alignment: .bottom)
                    .opacity(shown)
                    .blur(radius: (1 - shown) * GooeyLiquid.contentBlur)
                    .id(panel.tab)
                    // The old contents go at once: fading, they were squeezed
                    // into the liquid's next shape for a frame.
                    .transition(.identity)
            }
        }
        .frame(width: state.rect.width, height: state.rect.height)
        .clipShape(shape)
        // Pouring into the bar with no panel, it is untinted: the bar's tint
        // over its own read as a dark band as the two merged.
        .glassEffect(panel?.glass.liquid ?? RelayGlass.material, in: shape)
        .position(x: state.rect.midX, y: state.rect.midY)
    }
}

/// The liquid's springs, stepped once a frame by `GooeyPanelGlass`. A class
/// so stepping it does not invalidate the view.
final class GooeyLiquid {
    /// Coming out of the bar or changing shape, the centre's spring is the
    /// quicker one: the liquid's mass moves first, as a droplet, and swells
    /// into place (liquid-gooey's mass 320 and size 170 stiffness, slowed for
    /// an unhurried pour and critically damped, so nothing rebounds). Pouring
    /// back in, the two swap: the panel draws into a droplet first, which
    /// then drops into the tab.
    static let quick = Spring(stiffness: 210, damping: 2 * sqrt(210))
    static let slow = Spring(stiffness: 105, damping: 2 * sqrt(105))
    /// Pouring in, the centre follows the shrinking panel down closely, so
    /// it melts into the bar instead of hovering as a separate drop.
    static let pour = Spring(stiffness: 160, damping: 2 * sqrt(160))
    /// How much a moving panel's corners round towards a droplet.
    static let roundness: CGFloat = 0.55
    /// How long the droplet rounding and the neck take to fade once the
    /// motion stops (liquid-gooey's peak-hold envelope).
    static let envelopeDecay: Double = 0.3
    /// The neck: how far it reaches across the gap from the bar, and how wide
    /// it is at most, as a share of the narrower of the two shapes.
    static let neckReach: CGFloat = 64
    static let neckWidth: CGFloat = 0.7
    /// liquid-gooey's content blur while the liquid moves.
    static let contentBlur: CGFloat = 7

    struct Spring {
        let stiffness: Double
        let damping: Double

        /// One semi-implicit Euler step towards `target`.
        func step(_ x: inout Double, _ v: inout Double, to target: Double, dt: Double) {
            v += (-stiffness * (x - target) - damping * v) * dt
            x += v * dt
        }
    }

    struct State {
        var rect: CGRect
        /// Rises with motion at once and fades out over `envelopeDecay`.
        var motion: Double
        /// How fast the liquid's bottom edge moves up or down, held like `motion`.
        var verticalMotion: Double
        /// The liquid is pouring into the bar or has just come out of it; only
        /// then does a neck join the two.
        var pouring: Bool
        var settled: Bool

        func radius(base: CGFloat) -> CGFloat {
            let droplet = min(rect.width, rect.height) / 2
            return base + max(0, droplet - base) * GooeyLiquid.roundness * CGFloat(motion)
        }

        /// 1 once the liquid has its target's shape, fading with how far off it is.
        func contentOpacity(toward target: CGRect) -> Double {
            guard target.width > 0, target.height > 0 else { return 0 }
            let off = max(abs(rect.width - target.width) / target.width,
                          abs(rect.height - target.height) / target.height,
                          abs(rect.midY - target.midY) / target.height * 0.5)
            return 1 - GooeyLiquid.smoothstep(0.05, 0.4, Double(off))
        }

        /// The glass joining the liquid to the bar while it rises out of it or
        /// sinks into it: widest as it leaves, thinning as the gap opens until
        /// it snaps. None at rest, so a resting panel stays apart from the bar.
        func neck(to bar: CGRect) -> CGRect? {
            let gap = bar.minY - rect.maxY
            guard pouring, gap > 0, gap < GooeyLiquid.neckReach, verticalMotion > 0.02 else { return nil }
            let open = 1 - GooeyLiquid.smoothstep(0, Double(GooeyLiquid.neckReach), Double(gap))
            let width = min(rect.width, bar.width) * GooeyLiquid.neckWidth * CGFloat(open * verticalMotion)
            guard width > 3 else { return nil }
            let overlap: CGFloat = 10
            let x = min(max(rect.midX, bar.minX + width / 2), bar.maxX - width / 2)
            return CGRect(x: x - width / 2, y: rect.maxY - overlap,
                          width: width, height: gap + 2 * overlap)
        }
    }

    private var cx = 0.0, cy = 0.0, w = 0.0, h = 0.0
    private var vcx = 0.0, vcy = 0.0, vw = 0.0, vh = 0.0
    private var motion = 0.0, verticalMotion = 0.0
    /// Set while the liquid is inside the bar; cleared once it settles outside it.
    private var leftBar = false
    private var last: Date?
    private var started = false

    /// At `target` with nothing moving.
    func rests(at target: CGRect) -> Bool {
        started && abs(cx - target.midX) < 0.25 && abs(cy - target.midY) < 0.25
            && abs(w - target.width) < 0.25 && abs(h - target.height) < 0.25 && motion < 0.01
    }

    func step(to target: CGRect, at now: Date, bar: CGRect, pouringIn: Bool = false) -> State {
        if !started {
            // The first frame: already in place, as the page it belongs to.
            (cx, cy, w, h) = (target.midX, target.midY, target.width, target.height)
            started = true
            last = now
        }
        let elapsed = min(max(now.timeIntervalSince(last ?? now), 0), 1.0 / 20)
        last = now
        // Small fixed steps keep the stiff centre spring stable at any frame rate.
        let steps = max(1, Int((elapsed / (1.0 / 240)).rounded(.up)))
        let dt = elapsed / Double(steps)
        let centre = pouringIn ? Self.pour : Self.quick
        let size = pouringIn ? Self.quick : Self.slow
        for _ in 0..<steps {
            centre.step(&cx, &vcx, to: target.midX, dt: dt)
            centre.step(&cy, &vcy, to: target.midY, dt: dt)
            size.step(&w, &vw, to: target.width, dt: dt)
            size.step(&h, &vh, to: target.height, dt: dt)
        }
        let speed = abs(vcx) + abs(vcy) + abs(vw) + abs(vh)
        let bottomSpeed = abs(vcy + vh / 2)
        let fade = elapsed / Self.envelopeDecay
        motion = max(Self.smoothstep(4, 400, speed), motion - fade)
        verticalMotion = max(Self.smoothstep(2, 140, bottomSpeed), verticalMotion - fade)
        if rests(at: target) || (abs(cx - target.midX) < 0.25 && abs(cy - target.midY) < 0.25
                                 && abs(w - target.width) < 0.25 && abs(h - target.height) < 0.25
                                 && speed < 1) {
            (cx, cy, w, h) = (target.midX, target.midY, target.width, target.height)
            (vcx, vcy, vw, vh) = (0, 0, 0, 0)
        }
        let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: max(w, 0), height: max(h, 0))
        let settled = rests(at: target) && verticalMotion < 0.01
        if rect.maxY > bar.minY + 2 { leftBar = true } else if settled { leftBar = false }
        return State(rect: rect, motion: motion, verticalMotion: verticalMotion,
                     pouring: pouringIn || leftBar, settled: settled)
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
