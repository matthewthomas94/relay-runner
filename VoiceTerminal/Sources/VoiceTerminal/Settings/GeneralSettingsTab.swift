import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsTab: View {
    @Binding var config: GeneralConfig

    var body: some View {
        Form {
            TextField("Target Command", text: $config.command, prompt: Text("claude"))

            LabeledContent("Terminal App") {
                TerminalAppPicker(terminal: $config.terminal)
            }

            Toggle("Auto-start services on app launch", isOn: $config.auto_start)
        }
    }
}

private struct TerminalAppPicker: View {
    @Binding var terminal: String

    private var resolvedPath: String {
        GeneralConfig.resolveTerminalPath(terminal)
    }

    private var displayName: String {
        let path = resolvedPath
        if let bundle = Bundle(path: path),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private var appIcon: NSImage {
        let path = resolvedPath
        if FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 20, height: 20)
            Text(displayName)
            Spacer()
            Button("Choose\u{2026}") {
                chooseApp()
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Select Terminal App"
        if panel.runModal() == .OK, let url = panel.url {
            terminal = url.path
        }
    }
}
