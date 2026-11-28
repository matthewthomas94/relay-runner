import SwiftUI

extension View {
    /// Libraries.dev's Border Beam (vendored in `Vendor/BorderBeam`) in the
    /// playback glow's purples alone: its own palette, no hue cycling, so no
    /// other colours come in (user, 2026-11-28). On the reply the dock's
    /// Play will play and on Play itself, which fade it in and out together.
    func playbackBeam(active: Bool, cornerRadius: CGFloat) -> some View {
        borderBeam(.md, colorVariant: .playback, theme: .dark, staticColors: true, active: active,
                   borderRadius: Double(cornerRadius), hueRange: 0)
    }

    /// The same beam in the listening glow's oranges: round the talk button
    /// while it is ready to send what the user said (user, 2026-11-28).
    func listeningBeam(active: Bool, cornerRadius: CGFloat) -> some View {
        borderBeam(.md, colorVariant: .listening, theme: .dark, staticColors: true, active: active,
                   borderRadius: Double(cornerRadius), hueRange: 0)
    }
}
