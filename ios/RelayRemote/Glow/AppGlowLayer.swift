import SwiftUI

/// Which state glow shows behind the app. Listening wins over playback.
enum AppGlowState: Equatable {
    case none
    case listening
    case playing

    static func resolve(listening: Bool, playing: Bool) -> AppGlowState {
        if listening { return .listening }
        return playing ? .playing : .none
    }

    var style: DotFieldStyle? {
        switch self {
        case .none: nil
        case .listening: .listening
        case .playing: .playback
        }
    }
}

/// The app-wide state glows, behind every screen including the tab bar,
/// dock and text box: the listening field while the user talks and the
/// playback field while a reply plays (`DotField`). One view at the app root,
/// driven by the voice state.
///
/// It moves exactly like the desktop's `ParticleFieldRenderer`: a field
/// arrives and departs as a surface (fade, 96% scale, 12 pt blur; in on the
/// desktop enter curve over 360 ms, out on the exit curve over 160 ms), and
/// switching between listening and playback crossfades the two fields over
/// 450 ms on the change curve. Reduce Motion keeps only the fades.
struct AppGlowLayer: View {
    let model: AppModel

    /// The field showing, or leaving when `departure` heads to 1.
    @State private var current = AppGlowState.none
    /// The field fading out under `current` during a switch.
    @State private var previous = AppGlowState.none
    /// 0 shown, 1 gone.
    @State private var departure = 1.0
    /// 0 still showing `previous`, 1 fully `current`.
    @State private var arrival = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let enter = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.36)
    static let exit = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.16)
    static let crossfade = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.45)

    private var target: AppGlowState {
        guard let voice = model.voice else { return .none }
        let listening = voice.isListening || voice.activity == .listening || voice.activity == .hearing
        return .resolve(listening: listening, playing: voice.isSpeaking)
    }

    var body: some View {
        ZStack {
            if let style = previous.style {
                DotField(style: style).opacity(1 - arrival)
            }
            if let style = current.style {
                DotField(style: style).opacity(arrival)
            }
        }
        .opacity(1 - departure)
        .scaleEffect(reduceMotion ? 1 : 1 - (1 - RelayMotion.hiddenScale) * departure)
        .blur(radius: reduceMotion ? 0 : RelayMotion.pageBlur * departure)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { transition(to: target) }
        .onChange(of: target) { _, new in transition(to: new) }
    }

    private func transition(to new: AppGlowState) {
        if new == .none {
            guard current != .none else { return }
            withAnimation(Self.exit) { departure = 1 } completion: {
                // Only clear if nothing new arrived meanwhile.
                if departure == 1 { current = .none; previous = .none }
            }
            return
        }
        if current == .none || departure > 0.5 {
            // Arriving from nothing, or taking over a field that was leaving.
            let wasHidden = current == .none
            previous = .none
            current = new
            arrival = 1
            if wasHidden { departure = 1 }
            withAnimation(Self.enter) { departure = 0 }
            return
        }
        guard new != current else {
            withAnimation(Self.enter) { departure = 0 }
            return
        }
        // Listening <-> playback: crossfade the fields.
        previous = current
        current = new
        arrival = 0
        withAnimation(Self.crossfade) { arrival = 1 }
        withAnimation(Self.enter) { departure = 0 }
    }
}
