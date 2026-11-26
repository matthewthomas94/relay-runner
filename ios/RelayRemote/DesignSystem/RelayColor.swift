import SwiftUI

/// Colour tokens from the styles board (docs/design/relay-remote-ios/styles-board.jpg),
/// the desktop's Graphical neutrals (`GraphicalTheme`) on the phone.
enum RelayColor {
    /// #000000, the backdrop.
    static let neutral1 = Color(hex: 0x000000)
    /// #0c0f13, panels at 50% over glass.
    static let neutral2 = Color(hex: 0x0c0f13)
    /// #171a1e, secondary buttons at 75% over glass.
    static let neutral3 = Color(hex: 0x171a1e)
    /// #212529, selected items and hairlines.
    static let neutral4 = Color(hex: 0x212529)
    /// #383e46, the focus stroke.
    static let neutral5 = Color(hex: 0x383e46)
    /// #596069, a stopped agent's dot.
    static let neutral6 = Color(hex: 0x596069)
    /// #889099, secondary text.
    static let neutral7 = Color(hex: 0x889099)
    /// #ffffff, text and the primary action.
    static let neutral10 = Color(hex: 0xffffff)
    /// #8070f1, listening accents in controls.
    static let accent2 = Color(hex: 0x8070f1)
    /// #34d399, connected or ready.
    static let success = Color(hex: 0x34d399)
    /// #f41509, failed or destructive. Labels and icons only, never a fill.
    static let error = Color(hex: 0xf41509)
    /// #f5a15b, the R/ mark.
    static let brand = Color(hex: 0xf5a15b)

    /// Status glyph accents, from the desktop notch glyph.
    static let listening = Color(hex: 0xf2700c)
    static let playing = Color(hex: 0x2b11e8)
    /// The idle orb's sparse edge, the desktop card's navy.
    static let orbIdleEdge = Color(hex: 0x11161d)

    /// The fill of a pressed primary button.
    static let primaryPressed = Color(hex: 0xd9d9d9)
}

extension Color {
    /// An sRGB colour from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}
