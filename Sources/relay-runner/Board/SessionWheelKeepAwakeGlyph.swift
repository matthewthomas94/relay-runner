import SwiftUI

/// The wheel's Keep Awake icon. A filled bolt is white when off and the active tray
/// orange when on, so switching between them only retints it. Pending, approval, and
/// failure states swap to their own symbols: the outgoing symbol contracts and fades,
/// then the new one expands in, within one change duration. A change mid-swap retargets
/// from wherever the icon is, and nothing animates while the state rests.
struct SessionWheelKeepAwakeGlyph: View {
    let state: KeepAwakeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Look: Equatable {
        enum Tint: Equatable { case off, on, neutral, alert }

        let symbol: String
        let tint: Tint

        init(_ state: KeepAwakeState) {
            switch state {
            case .off: (symbol, tint) = ("bolt.fill", .off)
            case .on: (symbol, tint) = ("bolt.fill", .on)
            case .enabling, .disabling: (symbol, tint) = ("hourglass", .neutral)
            case .awaitingApproval: (symbol, tint) = ("hand.raised.fill", .neutral)
            case .failed: (symbol, tint) = ("exclamationmark.triangle", .neutral)
            case .restoreNeeded: (symbol, tint) = ("exclamationmark.triangle.fill", .alert)
            }
        }

        var color: Color {
            switch tint {
            case .off: return .white
            case .on: return ProgramBoardStyle.activeTrayOrange
            case .neutral: return ProgramBoardStyle.primaryText
            case .alert: return ProgramBoardStyle.red
            }
        }

        /// Off and on share the bolt, so only the colour changes between them.
        func swapsSymbol(to next: Look) -> Bool { symbol != next.symbol }
    }

    /// One change duration split between the exit and the entrance, so a swap never overlaps.
    static let exitDuration = RelayMotion.changeDuration * 0.4
    static let enterDuration = RelayMotion.changeDuration * 0.6
    /// Small enough that a 9-point symbol stays recognisable mid-swap.
    static let hiddenStyle = RelayMotion.Style(hiddenScale: 0.7, blurRadius: 1.5)

    static func tintAnimation(reduceMotion: Bool) -> Animation { RelayMotion.change(reduceMotion: reduceMotion) }

    /// Reduce Motion keeps the sequential fade and drops scale and blur.
    static func swap(reduceMotion: Bool) -> AnyTransition {
        let hidden = SessionWheelKeepAwakeGlyphEffect(hidden: true, reduceMotion: reduceMotion)
        let shown = SessionWheelKeepAwakeGlyphEffect(hidden: false, reduceMotion: reduceMotion)
        return .asymmetric(
            insertion: AnyTransition.modifier(active: hidden, identity: shown)
                .animation(RelayMotion.enterCurve.animation(duration: enterDuration).delay(exitDuration)),
            removal: AnyTransition.modifier(active: hidden, identity: shown)
                .animation(RelayMotion.exitCurve.animation(duration: exitDuration))
        )
    }

    var body: some View {
        let look = Look(state)
        ZStack {
            Image(systemName: look.symbol)
                .foregroundStyle(look.color)
                .id(look.symbol)
                .transition(Self.swap(reduceMotion: reduceMotion))
        }
        .animation(Self.tintAnimation(reduceMotion: reduceMotion), value: look)
        .accessibilityHidden(true)
    }
}

struct SessionWheelKeepAwakeGlyphEffect: ViewModifier {
    let hidden: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let style = SessionWheelKeepAwakeGlyph.hiddenStyle
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: style.blur(hidden: hidden, reduceMotion: reduceMotion))
            .scaleEffect(style.scale(hidden: hidden, reduceMotion: reduceMotion))
    }
}
