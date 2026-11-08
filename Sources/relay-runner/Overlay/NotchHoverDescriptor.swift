import SwiftUI

/// Hovered controls name themselves in the notch instead of in a tooltip
/// beside the pointer. A descriptor is one to three words: longer copy is
/// not shown at all, so the notch never fills with a sentence.
enum NotchHoverDescriptor {
    static let maximumWords = 3
    static let delay: TimeInterval = 0.35

    /// Installed by the app once the notch controller exists.
    @MainActor static var presenter: ((String?) -> Void)?
    /// Hovered controls, outermost first: a row, then a button inside it.
    @MainActor private static var shown: [(owner: UUID, label: String)] = []

    /// Collapses whitespace. Returns nil for empty copy or more than three words.
    static func normalized(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= maximumWords else { return nil }
        return words.joined(separator: " ")
    }

    static func isValid(_ text: String) -> Bool {
        normalized(text) != nil
    }

    @MainActor static func show(_ text: String, owner: UUID) {
        guard let label = normalized(text) else {
            hide(owner: owner)
            return
        }
        if let index = shown.firstIndex(where: { $0.owner == owner }) {
            // Copy changing in place (a toggle) keeps its depth.
            shown[index].label = label
        } else {
            shown.append((owner, label))
        }
        presenter?(shown.last?.label)
    }

    /// Leaving a control reveals the one it sat inside, if any, so a row's
    /// descriptor returns after the pointer leaves a button on that row.
    @MainActor static func hide(owner: UUID) {
        guard let index = shown.firstIndex(where: { $0.owner == owner }) else { return }
        shown.remove(at: index)
        presenter?(shown.last?.label)
    }
}

private struct NotchHintModifier: ViewModifier {
    let text: String
    @State private var owner = UUID()
    @State private var pending: DispatchWorkItem?
    @State private var isShowing = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                pending?.cancel()
                pending = nil
                guard hovering, !text.isEmpty else {
                    hide()
                    return
                }
                let show = DispatchWorkItem {
                    isShowing = true
                    NotchHoverDescriptor.show(text, owner: owner)
                }
                pending = show
                DispatchQueue.main.asyncAfter(deadline: .now() + NotchHoverDescriptor.delay, execute: show)
            }
            // A control whose copy changes while hovered (a toggle, a slider) updates in place.
            .onChange(of: text) { _, newText in
                guard isShowing else { return }
                NotchHoverDescriptor.show(newText, owner: owner)
            }
            .onDisappear {
                pending?.cancel()
                pending = nil
                hide()
            }
            .accessibilityHint(text)
    }

    private func hide() {
        guard isShowing else { return }
        isShowing = false
        NotchHoverDescriptor.hide(owner: owner)
    }
}

extension View {
    /// Names this control in the notch while hovered. One to three words.
    func notchHint(_ text: String) -> some View {
        modifier(NotchHintModifier(text: text))
    }
}
