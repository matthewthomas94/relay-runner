import SwiftUI

/// The app-wide state glows, behind every screen including the tab bar,
/// dock and text box: the listening field while the user talks and the
/// playback field while a reply plays (`DotField`). RR-541 wires them to the
/// voice state; until then nothing shows.
struct AppGlowLayer: View {
    let model: AppModel

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}
