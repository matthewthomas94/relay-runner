import SwiftUI

/// The app after onboarding: the selected tab's content above the glass tab
/// bar. Each tab is its own view in its own file; this file only switches
/// between them.
struct MainTabView: View {
    let model: AppModel
    @State private var selection: MainTab

    init(model: AppModel, initialTab: MainTab = .agents) {
        self.model = model
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        ZStack {
            switch selection {
            case .agents: AgentsTabView(model: model)
            case .workspace: WorkspaceTabView(model: model)
            case .settings: SettingsTabView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassTabBar { GlassTabBar(selection: $selection) }
    }
}
