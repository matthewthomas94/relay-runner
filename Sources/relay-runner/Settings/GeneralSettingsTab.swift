import SwiftUI

struct GeneralSettingsTab: View {
    @Binding var config: GeneralConfig
    @State private var skillInstalled = ProcessManager().isSkillInstalled
    @State private var showSkillSuccess = false
    @State private var showOverwriteAlert = false

    var body: some View {
        Form {
            TextField("Target Command", text: $config.command, prompt: Text("claude"))

            HStack {
                TextField("Working Directory", text: $config.working_directory, prompt: Text("~ (home)"))
                Button("Browse\u{2026}") { pickDirectory() }
            }

            Toggle("Auto-start services on app launch", isOn: $config.auto_start)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code Skill")
                    Text("Adds the /relay-bridge command to Claude Code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if showSkillSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button(skillInstalled ? "Reinstall" : "Install") {
                    if skillInstalled {
                        showOverwriteAlert = true
                    } else {
                        doInstallSkill()
                    }
                }
            }
            .alert("Overwrite existing skill?", isPresented: $showOverwriteAlert) {
                Button("Overwrite", role: .destructive) { doInstallSkill() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will replace ~/.claude/commands/relay-bridge.md with the default version.")
            }
        }
    }

    private func doInstallSkill() {
        let pm = ProcessManager()
        if pm.installSkill() {
            skillInstalled = true
            showSkillSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showSkillSuccess = false
            }
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the working directory for new voice sessions"
        if panel.runModal() == .OK, let url = panel.url {
            config.working_directory = url.path
        }
    }
}
