import UIKit

/// Haptics fired straight from a touch handler. SwiftUI's `sensoryFeedback`
/// only plays when it sees its trigger change between renders, so a quick tap
/// that presses and releases within one frame can go silent; these play on
/// every call. The generators are prepared ahead so the first tap is not late.
@MainActor
enum RelayHaptics {
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let light = UIImpactFeedbackGenerator(style: .light)

    /// A finger landing on a primary control.
    static func press() {
        medium.impactOccurred()
        medium.prepare()
    }

    /// The finger lifting.
    static func release() {
        light.impactOccurred()
        light.prepare()
    }

    static func prepare() {
        medium.prepare()
        light.prepare()
    }
}
