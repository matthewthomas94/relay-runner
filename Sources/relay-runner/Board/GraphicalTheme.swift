import AppKit
import SwiftUI

/// The "RR" Graphical UI theme, ported by hand from the kit's `theme.ts` and
/// per-component dark-mode specifications. Only base-component values live
/// here: surfaces, text, accents, radii and spacing. Typography faces and the
/// particle, skeleton and glyph-loader systems are deliberately untouched.
enum GraphicalTheme {
    // Dark-mode neutrals, 1 (page) to 10 (strongest text), from kit revision 1fooxs04xnek.
    static let neutral1NSColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let neutral2NSColor = NSColor(srgbRed: 0x0c / 255, green: 0x0f / 255, blue: 0x13 / 255, alpha: 1)
    static let neutral3NSColor = NSColor(srgbRed: 0x17 / 255, green: 0x1a / 255, blue: 0x1e / 255, alpha: 1)
    static let neutral4NSColor = NSColor(srgbRed: 0x21 / 255, green: 0x25 / 255, blue: 0x29 / 255, alpha: 1)
    static let neutral5NSColor = NSColor(srgbRed: 0x38 / 255, green: 0x3e / 255, blue: 0x46 / 255, alpha: 1)
    static let neutral6NSColor = NSColor(srgbRed: 0x59 / 255, green: 0x60 / 255, blue: 0x69 / 255, alpha: 1)
    static let neutral7NSColor = NSColor(srgbRed: 0x88 / 255, green: 0x90 / 255, blue: 0x99 / 255, alpha: 1)
    static let neutral8NSColor = NSColor(srgbRed: 0xa7 / 255, green: 0xb0 / 255, blue: 0xba / 255, alpha: 1)
    static let neutral9NSColor = NSColor(srgbRed: 0xc5 / 255, green: 0xca / 255, blue: 0xd3 / 255, alpha: 1)
    static let neutral10NSColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// color-1, the kit's accent.
    static let accentNSColor = NSColor(srgbRed: 0x2b / 255, green: 0x11 / 255, blue: 0xe8 / 255, alpha: 1)
    /// color-2 to color-4, the kit's supporting palette.
    static let accent2NSColor = NSColor(srgbRed: 0x80 / 255, green: 0x70 / 255, blue: 0xf1 / 255, alpha: 1)
    static let accent3NSColor = NSColor(srgbRed: 0xbf / 255, green: 0xb8 / 255, blue: 0xf8 / 255, alpha: 1)
    static let accent4NSColor = NSColor(srgbRed: 0xea / 255, green: 0xe7 / 255, blue: 0xfd / 255, alpha: 1)
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
    static let accent3 = Color(nsColor: accent3NSColor)
    static let accent4 = Color(nsColor: accent4NSColor)
    static let error = Color(nsColor: errorNSColor)

    // Radii (kit revision rb2u57i23dk0): xs 8, s 12, m 16, l 24, xl 48. Buttons
    // and inputs use s; popovers, dialogs and tab lists use m; options inside a
    // popover use xs.
    static let radiusXS: CGFloat = 8
    static let radiusS: CGFloat = 12
    static let radiusM: CGFloat = 16
    static let radiusL: CGFloat = 24
    static let radiusXL: CGFloat = 48

    // Type scale sizes (xxs to xxl) and their line heights. Faces stay the app's own.
    static let textXXS: CGFloat = 8
    static let textXS: CGFloat = 12
    static let textS: CGFloat = 16
    static let textM: CGFloat = 20
    static let textL: CGFloat = 24
    static let textXL: CGFloat = 32
    static let textXXL: CGFloat = 40
    static let lineHeightXXS: CGFloat = 16
    static let lineHeightXS: CGFloat = 20
    static let lineHeightS: CGFloat = 20
    static let lineHeightM: CGFloat = 24
    static let lineHeightL: CGFloat = 27.5
    static let lineHeightXL: CGFloat = 36

    /// The kit's control height: 8 points above and below a 20-point text line.
    static let controlHeight: CGFloat = 36

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

    /// The kit's focus ring: neutral-10 at its transparent step (20%), 2 points wide.
    static let focusRing = neutral10.opacity(0.2)
    static let focusRingWidth: CGFloat = 2

    /// The primary action colour: neutral-10, with neutral-1 text on it.
    static let primaryAction = neutral10
    static let onPrimaryAction = neutral1

    /// Translucent fills keep the hover and skeleton dots readable through
    /// filled controls, which the kit's solid fills would otherwise hide.
    static let fillThroughDotsOpacity: Double = 0.72
}
