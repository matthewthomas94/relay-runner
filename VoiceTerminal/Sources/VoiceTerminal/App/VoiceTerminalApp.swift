import SwiftUI

@main
struct VoiceTerminalApp: App {
    @State private var appState = AppState()

    private var menuBarIcon: String {
        switch appState.stateMachine.state {
        case .recording:        return "mic.fill"
        case .processing:       return "brain"
        case .preparing:        return "brain"
        case .speaking:         return "speaker.wave.2.fill"
        case .messageWaiting:   return "ellipsis.bubble.fill"
        case .paused:           return "pause.fill"
        default:                return "waveform"
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: menuBarIcon)
        }

        Settings {
            SettingsWindow(appState: appState)
        }
    }
}
