import SwiftUI

struct SettingsWindow: View {
    @Bindable var appState: AppState

    var body: some View {
        SettingsContent(appState: appState, style: .window)
    }
}

struct WorkspaceSettingsPanel: View {
    @Bindable var appState: AppState

    var body: some View {
        SettingsContent(appState: appState, style: .workspace)
            .frame(maxWidth: 940, minHeight: BoardSurfaceLayout.columnHeight, maxHeight: BoardSurfaceLayout.columnHeight)
            .background(BoardDarkSurfaceBackground(cornerRadius: BoardDarkSurfaceStyle.columnCornerRadius))
            .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 10)
            .environment(\.colorScheme, .dark)
    }
}

private enum SettingsContentStyle {
    case window
    case workspace

    var contentPadding: EdgeInsets {
        switch self {
        case .window:
            return EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        case .workspace:
            return EdgeInsets(top: 20, leading: 22, bottom: 16, trailing: 22)
        }
    }

    var footerPadding: EdgeInsets {
        switch self {
        case .window:
            return EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        case .workspace:
            return EdgeInsets(top: 12, leading: 22, bottom: 16, trailing: 22)
        }
    }

    var fixedFrame: (width: CGFloat, height: CGFloat)? {
        switch self {
        case .window: return (480, 520)
        case .workspace: return nil
        }
    }
}

private struct SettingsContent: View {
    @Bindable var appState: AppState
    let style: SettingsContentStyle

    @State private var draft: AppConfig
    @State private var saving = false

    init(appState: AppState, style: SettingsContentStyle) {
        self.appState = appState
        self.style = style
        self._draft = State(initialValue: appState.config)
    }

    private var hasChanges: Bool { draft != appState.config }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                StatusSettingsTab(appState: appState)
                    .tabItem { Label("Status", systemImage: "checkmark.shield") }

                STTSettingsTab(config: $draft.stt)
                    .tabItem { Label("Speech-to-Text", systemImage: "mic") }

                TTSSettingsTab(config: $draft.tts)
                    .tabItem { Label("Text-to-Speech", systemImage: "speaker.wave.2") }

                GeneralSettingsTab(config: $draft.general)
                    .tabItem { Label("General", systemImage: "gear") }

                AwarenessSettingsTab(config: $draft.awareness)
                    .tabItem { Label("Awareness", systemImage: "eye") }
            }
            .padding(style.contentPadding)

            Divider()

            HStack {
                if style == .workspace {
                    Text(hasChanges ? "Unsaved changes" : "Settings are up to date")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") {
                    saving = true
                    appState.saveConfig(draft)
                    saving = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges || saving)
            }
            .padding(style.footerPadding)
        }
        .frame(width: style.fixedFrame?.width, height: style.fixedFrame?.height)
        .onChange(of: appState.config) { _, newValue in
            draft = newValue
        }
    }
}
