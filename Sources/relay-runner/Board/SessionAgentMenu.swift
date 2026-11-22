import SwiftUI

/// RR-523: what the Start/End session button does. While a session runs it
/// ends the session. With none running it has no direct start: activating it
/// opens the agent menu, and choosing an agent starts that agent.
enum ProgramSessionAction {
    case end(() -> Void)
    case chooseAgent(options: [SessionAgent], start: (SessionAgent) -> Void)

    static func resolve(
        hasActiveSession: Bool,
        end: @escaping () -> Void,
        start: @escaping (SessionAgent) -> Void
    ) -> ProgramSessionAction {
        hasActiveSession ? .end(end) : .chooseAgent(options: SessionAgent.allCases, start: start)
    }

    /// The agents the menu offers; empty while the button ends the session.
    var agentOptions: [SessionAgent] {
        if case .chooseAgent(let options, _) = self { return options }
        return []
    }
}

/// RR-523: the agent menu behind the Start Session button and the terminal
/// tab strip's "+", built the way the Add project menu is: a list of actions,
/// each an agent's name, and no checkmarks.
struct SessionAgentMenuOptions: View {
    let agents: [SessionAgent]
    let start: (SessionAgent) -> Void
    let dismiss: () -> Void

    var body: some View {
        SettingsMenuOptions(
            title: "Start agent",
            selection: Binding<SessionAgent?>(
                get: { nil },
                set: { agent in if let agent { start(agent) } }
            ),
            options: agents.map { (label: $0.name, value: Optional($0)) },
            showsCheckmarks: false,
            dismiss: dismiss
        )
        .environment(\.colorScheme, .dark)
    }
}
