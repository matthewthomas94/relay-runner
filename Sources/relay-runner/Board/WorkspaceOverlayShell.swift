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
        case .systemSettings: return "System Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .work: return "rectangle.3.group"
        case .terminal: return "terminal"
        case .systemSettings: return "gearshape"
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

struct WorkspaceOverlayHeader: View {
    @Bindable var workspace: WorkspaceViewModel
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text("Workspace")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.94))

            HStack(spacing: 4) {
                ForEach(workspace.availableTabs) { tab in
                    WorkspaceTabButton(
                        tab: tab,
                        selected: workspace.selectedTab == tab,
                        action: { workspace.select(tab) }
                    )
                }
            }
            .padding(3)
            .background(BoardDarkCapsuleBackground())

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.72))
                    .frame(width: 24, height: 24)
                    .background(BoardDarkCircleBackground())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close Workspace")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(BoardDarkCapsuleBackground(fill: BoardDarkSurfaceStyle.panelFill))
        .onTapGesture { }
    }
}

private struct WorkspaceTabButton: View {
    let tab: WorkspaceTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(tab.title, systemImage: tab.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(
                    Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: selected ? 0.95 : 0.62)
                )
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    Capsule()
                        .fill(selected ? Color(.sRGB, red: 31 / 255, green: 41 / 255, blue: 55 / 255, opacity: 1) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}
