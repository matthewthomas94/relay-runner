import SwiftUI

/// The beams creep round slowly, each at its own pace, so no two move in
/// step (user, 2026-11-28). The glow reaches only about 10 pt in from the
/// edge (`innerEdgeMaskPx` in the vendored spec, was 28).
enum PlaybackBeam {
    /// Seconds a lap: Play's, the reply's and the talk button's.
    static let playLap: Double = 4.6
    static let replyLap: Double = 6.4
    static let talkLap: Double = 5.4
}

extension View {
    /// Libraries.dev's Border Beam (vendored in `Vendor/BorderBeam`) in the
    /// playback glow's purples alone: its own palette, no hue cycling, so no
    /// other colours come in (user, 2026-11-28). On the reply the dock's
    /// Play will play and on Play itself, which fade it in and out together.
    /// `lap` is the seconds per lap: the reply's and Play's differ, so the two
    /// beams run round independently, never in step (user, 2026-11-28).
    func playbackBeam(active: Bool, cornerRadius: CGFloat, lap: Double = PlaybackBeam.playLap) -> some View {
        borderBeam(.md, colorVariant: .playback, theme: .dark, staticColors: true, duration: lap,
                   active: active, borderRadius: Double(cornerRadius), hueRange: 0)
    }

    /// The same beam in the listening glow's oranges: round the talk button
    /// while it is ready to send what the user said (user, 2026-11-28).
    func listeningBeam(active: Bool, cornerRadius: CGFloat) -> some View {
        borderBeam(.md, colorVariant: .listening, theme: .dark, staticColors: true,
                   duration: PlaybackBeam.talkLap, active: active,
                   borderRadius: Double(cornerRadius), hueRange: 0)
    }
}
