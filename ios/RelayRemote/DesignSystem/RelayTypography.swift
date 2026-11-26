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
