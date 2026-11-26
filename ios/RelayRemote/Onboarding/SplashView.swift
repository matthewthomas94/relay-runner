import SwiftUI

/// The splash schedule (01–05), a port of the desktop's `OnboardingIntroTimeline`.
/// Pure, so a test can check the beats without playing them.
enum SplashTimeline {
    static let phrases = ["Relay Runner", "First thing’s first", "I need a few permissions"]
    static let brandHold: TimeInterval = 0.70
    static let typingInterval: TimeInterval = 0.029
    static let dotFieldTravel: TimeInterval = 4.00
    /// The brand rests a beat after the glow finishes, as on the desktop.
    static let brandSettle: TimeInterval = 0.36
    static let swap: TimeInterval = RelayMotion.swapDuration
    static let phraseHold: TimeInterval = 1.05
    static let finalHold: TimeInterval = 1.40

    static var typingDuration: TimeInterval { Double(phrases[0].count - 1) * typingInterval }
    static var glowStart: TimeInterval { brandHold + typingDuration }
    static var firstSwapStart: TimeInterval { glowStart + dotFieldTravel + brandSettle }
    static var secondSwapStart: TimeInterval { firstSwapStart + swap * 2 + phraseHold }
    static var duration: TimeInterval { secondSwapStart + swap * 2 + finalHold }

    struct Frame: Equatable {
        var phrase: Int
        /// How many characters of the phrase show.
        var visible: Int
        /// 0 shown, 1 gone: the line-swap fade, blur and scale.
        var hidden: Double
        /// 0...1 rise of the dot field, smoothstepped.
        var glow: Double
        var glowOpacity: Double
        var isComplete: Bool
    }

    static func frame(at elapsed: TimeInterval) -> Frame {
        let t = max(0, elapsed)
        let brand = phrases[0]
        // The epsilon keeps the last character from missing its beat to float rounding.
        let typed = t < brandHold ? 1 : min(brand.count, 1 + Int((t - brandHold) / typingInterval + 1e-9))
        let glow = RelayMotion.smoothstep((t - glowStart) / dotFieldTravel)
        func swapPhase(_ start: TimeInterval) -> Double { RelayMotion.smoothstep((t - start) / swap) }

        if t < firstSwapStart {
            return Frame(phrase: 0, visible: typed, hidden: 0, glow: glow, glowOpacity: 1, isComplete: false)
        }
        if t < firstSwapStart + swap {
            let phase = swapPhase(firstSwapStart)
            return Frame(phrase: 0, visible: brand.count, hidden: phase, glow: 1, glowOpacity: 1 - phase,
                         isComplete: false)
        }
        func line(_ index: Int, start: TimeInterval) -> Frame {
            let into = t - start - swap
            return Frame(phrase: index, visible: phrases[index].count,
                         hidden: 1 - smoothIn(into), glow: 1, glowOpacity: 0, isComplete: false)
        }
        func smoothIn(_ into: TimeInterval) -> Double { RelayMotion.smoothstep(into / swap) }
        if t < secondSwapStart {
            return line(1, start: firstSwapStart)
        }
        if t < secondSwapStart + swap {
            var frame = line(1, start: -swap * 2 - 1)
            frame.hidden = swapPhase(secondSwapStart)
            return frame
        }
        var frame = line(2, start: secondSwapStart)
        frame.isComplete = t >= duration
        return frame
    }
}

/// Splash (01–05): the port of the desktop intro. Tapping skips it; with
/// Reduce Motion on it never shows.
struct SplashView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now
    @State private var finished = false

    var body: some View {
        ZStack {
            RelayColor.neutral1
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: finished)) { timeline in
                let frame = SplashTimeline.frame(at: timeline.date.timeIntervalSince(start))
                ZStack(alignment: .top) {
                    DotField(style: .playback, reveal: frame.glow).opacity(frame.glowOpacity)
                    HeroTextView(hero: Self.hero(frame))
                        .modifier(RelayHiddenModifier(hidden: frame.hidden))
                        .padding(.top, OnboardingHeroLayout<EmptyView, EmptyView>.heroTop)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: finish)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Relay Runner. Continue")
        .accessibilityAction(.default, finish)
        .task {
            if reduceMotion { return finish() }
            try? await Task.sleep(for: .seconds(SplashTimeline.duration))
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }

    private static func hero(_ frame: SplashTimeline.Frame) -> HeroText {
        HeroText(String(SplashTimeline.phrases[frame.phrase].prefix(frame.visible)))
    }
}
