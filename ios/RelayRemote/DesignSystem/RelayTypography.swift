import SwiftUI
import UIKit

/// Bai Jamjuree text styles from the styles board. The fonts ship in
/// `DesignSystem/Fonts` and are registered by `UIAppFonts` in Info.plist.
struct RelayTextStyle: Equatable {
    enum Weight: Equatable {
        case regular, semiBold

        var postScriptName: String {
            switch self {
            case .regular: return "BaiJamjuree-Regular"
            case .semiBold: return "BaiJamjuree-SemiBold"
            }
        }
    }

    let weight: Weight
    let size: CGFloat
    /// The height of one line box, as in Figma.
    let lineHeight: CGFloat

    /// Onboarding hero text, Regular 28/40.
    static let hero = RelayTextStyle(weight: .regular, size: 28, lineHeight: 40)
    static let titleXL = RelayTextStyle(weight: .semiBold, size: 32, lineHeight: 40)
    static let titleL = RelayTextStyle(weight: .semiBold, size: 24, lineHeight: 32)
    static let cardTitle = RelayTextStyle(weight: .semiBold, size: 18, lineHeight: 24)
    static let section = RelayTextStyle(weight: .semiBold, size: 16, lineHeight: 20)
    static let body = RelayTextStyle(weight: .regular, size: 16, lineHeight: 20)
    /// The line under the agent's name in the Agents header (Figma Final 21).
    static let subtitle = RelayTextStyle(weight: .regular, size: 14, lineHeight: 18)
    /// Button and control labels.
    static let control = RelayTextStyle(weight: .regular, size: 16, lineHeight: 20)
    /// Tab bar labels.
    static let tabLabel = RelayTextStyle(weight: .regular, size: 12, lineHeight: 16)
    static let caption = RelayTextStyle(weight: .regular, size: 12, lineHeight: 16)

    var font: Font { .custom(weight.postScriptName, fixedSize: size) }

    var uiFont: UIFont {
        UIFont(name: weight.postScriptName, size: size) ?? .systemFont(ofSize: size)
    }

    /// Extra space between lines so each line box is `lineHeight` tall.
    var lineSpacing: CGFloat { max(0, lineHeight - uiFont.lineHeight) }
}

extension View {
    /// Applies the style's font and line height. The text's frame is a whole
    /// number of line boxes, so a first line sits where Figma puts it.
    func relayTextStyle(_ style: RelayTextStyle) -> some View {
        font(style.font)
            .lineSpacing(style.lineSpacing)
            .padding(.vertical, style.lineSpacing / 2)
    }
}

/// RR-551: the same styles at the reader's Dynamic Type size. Most of the app
/// keeps them fixed, as on the styles board; text a person reads at length, such
/// as a ticket, scales with the Text Size setting relative to Body.
struct RelayScaledTextStyle: ViewModifier {
    let style: RelayTextStyle
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .font(style.font(scaledBy: scale))
            .lineSpacing(style.lineSpacing(scaledBy: scale))
            .padding(.vertical, style.lineSpacing(scaledBy: scale) / 2)
    }
}

extension RelayTextStyle {
    func font(scaledBy scale: CGFloat) -> Font { .custom(weight.postScriptName, fixedSize: size * scale) }

    func lineSpacing(scaledBy scale: CGFloat) -> CGFloat {
        let font = UIFont(name: weight.postScriptName, size: size * scale) ?? .systemFont(ofSize: size * scale)
        return max(0, lineHeight * scale - font.lineHeight)
    }
}

extension View {
    /// `relayTextStyle` that follows Dynamic Type.
    func relayScaledTextStyle(_ style: RelayTextStyle) -> some View {
        modifier(RelayScaledTextStyle(style: style))
    }
}
