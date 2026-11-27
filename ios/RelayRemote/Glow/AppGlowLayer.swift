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
/// A field rises from the bottom edge to its full height as it arrives
/// (500 ms, strong ease-out) and sinks back into the bottom edge as it
/// leaves (340 ms, ease-in), while carrying the desktop's surface transform
/// from `ParticleFieldRenderer` under `VoiceOverlayMotion`: fading, blurring
/// by 12 pt and scaling to 96% about the field's own centre at the base of
/// the screen. Switching between listening and playback crossfades
/// the two fields over 450 ms on the change curve. Reduce Motion keeps only
/// the fades.
struct AppGlowLayer: View {
    let model: AppModel

    private var target: AppGlowState {
        guard let voice = model.voice else { return .none }
        let listening = voice.isListening || voice.activity == .listening || voice.activity == .hearing
        return .resolve(listening: listening, playing: voice.isSpeaking)
    }

    var body: some View {
        StateGlowLayer(target: target)
    }
}

/// The glow for a given state; `AppGlowLayer` feeds it the live voice state.
struct StateGlowLayer: View {
    let target: AppGlowState

    /// The field showing, or leaving when `departure` heads to 1.
    @State private var current = AppGlowState.none
    /// The field fading out under `current` during a switch.
    @State private var previous = AppGlowState.none
    /// 0 shown, 1 gone.
    @State private var departure = 1.0
    /// 0 still showing `previous`, 1 fully `current`.
    @State private var arrival = 1.0
    /// How far up the field has risen: 0 sunk into the bottom edge, 1 full.
    @State private var reveal = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The desktop's surface motion (fade, blur, 96% scale) over its
    /// `VoiceOverlayMotion.travelDuration` smoothstep on the way in.
    static let enter = Animation.timingCurve(0.45, 0, 0.55, 1, duration: 0.2)
    /// Leaving takes as long as the sink, so the falling edge stays visible.
    static let exit = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.34)
    /// The field rises from the bottom edge to its full height, pushing up.
    static let rise = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 0.55)
    /// And pulls back down into the bottom edge as it leaves.
    static let sink = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.34)
    static let crossfade = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.45)
    /// The height of the rising field's soft top edge.
    static let edge: CGFloat = 120

    /// The centre of the field showing, which the desktop scales about.
    private var anchor: UnitPoint {
        let coverage = (current.style ?? previous.style)?.coverage ?? DotFieldStyle.playback.coverage
        return UnitPoint(x: 0.5, y: 1 - coverage / 2)
    }

    /// The tallest field showing, so a crossfade never clips the taller one.
    private var coverage: CGFloat {
        max(current.style?.coverage ?? 0, previous.style?.coverage ?? 0)
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
        // The field rises from the bottom edge behind a soft-topped mask.
        // Only the mask's offset animates, on the GPU, so the dots keep
        // their own frame rate and the edge moves at the display's.
        .mask {
            GeometryReader { geo in
                let height = geo.size.height
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.edge)
                    Color.black.frame(height: height)
                }
                .offset(y: height - (height * coverage + Self.edge) * reveal)
            }
        }
        .opacity(1 - departure)
        .scaleEffect(reduceMotion ? 1 : 1 - (1 - RelayMotion.hiddenScale) * departure, anchor: anchor)
        .blur(radius: reduceMotion ? 0 : RelayMotion.pageBlur * departure)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { transition(to: target) }
        .onChange(of: target) { _, new in transition(to: new) }
    }

    private func transition(to new: AppGlowState) {
        if new == .none {
            guard current != .none else { return }
            withAnimation(reduceMotion ? nil : Self.sink) { reveal = 0 }
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
            if wasHidden {
                departure = 1
                reveal = reduceMotion ? 1 : 0
            }
            withAnimation(Self.enter) { departure = 0 }
            withAnimation(Self.rise) { reveal = 1 }
            return
        }
        guard new != current else {
            withAnimation(Self.enter) { departure = 0 }
            withAnimation(Self.rise) { reveal = 1 }
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
