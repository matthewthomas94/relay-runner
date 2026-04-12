import SwiftUI

struct GeneralSettingsTab: View {
    @Binding var config: GeneralConfig

    var body: some View {
        Form {
            TextField("Target Command", text: $config.command, prompt: Text("claude"))

            Toggle("Auto-start services on app launch", isOn: $config.auto_start)
        }
    }
}
