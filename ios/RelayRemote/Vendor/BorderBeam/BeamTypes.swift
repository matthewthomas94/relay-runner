import SwiftUI

/// Size/type preset for the border beam effect.
///
/// Rotate family (traveling/spinning beam): `.sm`, `.md`, `.line`.
/// Pulse family (breathing glow, no rotation): `.pulseOutside`, `.pulseInner`.
public enum BeamSize: String, CaseIterable, Sendable {
    case sm
    case md
    case line
    case pulseOutside = "pulse-outside"
    case pulseInner = "pulse-inner"

    public var isPulse: Bool { self == .pulseOutside || self == .pulseInner }
}

/// Theme mode for adapting beam colors to the background.
public enum BeamTheme: String, CaseIterable, Sendable {
    case dark
    case light
    /// Follows the SwiftUI `colorScheme` environment.
    case auto
}

/// Color variant for the beam effect.
public enum BeamColorVariant: String, CaseIterable, Sendable {
    case colorful
    case mono
    case ocean
    case sunset
    /// Relay Remote: the ocean layout recoloured to the playback glow's
    /// purples only (hue 0.68 ± 0.04), added to beam-spec.json.
    case playback
}
