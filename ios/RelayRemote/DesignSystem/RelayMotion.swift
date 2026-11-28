import SwiftUI

/// The motion language shared with the desktop's RelayMotion kit: blur and
/// fade with a small scale, eased, and swaps that never overlap (the old
/// content leaves before the new arrives).
enum RelayMotion {
    /// One half of a line swap: 0.24 s.
    static let swapDuration: TimeInterval = 0.24
    /// Hidden content blurs to 6 pt and scales to 96%.
    static let hiddenBlur: CGFloat = 6
    static let hiddenScale: CGFloat = 0.96

    static let swap = Animation.easeInOut(duration: swapDuration)
    static let change = Animation.easeInOut(duration: 0.3)

    // The interaction curves (Emil Kowalski's strong ease-out and ease-in-out;
    // the built-in easings are too weak). UI motion stays under 300 ms.

    /// Press feedback: 160 ms strong ease-out.
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    /// Something arriving or leaving (a message, a banner, a swapped
    /// control): 240 ms strong ease-out.
    static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
    /// Something moving on screen (a selection sliding between tabs, a box
    /// growing): a critically damped spring, so a quick second tap retargets
    /// from where it is instead of restarting.
    static let move = Animation.spring(duration: 0.3, bounce: 0)
    /// How far a pressed control shrinks.
    static let pressedScale: CGFloat = 0.97

    /// Smoothstep on 0...1.
    static func smoothstep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Fade, blur and scale by `hidden` (0 shown, 1 gone).
struct RelayHiddenModifier: ViewModifier {
    let hidden: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(1 - hidden)
            .blur(radius: RelayMotion.hiddenBlur * hidden)
            .scaleEffect(1 - (1 - RelayMotion.hiddenScale) * hidden)
    }
}

extension AnyTransition {
    /// A surface arriving or leaving: fade, blur to 6 pt, scale to 96%.
    static var relaySurface: AnyTransition {
        .modifier(active: RelayHiddenModifier(hidden: 1), identity: RelayHiddenModifier(hidden: 0))
    }
}

/// Shows `content(value)` and swaps it when `value` changes: the old content
/// fades out over 0.24 s (blurring to 6 pt, scaling to 96%), then the new
/// content fades in the same way. With Reduce Motion it swaps with a plain fade.
struct RelaySwap<Value: Equatable, Content: View>: View {
    let value: Value
    @ViewBuilder let content: (Value) -> Content

    @State private var shown: Value
    @State private var hidden: CGFloat = 0
    @State private var generation = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ value: Value, @ViewBuilder content: @escaping (Value) -> Content) {
        self.value = value
        self.content = content
        _shown = State(initialValue: value)
    }

    var body: some View {
        content(shown)
            .modifier(reduceMotion ? RelayHiddenModifier(hidden: 0) : RelayHiddenModifier(hidden: hidden))
            .opacity(reduceMotion ? Double(1 - hidden) : 1)
            .onChange(of: value) { _, newValue in swap(to: newValue) }
    }

    private func swap(to newValue: Value) {
        generation += 1
        let current = generation
        withAnimation(RelayMotion.swap) { hidden = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + RelayMotion.swapDuration) {
            guard current == generation else { return }
            shown = newValue
            withAnimation(RelayMotion.swap) { hidden = 0 }
        }
    }
}

extension View {
    /// Press feedback for anything tappable: shrinks to 97% while pressed and
    /// springs back on release, with a light haptic tap the moment the finger
    /// lands. Scale only, so Reduce Motion keeps it (it is feedback, not
    /// movement across the screen).
    func relayPressed(_ pressed: Bool) -> some View {
        scaleEffect(pressed ? RelayMotion.pressedScale : 1)
            .animation(RelayMotion.press, value: pressed)
            // Straight from UIKit: `sensoryFeedback` can be late or silent on a quick tap.
            .onChange(of: pressed) { _, isPressed in if isPressed { RelayHaptics.tap() } }
    }
}

extension AnyTransition {
    /// A message or row arriving: rises 8 pt and fades in with a hint of
    /// scale; leaves with a quicker fade.
    static var relayRise: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.98, anchor: .bottom)),
            removal: .opacity.animation(.easeOut(duration: 0.15))
        )
    }

    /// A control swapping for another in the same place (Replay, Play and
    /// Cancel, the talk button's icon): the desktop's control swap, shortened
    /// for something pressed many times a day. The old control fades out,
    /// blurring to 6 pt and shrinking to 96%, in 100 ms on the exit curve;
    /// the new one arrives the same way as it goes, 160 ms on the strong
    /// ease-out, starting when the old one has gone. They never overlap, and
    /// the swap is over in 260 ms. Reduce Motion keeps only the fades.
    static var relayControlSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: RelayControlSwapModifier(hidden: true),
                                 identity: RelayControlSwapModifier(hidden: false))
                .animation(RelayMotion.controlEnter),
            removal: .modifier(active: RelayControlSwapModifier(hidden: true),
                               identity: RelayControlSwapModifier(hidden: false))
                .animation(RelayMotion.controlExit))
    }
}

extension RelayMotion {
    /// A control leaving its place for another: 100 ms on the exit curve.
    static let controlExitDuration: TimeInterval = 0.1
    static let controlExit = Animation.timingCurve(0.4, 0, 1, 1, duration: controlExitDuration)
    /// The control taking its place, once the old one has gone.
    static let controlEnter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16).delay(controlExitDuration)
}

struct RelayControlSwapModifier: ViewModifier {
    let hidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let move = hidden && !reduceMotion
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: move ? RelayMotion.hiddenBlur : 0)
            .scaleEffect(move ? RelayMotion.hiddenScale : 1)
    }
}

/// A `ButtonStyle` wrapper that adds `relayPressed` to any label.
struct RelayPressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.relayPressed(configuration.isPressed)
    }
}

extension ButtonStyle where Self == RelayPressableStyle {
    /// A plain button with press feedback.
    static var relayPlain: RelayPressableStyle { RelayPressableStyle() }
}

// MARK: - Page transitions (the desktop's `relayReplacing(.surface)`)

extension RelayMotion {
    /// The desktop's exit: 160 ms on (0.4, 0, 1, 1), so the page leaves quickly.
    static let pageExitDuration: TimeInterval = 0.16
    static let pageExit = Animation.timingCurve(0.4, 0, 1, 1, duration: pageExitDuration)
    /// The new page arrives only after the old one has gone, plus a 75 ms beat.
    static let pageGap: TimeInterval = 0.075
    /// The desktop's large entrance: a 360 ms spring with a little bounce.
    static let pageEnter = Animation.spring(duration: 0.36, bounce: 0.2).delay(pageExitDuration + pageGap)
    /// Pages blur to 12 pt and shrink to 96% while hidden, like desktop surfaces.
    static let pageBlur: CGFloat = 12
    /// How far a page drifts sideways, toward where it went in the tab order.
    static let pageTravel: CGFloat = 14
}

/// A page's hidden state: faded, blurred, slightly smaller and shifted by
/// `travel` points. Reduce Motion keeps only the fade.
struct RelayPageEffect: ViewModifier {
    let hidden: Bool
    let travel: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let move = hidden && !reduceMotion
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: move ? RelayMotion.pageBlur : 0)
            .scaleEffect(move ? RelayMotion.hiddenScale : 1)
            .offset(x: move ? travel : 0)
    }
}

extension AnyTransition {
    /// Whole pages replacing each other, ported from the desktop: the old page
    /// contracts, blurs and fades out fast; after a short beat the new one
    /// springs in from the same blur. `direction` (+1 forward, -1 back, 0 none)
    /// slides them a few points the way the user moved, so the tab bar and
    /// the page agree about where things are.
    static func relayPage(direction: CGFloat = 0) -> AnyTransition {
        let travel = RelayMotion.pageTravel * direction
        return .asymmetric(
            insertion: .modifier(active: RelayPageEffect(hidden: true, travel: travel),
                                 identity: RelayPageEffect(hidden: false, travel: 0))
                .animation(RelayMotion.pageEnter),
            removal: .modifier(active: RelayPageEffect(hidden: true, travel: -travel),
                               identity: RelayPageEffect(hidden: false, travel: 0))
                .animation(RelayMotion.pageExit)
        )
    }
}

// MARK: - Onboarding stages

extension AnyTransition {
    /// Onboarding stages (splash, permissions, pairing, tutorial) all put the
    /// hero line in the same place, so moving between them is a line swap,
    /// not a page change: the old stage fades out with a light blur on the
    /// exit curve, then after the same short beat the new one fades in on the
    /// strong ease-out. Nothing scales, slides or bounces, so the line stays
    /// exactly where the eye is.
    static var relayStageSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: RelayStageEffect(hidden: true), identity: RelayStageEffect(hidden: false))
                .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
                    .delay(RelayMotion.pageExitDuration + RelayMotion.pageGap)),
            removal: .modifier(active: RelayStageEffect(hidden: true), identity: RelayStageEffect(hidden: false))
                .animation(RelayMotion.pageExit)
        )
    }
}

/// An onboarding stage's hidden state: faded and blurred by 6 pt. Reduce
/// Motion keeps only the fade.
struct RelayStageEffect: ViewModifier {
    let hidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden && !reduceMotion ? 6 : 0)
    }
}

// MARK: - Tab switches

extension RelayMotion {
    /// A beat between one thing leaving and the next arriving (an agent's
    /// chat swapping, a panel pushing out of the tab bar).
    static let tabGap: TimeInterval = 0.075
}

struct RelayArrivingModifier: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content.opacity(hidden ? 0 : 1).blur(radius: hidden ? 4 : 0).offset(y: hidden ? 6 : 0)
    }
}
