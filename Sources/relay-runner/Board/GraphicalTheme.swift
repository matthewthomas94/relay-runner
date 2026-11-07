import AppKit
import SwiftUI

/// The "RR" Graphical UI theme, ported by hand from the kit's `theme.ts` and
/// per-component dark-mode specifications. Only base-component values live
/// here: surfaces, text, accents, radii and spacing. Typography faces and the
/// particle, skeleton and glyph-loader systems are deliberately untouched.
enum GraphicalTheme {
    // Dark-mode neutrals, 1 (page) to 10 (strongest text).
    static let neutral1NSColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let neutral2NSColor = NSColor(srgbRed: 0x1c / 255, green: 0x20 / 255, blue: 0x26 / 255, alpha: 1)
    static let neutral3NSColor = NSColor(srgbRed: 0x27 / 255, green: 0x2b / 255, blue: 0x31 / 255, alpha: 1)
    static let neutral4NSColor = NSColor(srgbRed: 0x34 / 255, green: 0x39 / 255, blue: 0x3e / 255, alpha: 1)
    static let neutral5NSColor = NSColor(srgbRed: 0x4c / 255, green: 0x51 / 255, blue: 0x57 / 255, alpha: 1)
    static let neutral6NSColor = NSColor(srgbRed: 0x73 / 255, green: 0x78 / 255, blue: 0x7e / 255, alpha: 1)
    static let neutral7NSColor = NSColor(srgbRed: 0x9e / 255, green: 0xa4 / 255, blue: 0xab / 255, alpha: 1)
    static let neutral8NSColor = NSColor(srgbRed: 0xc1 / 255, green: 0xc7 / 255, blue: 0xce / 255, alpha: 1)
    static let neutral9NSColor = NSColor(srgbRed: 0xdf / 255, green: 0xe2 / 255, blue: 0xe7 / 255, alpha: 1)
    static let neutral10NSColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// color-1, the kit's accent: switch-on, slider indicator, focus ring.
    static let accentNSColor = NSColor(srgbRed: 0x2b / 255, green: 0x11 / 255, blue: 0xe8 / 255, alpha: 1)
    /// color-2, the kit's secondary accent.
    static let accent2NSColor = NSColor(srgbRed: 0xf2 / 255, green: 0x70 / 255, blue: 0x0c / 255, alpha: 1)
    static let errorNSColor = NSColor(srgbRed: 0xf4 / 255, green: 0x15 / 255, blue: 0x09 / 255, alpha: 1)

    static let neutral1 = Color(nsColor: neutral1NSColor)
    static let neutral2 = Color(nsColor: neutral2NSColor)
    static let neutral3 = Color(nsColor: neutral3NSColor)
    static let neutral4 = Color(nsColor: neutral4NSColor)
    static let neutral5 = Color(nsColor: neutral5NSColor)
    static let neutral6 = Color(nsColor: neutral6NSColor)
    static let neutral7 = Color(nsColor: neutral7NSColor)
    static let neutral8 = Color(nsColor: neutral8NSColor)
    static let neutral9 = Color(nsColor: neutral9NSColor)
    static let neutral10 = Color(nsColor: neutral10NSColor)
    static let accent = Color(nsColor: accentNSColor)
    static let accent2 = Color(nsColor: accent2NSColor)
    static let error = Color(nsColor: errorNSColor)

    // Radii: xs 8, s 16, m 24, l 32, xl 64. Buttons and inputs use s; popovers,
    // dialogs and tab lists use m; options inside a popover use xs.
    static let radiusXS: CGFloat = 8
    static let radiusS: CGFloat = 16
    static let radiusM: CGFloat = 24
    static let radiusL: CGFloat = 32
    static let radiusXL: CGFloat = 64

    // Spacing: xxs 4, xs 8, s 12, m 16, l 24, xl 32, xxl 48.
    static let spaceXXS: CGFloat = 4
    static let spaceXS: CGFloat = 8
    static let spaceS: CGFloat = 12
    static let spaceM: CGFloat = 16
    static let spaceL: CGFloat = 24
    static let spaceXL: CGFloat = 32
    static let spaceXXL: CGFloat = 48

    /// Border widths and shadows are zero in this theme; surfaces separate by fill alone.
    static let borderWidth: CGFloat = 0

    /// Translucent fills keep the hover and skeleton dots readable through
    /// filled controls, which the kit's solid fills would otherwise hide.
    static let fillThroughDotsOpacity: Double = 0.72
}
