import SwiftUI

struct ControlsSettingsTab: View {
    @Binding var config: ControlsConfig

    var body: some View {
        Form {
            KeyCaptureView(label: "Play / Pause Key", value: $config.play_pause_key)
            KeyCaptureView(label: "Skip Key", value: $config.skip_key)
        }
    }
}
