import SwiftUI

struct AwarenessSettingsTab: View {
    @Binding var config: AwarenessConfig

    var body: some View {
        Form {
            Section {
                Text("Awareness features are coming soon.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
