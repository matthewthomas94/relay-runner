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
/// driven by the voice state; fades in and out over 0.3 s.
struct AppGlowLayer: View {
    let model: AppModel

    @State private var shown = AppGlowState.none
    @State private var reveal = 0.0

    private var target: AppGlowState {
        guard let voice = model.voice else { return .none }
        let listening = voice.isListening || voice.activity == .listening || voice.activity == .hearing
        return .resolve(listening: listening, playing: voice.isSpeaking)
    }

    var body: some View {
        ZStack {
            if let style = shown.style {
                DotField(style: style, reveal: reveal)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: target) { _, new in transition(to: new) }
    }

    private func transition(to new: AppGlowState) {
        if new == .none {
            withAnimation(.easeOut(duration: 0.3)) { reveal = 0 }
            return
        }
        if shown != new { shown = new; reveal = 0 }
        withAnimation(.easeOut(duration: 0.3)) { reveal = 1 }
    }
}
