import SwiftUI

enum WorkspaceTab: String, CaseIterable, Identifiable, Equatable {
    case work
    case notes
    case terminal
    case systemSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: return "Workspace"
        case .notes: return "Notes"
        case .terminal: return "Terminal"
        case .systemSettings: return "Settings"
        }
    }

    var requiresKeyWindow: Bool {
        self == .notes || self == .terminal || self == .systemSettings
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
    var updater: RelayUpdaterController?

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
        tabs.append(.notes)
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

enum WorkspaceNavigationStyle {
    static let controlHeight: CGFloat = BoardSurfaceLayout.navigationHeight
    static let horizontalPadding: CGFloat = 4
    static let verticalPadding: CGFloat = horizontalPadding
    static let cornerRadius: CGFloat = 4
    static let iconTextSpacing: CGFloat = 6
    static let iconSize: CGFloat = 10
    static let systemFocusEffectDisabled = true
    static let activeTextOpacity: Double = 0.98
    static let inactiveTextOpacity: Double = 0.72
    static let selectedFillOpacity: Double = 0.08
    static let focusedFillOpacity: Double = 0.12
}

struct WorkspaceMenuBarStrip: View {
    @Bindable var workspace: WorkspaceViewModel
    let hasActiveSession: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RelaySwap(hasActiveSession) { hasActiveSession in
                Image(TrayIconAsset.name(hasActiveSession: hasActiveSession), bundle: RelayRunnerResources.bundle)
                    .renderingMode(.original)
                    .frame(
                        width: BoardSurfaceLayout.navigationHeight,
                        height: BoardSurfaceLayout.navigationHeight
                    )
            }
            .accessibilityLabel(hasActiveSession ? "Relay Runner session active" : "Relay Runner session inactive")

            ForEach(workspace.availableTabs) { tab in
                WorkspaceTabButton(
                    tab: tab,
                    selected: workspace.selectedTab == tab,
                    action: { workspace.select(tab) }
                )
                .transition(.relayElement)
            }
            if let updater = workspace.updater, let version = updater.availableVersion {
                WorkspaceNavigationButton(
                    title: "Update available",
                    systemName: "arrow.down.to.line",
                    accessibilityLabel: "Update available tab, version \(version)",
                    help: "Download Relay Runner \(version)",
                    action: { updater.checkForUpdates() }
                )
                .transition(.relayElement)
            }
        }
        .frame(height: BoardSurfaceLayout.navigationHeight)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: workspace.availableTabs)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: workspace.updater?.availableVersion)
        .onTapGesture { }
    }
}

private struct WorkspaceTabButton: View {
    let tab: WorkspaceTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        WorkspaceNavigationButton(
            title: tab.title,
            selected: selected,
            accessibilityLabel: "\(tab.title) tab",
            help: "\(tab.title) tab",
            action: action
        )
    }
}

struct WorkspaceNavigationButton: View {
    let title: String
    let systemName: String?
    let selected: Bool
    let accessibilityLabel: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        systemName: String? = nil,
        selected: Bool = false,
        accessibilityLabel: String? = nil,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemName = systemName
        self.selected = selected
        self.accessibilityLabel = accessibilityLabel ?? title
        self.help = help ?? title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: WorkspaceNavigationStyle.iconTextSpacing) {
                if let systemName {
                    RelaySwap(systemName) { systemName in
                        Image(systemName: systemName)
                            .font(AppTypography.symbolFont(
                                size: WorkspaceNavigationStyle.iconSize,
                                weight: .bold
                            ))
                            .frame(
                                width: WorkspaceNavigationStyle.iconSize,
                                height: WorkspaceNavigationStyle.iconSize
                            )
                    }
                }
                // Start ↔ End session and note-taker titles swap in place.
                RelaySwap(title, style: .text, alignment: .leading) { title in
                    Text(title)
                        .font(AppTypography.font(.menuTab))
                        .lineLimit(1)
                }
            }
            .animation(RelayMotion.change(reduceMotion: reduceMotion), value: title)
            .foregroundStyle(
                Color(
                    .sRGB,
                    red: 226 / 255,
                    green: 232 / 255,
                    blue: 240 / 255,
                    opacity: foregroundOpacity
                )
            )
            .frame(height: WorkspaceNavigationStyle.controlHeight - 2 * WorkspaceNavigationStyle.verticalPadding)
            .padding(.horizontal, WorkspaceNavigationStyle.horizontalPadding)
            .padding(.vertical, WorkspaceNavigationStyle.verticalPadding)
            // Selection, hover, and focus show through the text colour alone.
            .contentShape(
                RoundedRectangle(cornerRadius: WorkspaceNavigationStyle.cornerRadius)
            )
            .animation(RelayMotion.hover, value: isHovered)
            .animation(RelayMotion.hover, value: isFocused)
            .animation(RelayMotion.change(reduceMotion: reduceMotion), value: selected)
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled(WorkspaceNavigationStyle.systemFocusEffectDisabled)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }

    private var foregroundOpacity: Double {
        selected || isHovered || isFocused
            ? WorkspaceNavigationStyle.activeTextOpacity
            : WorkspaceNavigationStyle.inactiveTextOpacity
    }
}
