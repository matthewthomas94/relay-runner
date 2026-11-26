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
