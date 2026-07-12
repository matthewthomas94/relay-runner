import SwiftUI

enum WorkspaceTab: String, CaseIterable, Identifiable, Equatable {
    case work
    case terminal
    case systemSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: return "Work"
        case .terminal: return "Terminal"
        case .systemSettings: return "Settings"
        }
    }

    var requiresKeyWindow: Bool {
        self == .terminal || self == .systemSettings
    }

    func allowsEscapeDismissal(terminalHasFocus: Bool) -> Bool {
        self != .terminal || !terminalHasFocus
    }
}

@Observable
final class WorkspaceViewModel {
    var selectedTab: WorkspaceTab = .work
    var showsWorkTab = true
    var showsTerminalTab = true
    var showsSettingsTab = false

    var availableTabs: [WorkspaceTab] {
        WorkspaceViewModel.availableTabs(
            showsWorkTab: showsWorkTab,
            showsTerminalTab: showsTerminalTab,
            showsSettingsTab: showsSettingsTab
        )
    }

    func configure(
        showsWorkTab: Bool,
        showsTerminalTab: Bool,
        showsSettingsTab: Bool,
        initialTab: WorkspaceTab
    ) {
        self.showsWorkTab = showsWorkTab
        self.showsTerminalTab = showsTerminalTab
        self.showsSettingsTab = showsSettingsTab
        selectedTab = Self.normalized(
            initialTab,
            showsWorkTab: showsWorkTab,
            showsTerminalTab: showsTerminalTab,
            showsSettingsTab: showsSettingsTab
        )
    }

    func select(_ tab: WorkspaceTab) {
        selectedTab = Self.normalized(
            tab,
            showsWorkTab: showsWorkTab,
            showsTerminalTab: showsTerminalTab,
            showsSettingsTab: showsSettingsTab
        )
    }

    static func availableTabs(
        showsWorkTab: Bool,
        showsTerminalTab: Bool,
        showsSettingsTab: Bool
    ) -> [WorkspaceTab] {
        var tabs: [WorkspaceTab] = []
        if showsWorkTab { tabs.append(.work) }
        if showsTerminalTab { tabs.append(.terminal) }
        if showsSettingsTab { tabs.append(.systemSettings) }
        return tabs
    }

    static func normalized(
        _ tab: WorkspaceTab,
        showsWorkTab: Bool,
        showsTerminalTab: Bool,
        showsSettingsTab: Bool
    ) -> WorkspaceTab {
        let tabs = availableTabs(
            showsWorkTab: showsWorkTab,
            showsTerminalTab: showsTerminalTab,
            showsSettingsTab: showsSettingsTab
        )
        if tabs.contains(tab) { return tab }
        return tabs.first ?? .work
    }
}

enum TrayIconAsset {
    static func name(hasActiveSession: Bool) -> String {
        hasActiveSession ? "TrayIconActive" : "TrayIcon"
    }
}

struct WorkspaceMenuBarStrip: View {
    @Bindable var workspace: WorkspaceViewModel
    let hasActiveSession: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(TrayIconAsset.name(hasActiveSession: hasActiveSession), bundle: RelayRunnerResources.bundle)
                .renderingMode(.original)
                .frame(width: 24, height: 24)
                .accessibilityLabel(hasActiveSession ? "Relay Runner session active" : "Relay Runner session inactive")

            ForEach(workspace.availableTabs) { tab in
                WorkspaceTabButton(
                    tab: tab,
                    selected: workspace.selectedTab == tab,
                    action: { workspace.select(tab) }
                )
            }
        }
        .frame(height: 24)
        .onTapGesture { }
    }
}

private struct WorkspaceTabButton: View {
    let tab: WorkspaceTab
    let selected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(tab.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: selected || isHovered || isFocused ? 0.98 : 0.72)
                )
                .padding(.horizontal, 2)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tabFill)
                )
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(tab.title) tab")
        .help("\(tab.title) tab")
    }

    private var tabFill: Color {
        if selected { return Color.white.opacity(0.08) }
        if isFocused { return Color.white.opacity(0.12) }
        if isHovered { return Color.white.opacity(0.06) }
        return Color.clear
    }
}
