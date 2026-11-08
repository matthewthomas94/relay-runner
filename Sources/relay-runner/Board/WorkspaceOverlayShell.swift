import SwiftUI

enum WorkspaceTab: String, CaseIterable, Identifiable, Equatable {
    case work
    case notes
    case terminal
    case history
    case systemSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: return "Workspace"
        case .notes: return "Notetaker"
        case .terminal: return "Terminal"
        case .history: return "History"
        case .systemSettings: return "Settings"
        }
    }

    var requiresKeyWindow: Bool {
        self == .notes || self == .terminal || self == .history || self == .systemSettings
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
    var isGeneralContext = true
    var contextPath: String?

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
        // History lists a project's archived tickets, so it follows the Workspace tab.
        if showsWorkTab { tabs.append(.history) }
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

/// The Graphical kit's tabs: a neutral-3 list with 4 points of padding, and
/// triggers that are neutral-7 at rest, white on hover, and white on a
/// neutral-1 pill when selected.
enum WorkspaceNavigationStyle {
    static let listPadding: CGFloat = GraphicalTheme.spaceXXS
    static let listCornerRadius: CGFloat = GraphicalTheme.radiusM
    static let listFill = GraphicalTheme.neutral3
    static let controlHeight: CGFloat = BoardSurfaceLayout.navigationHeight - 2 * listPadding
    static let horizontalPadding: CGFloat = GraphicalTheme.spaceS
    static let verticalPadding: CGFloat = 4
    static let cornerRadius: CGFloat = GraphicalTheme.radiusS
    static let iconTextSpacing: CGFloat = 6
    static let iconSize: CGFloat = 10
    static let systemFocusEffectDisabled = true
    static let activeTextOpacity: Double = 0.98
    static let selectedFillOpacity: Double = 0.08
    static let focusedFillOpacity: Double = 0.12
    static let textColor = GraphicalTheme.neutral10.opacity(activeTextOpacity)
    static let inactiveTextColor = GraphicalTheme.neutral7
    static let selectedFill = GraphicalTheme.neutral1
}

/// The day, date and time at the strip's far end, where the menu bar's
/// clock sits, so they stay in view while the Workspace covers it.
struct WorkspaceMenuBarClock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.text(for: context.date))
                .font(AppTypography.font(.menuTab))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(WorkspaceNavigationStyle.textColor)
        }
        .frame(height: BoardSurfaceLayout.navigationHeight)
    }

    /// Written as the menu bar writes it, in the user's locale and 12- or
    /// 24-hour preference, without the locale's comma: "Sun 1 Nov  8:49 pm".
    static func text(for date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        let day = formatter.string(from: date).replacingOccurrences(of: ",", with: "")
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return day + "  " + formatter.string(from: date)
    }
}

struct WorkspaceMenuBarStrip: View {
    @Bindable var workspace: WorkspaceViewModel
    let hasActiveSession: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionHighlight

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            RelaySwap(hasActiveSession) { hasActiveSession in
                Image(TrayIconAsset.name(hasActiveSession: hasActiveSession), bundle: RelayRunnerResources.bundle)
                    .renderingMode(.original)
                    .frame(
                        width: BoardSurfaceLayout.navigationHeight,
                        height: BoardSurfaceLayout.navigationHeight
                    )
            }
            .accessibilityLabel(hasActiveSession ? "Relay Runner session active" : "Relay Runner session inactive")

            HStack(spacing: GraphicalTheme.spaceXXS) {
                ForEach(workspace.availableTabs) { tab in
                    WorkspaceTabButton(
                        tab: tab,
                        selected: workspace.selectedTab == tab,
                        action: { workspace.select(tab) }
                    )
                    .background {
                        if workspace.selectedTab == tab {
                            // One highlight glides between tabs; Reduce Motion
                            // gives each tab its own id so it only crossfades.
                            RoundedRectangle(cornerRadius: WorkspaceNavigationStyle.cornerRadius, style: .continuous)
                                .fill(WorkspaceNavigationStyle.selectedFill)
                                .graphicalShadow(.s)
                                .matchedGeometryEffect(
                                    id: reduceMotion ? AnyHashable(tab.id) : AnyHashable("selection"),
                                    in: selectionHighlight
                                )
                        }
                    }
                    .transition(.relayElement)
                }
            }
            .padding(WorkspaceNavigationStyle.listPadding)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceNavigationStyle.listCornerRadius, style: .continuous)
                    .fill(WorkspaceNavigationStyle.listFill)
            )
            if let updater = workspace.updater, let version = updater.availableVersion {
                WorkspaceNavigationButton(
                    title: "Update available",
                    systemName: "arrow.down.to.line",
                    accessibilityLabel: "Update available tab, version \(version)",
                    help: "Download update",
                    action: { updater.checkForUpdates() }
                )
                .transition(.relayElement)
            }
        }
        .frame(height: BoardSurfaceLayout.navigationHeight)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: workspace.availableTabs)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: workspace.selectedTab)
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
            help: selected ? "" : "Open \(tab.title.lowercased()) tab",
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
        self.help = help ?? ""
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
            .foregroundStyle(foregroundColor)
            .frame(height: WorkspaceNavigationStyle.controlHeight - 2 * WorkspaceNavigationStyle.verticalPadding)
            .padding(.horizontal, WorkspaceNavigationStyle.horizontalPadding)
            .padding(.vertical, WorkspaceNavigationStyle.verticalPadding)
            // Hover fills the item with the skeleton loader's shimmering
            // dots. The selected fill is drawn by the strip so it can glide
            // between tabs.
            .background {
                FluxDotsBackground(
                    cornerRadius: WorkspaceNavigationStyle.cornerRadius,
                    style: .standard,
                    isVisible: isHovered && !selected
                )
            }
            .contentShape(
                RoundedRectangle(cornerRadius: WorkspaceNavigationStyle.cornerRadius, style: .continuous)
            )
            .animation(RelayMotion.hover, value: isHovered)
            .animation(RelayMotion.hover, value: isFocused)
            .animation(RelayMotion.change(reduceMotion: reduceMotion), value: selected)
        }
        .buttonStyle(.graphicalPress)
        .focusable()
        .focusEffectDisabled(WorkspaceNavigationStyle.systemFocusEffectDisabled)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
        .notchHint(help)
    }

    private var foregroundColor: Color {
        selected || isHovered || isFocused
            ? WorkspaceNavigationStyle.textColor : WorkspaceNavigationStyle.inactiveTextColor
    }
}
