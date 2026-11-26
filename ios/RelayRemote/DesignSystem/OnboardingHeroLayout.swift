import SwiftUI

/// Onboarding hero copy: lines broken by hand (so no word wraps onto a line
/// of its own), each a run of text and inline chips. The last line ends with
/// the pulsing " /" cursor, which the layout adds.
struct HeroText: Hashable, ExpressibleByStringLiteral {
    enum Segment: Hashable {
        case text(String)
        /// A small control-like chip, such as "[mic Hold to talk]" or "[■]".
        case chip(icon: LucideIcon?, label: String?, style: HeroChip.Style)
    }

    var lines: [[Segment]]

    init(lines: [[Segment]]) {
        self.lines = lines
    }

    /// Plain text; "\n" breaks lines.
    init(_ text: String) {
        lines = text.components(separatedBy: "\n").map { [.text($0)] }
    }

    init(stringLiteral value: String) {
        self.init(value)
    }
}

/// The action under the hero: full width, 52 pt tall.
struct OnboardingAction {
    let title: String
    var icon: LucideIcon?
    var role: RelayButtonStyle.Role = .primary
    let perform: () -> Void
}

/// The layout every onboarding screen (splash, permissions, pairing,
/// tutorial) uses:
/// - the hero text's first line sits at y 300 and the text grows downward;
///   it is never re-centred when the copy changes,
/// - "Skip →" top right when the screen allows skipping,
/// - an optional accessory below the hero (a viewfinder, the Mac card),
/// - a full-width 52 pt action with 16 pt side margins and 40 pt below it,
///   with any secondary actions directly above it.
/// Copy changes swap with the line-swap transition.
struct OnboardingHeroLayout<Accessory: View, Secondary: View>: View {
    let hero: HeroText
    var onSkip: (() -> Void)?
    var action: OnboardingAction?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var secondary: Secondary

    /// The first line's top edge, in screen points.
    static var heroTop: CGFloat { 300 }
    static var actionBottom: CGFloat { 40 }

    init(hero: HeroText, onSkip: (() -> Void)? = nil, action: OnboardingAction? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder secondary: () -> Secondary = { EmptyView() }) {
        self.hero = hero
        self.onSkip = onSkip
        self.action = action
        self.accessory = accessory()
        self.secondary = secondary()
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Color.clear.frame(height: Self.heroTop)
                RelaySwap(hero) { HeroTextView(hero: $0) }
                accessory.padding(.top, 24)
                Spacer(minLength: 0)
            }
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                secondary
                if let action {
                    Button(action: action.perform) { RelayButtonLabel(action.title, icon: action.icon) }
                        .buttonStyle(RelayButtonStyle(role: action.role, height: RelayMetrics.largeControlHeight,
                                                      fullWidth: true))
                }
            }
            .padding(.horizontal, RelayMetrics.screenMargin)
            .padding(.bottom, Self.actionBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            if let onSkip {
                Button(action: onSkip) {
                    Text("Skip →")
                        .relayTextStyle(.body)
                        .foregroundStyle(RelayColor.neutral7)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip")
                .padding(.top, 1)
                .padding(.trailing, 20)
            }
        }
        .background(RelayColor.neutral1)
    }
}

/// The hero lines, centred, with the cursor after the last one.
struct HeroTextView: View {
    let hero: HeroText

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(hero.lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(line.enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .text(let text):
                            Text(text).relayTextStyle(.hero)
                        case .chip(let icon, let label, let style):
                            HeroChip(icon: icon, label: label, style: style).padding(.horizontal, 6)
                        }
                    }
                    if index == hero.lines.count - 1 { HeroCursor() }
                }
                .fixedSize()
                .frame(height: RelayTextStyle.hero.lineHeight)
            }
        }
        .foregroundStyle(RelayColor.neutral10)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The " /" cursor: pulses between 50% and 100% opacity on a 0.8 s cycle.
struct HeroCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let period: TimeInterval = 0.8

    /// The desktop's `OnboardingCursorBlink`: an eased cosine from 100% down
    /// to 50% and back. Held at 82% with Reduce Motion.
    static func opacity(at elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0.82 }
        let progress = max(0, elapsed).truncatingRemainder(dividingBy: period) / period
        let wave = 0.5 + 0.5 * cos(progress * .pi * 2)
        let eased = wave < 0.5 ? 2 * wave * wave : 1 - pow(-2 * wave + 2, 2) / 2
        return 0.5 + 0.5 * eased
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Text(" /")
                .relayTextStyle(.hero)
                .opacity(Self.opacity(at: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion))
        }
        .accessibilityHidden(true)
    }
}

/// A small button-like chip inside hero text, styled like the real control.
struct HeroChip: View {
    enum Style: Hashable {
        /// The lit control: light fill, dark label.
        case primary
        /// A glass control.
        case secondary
    }

    let icon: LucideIcon?
    let label: String?
    var style: Style = .secondary

    static let height: CGFloat = 36

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 8) {
            if let icon { LucideImage(icon, size: 18) }
            if let label { Text(label).relayTextStyle(.control) }
        }
        .foregroundStyle(style == .primary ? RelayColor.neutral1 : RelayColor.neutral10)
        .padding(.horizontal, label == nil ? 9 : 14)
        .frame(height: Self.height)
        .background {
            if style == .primary {
                shape.fill(RelayColor.primaryPressed)
            } else {
                RelayGlassBackground(glass: .control, shape: shape)
            }
        }
    }
}
