import SwiftUI

struct SettingsWindow: View {
    @Bindable var appState: AppState

    @State private var draft: AppConfig
    @State private var saving = false

    init(appState: AppState) {
        self.appState = appState
        self._draft = State(initialValue: appState.config)
    }

    private var hasChanges: Bool { draft != appState.config }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                STTSettingsTab(config: $draft.stt)
                    .tabItem { Label("Speech-to-Text", systemImage: "mic") }

                TTSSettingsTab(config: $draft.tts)
                    .tabItem { Label("Text-to-Speech", systemImage: "speaker.wave.2") }

                ControlsSettingsTab(config: $draft.controls)
                    .tabItem { Label("Controls", systemImage: "keyboard") }

                GeneralSettingsTab(config: $draft.general)
                    .tabItem { Label("General", systemImage: "gear") }

                AwarenessSettingsTab(config: $draft.awareness)
                    .tabItem { Label("Awareness", systemImage: "eye") }
            }
            .padding()

            Divider()

            HStack {
                Spacer()
                Button("Save") {
                    saving = true
                    appState.saveConfig(draft)
                    saving = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges || saving)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onChange(of: appState.config) { _, newValue in
            draft = newValue
        }
    }
}
