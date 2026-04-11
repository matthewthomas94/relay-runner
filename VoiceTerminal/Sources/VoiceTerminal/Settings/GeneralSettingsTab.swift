import SwiftUI

struct GeneralSettingsTab: View {
    @Binding var config: GeneralConfig

    var body: some View {
        Form {
            TextField("Target Command", text: $config.command, prompt: Text("claude"))

            Picker("Terminal App", selection: $config.terminal) {
                Text("Warp").tag("warp")
                Text("Terminal.app").tag("terminal")
                Text("iTerm2").tag("iterm2")
                Text("Kitty").tag("kitty")
                Text("Alacritty").tag("alacritty")
            }

            Toggle("Auto-start services on app launch", isOn: $config.auto_start)
        }
    }
}
