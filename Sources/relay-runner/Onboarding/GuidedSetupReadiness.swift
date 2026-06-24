import Foundation

struct GuidedSetupPlan {
    struct Item: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    let provider: GeneralConfig.AgentProvider

    var primaryActionTitle: String {
        "Set Up \(provider.displayName)"
    }

    var items: [Item] {
        Self.items(for: provider)
    }

    static func items(for provider: GeneralConfig.AgentProvider) -> [Item] {
        [
            Item(
                id: "voice-runtime",
                title: "Prepare local voice runtime",
                detail: "Install or verify the bundled Python environment, speech model, voice bridge, and TTS worker."
            ),
            providerToolsItem(for: provider),
            Item(
                id: "workspace-folder",
                title: "Choose workspace folder",
                detail: "Persist where Relay Runner starts \(provider.displayName) sessions and lets Program Manager discover child git repositories."
            ),
            Item(
                id: "session-readiness",
                title: "Check session launch readiness",
                detail: "Verify the selected agent can start with Relay Runner's voice bridge command already queued."
            ),
            Item(
                id: "board-readiness",
                title: "Prepare project boards",
                detail: "Use the selected workspace folder to find child repos or activate one repo without asking the model to classify the folder."
            ),
        ]
    }

    static func providerToolsItem(for provider: GeneralConfig.AgentProvider) -> Item {
        switch provider {
        case .codex:
            return Item(
                id: "provider-tools",
                title: "Install Codex Relay tools",
                detail: "Refresh the Codex relay-bridge and relay-stop skills and the MCP tool registration used by Codex sessions."
            )
        case .claude:
            return Item(
                id: "provider-tools",
                title: "Install Claude Relay tools",
                detail: "Refresh the Claude /relay-bridge and /relay-stop slash commands and the MCP tool registration used by Claude sessions."
            )
        }
    }
}

struct GuidedSetupReadiness: Equatable {
    enum Mode: Equatable {
        case blocked
        case voiceOnly
        case fullyArmed
    }

    let provider: GeneralConfig.AgentProvider
    let microphone: PermissionStatus
    let inputMonitoring: PermissionStatus
    let pythonInstalled: Bool
    let agentSignedIn: Bool
    let parentPermissionsReviewed: Bool

    var voiceReady: Bool {
        microphone == .granted && pythonInstalled && agentSignedIn
    }

    var screenControlAndBoardReady: Bool {
        inputMonitoring == .granted && parentPermissionsReviewed
    }

    var mode: Mode {
        guard voiceReady else { return .blocked }
        return screenControlAndBoardReady ? .fullyArmed : .voiceOnly
    }

    var title: String {
        switch mode {
        case .blocked:
            return "Setup still needs attention."
        case .voiceOnly:
            return "Voice-ready. Screen control is deferred."
        case .fullyArmed:
            return "Fully armed for voice, screen control, and board."
        }
    }

    var detail: String {
        switch mode {
        case .blocked:
            return missingRequiredItems.joined(separator: " ")
        case .voiceOnly:
            return "Start Session can launch \(provider.displayName) with the voice bridge and TTS ready. \(deferredItems.joined(separator: " "))"
        case .fullyArmed:
            return "Start Session can launch \(provider.displayName) with the voice bridge, board, MCP tools, and TTS ready."
        }
    }

    var missingRequiredItems: [String] {
        var items: [String] = []
        if microphone != .granted {
            items.append("Microphone access is required before voice sessions can start.")
        }
        if !pythonInstalled {
            items.append("The bundled Python voice environment still needs to finish installing.")
        }
        if !agentSignedIn {
            items.append("\(provider.displayName) sign-in still needs to complete.")
        }
        return items
    }

    var deferredItems: [String] {
        guard voiceReady else { return [] }
        var items: [String] = []
        if inputMonitoring != .granted {
            items.append("Input Monitoring is deferred, so non-Caps-Lock activation keys and the double-tap Shift board hotkey stay disabled.")
        }
        if !parentPermissionsReviewed {
            items.append("Parent-app Accessibility and Screen Recording are deferred, so Relay Actions and Relay Vision may prompt again after the session starts.")
        }
        return items
    }
}
