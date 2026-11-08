import SwiftUI

struct SettingsWindow: View {
    @Bindable var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(appState: AppState) {
        self.appState = appState
    }

    var body: some View {
        shellContent
            .animation(
                RelayMotion.change(reduceMotion: reduceMotion),
                value: appState.isFirstRunExperienceActive
            )
    }

    @ViewBuilder
    private var shellContent: some View {
        if AppState.allowsAppShellAccess(
            firstRunExperienceActive: appState.isFirstRunExperienceActive
        ) {
            SettingsContent(
                appState: appState,
                style: .window
            )
            // The Settings scene mounts this from AppKit, so it plays its own entrance.
            .relayAppearOnMount()
            .transition(.asymmetric(insertion: .identity, removal: .relaySurface))
        } else {
            EmptyView()
        }
    }
}

struct WorkspaceSettingsPanel: View {
    @Bindable var appState: AppState
    let onOpenExternalWindow: () -> Void

    init(
        appState: AppState,
        onOpenExternalWindow: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.onOpenExternalWindow = onOpenExternalWindow
    }

    var body: some View {
        SettingsContent(
            appState: appState,
            style: .workspace,
            onOpenExternalWindow: onOpenExternalWindow
        )
            .frame(maxWidth: WorkspaceSurfaceSizing.settingsMaxWidth, minHeight: BoardSurfaceLayout.columnHeight, maxHeight: BoardSurfaceLayout.columnHeight)
            .environment(\.colorScheme, .dark)
    }
}

enum SettingsContentStyle {
    case window
    case workspace

    var sidebarWidth: CGFloat {
        switch self {
        case .window: return 172
        case .workspace: return 190
        }
    }

    var detailPadding: EdgeInsets {
        switch self {
        case .window: return EdgeInsets(top: 18, leading: 20, bottom: 20, trailing: 20)
        case .workspace: return EdgeInsets(top: 18, leading: 22, bottom: 22, trailing: 22)
        }
    }

    var footerPadding: EdgeInsets {
        switch self {
        case .window: return EdgeInsets(top: 12, leading: 20, bottom: 14, trailing: 20)
        case .workspace: return EdgeInsets(top: 12, leading: 22, bottom: 14, trailing: 22)
        }
    }

    var fixedFrame: (width: CGFloat, height: CGFloat)? {
        switch self {
        case .window: return (1148, 640)
        case .workspace: return nil
        }
    }

    var detailMaxWidth: CGFloat {
        SettingsLayout.detailMaxWidth
    }

}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case permissions
    case speechToText
    case textToSpeech
    case general
    case awareness
    case relayRemote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .permissions: return "Permissions"
        case .speechToText: return "Speech-to-Text"
        case .textToSpeech: return "Text-to-Speech"
        case .general: return "General"
        case .awareness: return "Awareness"
        case .relayRemote: return "Relay Remote"
        }
    }

    var navigationLabel: String { title }

    var icon: LucideIcon {
        switch self {
        case .permissions: return .shieldCheck
        case .speechToText: return .mic
        case .textToSpeech: return .volume2
        case .general: return .settings
        case .awareness: return .eye
        case .relayRemote: return .smartphone
        }
    }

    static func category(after category: SettingsCategory) -> SettingsCategory {
        let all = Self.allCases
        guard let index = all.firstIndex(of: category), index < all.index(before: all.endIndex) else {
            return category
        }
        return all[all.index(after: index)]
    }

    static func category(before category: SettingsCategory) -> SettingsCategory {
        let all = Self.allCases
        guard let index = all.firstIndex(of: category), index > all.startIndex else {
            return category
        }
        return all[all.index(before: index)]
    }

}

private struct SettingsContent: View {
    @Bindable var appState: AppState
    let style: SettingsContentStyle
    let onOpenExternalWindow: () -> Void

    @State private var draft: AppConfig
    @State private var saving = false
    @State private var selectedCategory: SettingsCategory = .permissions
    @State private var scrollTarget: SettingsCategory = .permissions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        appState: AppState,
        style: SettingsContentStyle,
        onOpenExternalWindow: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.style = style
        self.onOpenExternalWindow = onOpenExternalWindow
        self._draft = State(initialValue: appState.config)
    }

    private var hasChanges: Bool { draft != appState.config }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: SettingsAgentCardLayout.spacing) {
                settingsPane
                    .frame(maxWidth: .infinity)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    SettingsAgentCard(
                        presentation: SettingsAgentPresentation(
                            name: SettingsAgentPresentation.voiceName(draft.tts),
                            subtitle: SettingsAgentPresentation.subtitle(
                                state: appState.stateMachine.state,
                                hasActiveSession: appState.hasActiveSession,
                                hasWorkingProgress: appState.stateMachine.currentWorkingProgress(now: context.date) != nil
                            )
                        ),
                        theme: appState.stateMachine.state.particleTheme ?? .idle
                    )
                }
                .frame(width: style == .window ? 280 : SettingsAgentCardLayout.width(availableWidth: geometry.size.width))
            }
        }
        // The window is its own black page; in the Workspace the backdrop is.
        .padding(style == .window ? SettingsAgentCardLayout.spacing : 0)
        .background(style == .window ? GraphicalTheme.neutral1 : Color.clear)
        .foregroundStyle(SettingsSurfaceColor.primaryText)
        .tint(SettingsSurfaceColor.focusRing)
        .environment(\.colorScheme, .dark)
        .frame(width: style.fixedFrame?.width, height: style.fixedFrame?.height)
        .onAppear { selectRequestedCategory() }
        .onChange(of: appState.requestedSettingsCategory) { _, _ in selectRequestedCategory() }
        .onChange(of: appState.config) { oldValue, newValue in
            // A save made elsewhere (Relay App, RR-459) shows at once unless the page has unsaved edits.
            draft = draft == oldValue ? newValue : draft.mergingWheelSettingsChange(from: oldValue, to: newValue)
                ?? newValue
        }
        .onChange(of: selectedCategory) { _, newValue in
            scrollTarget = newValue
        }
    }

    private func selectRequestedCategory() {
        guard let requested = appState.requestedSettingsCategory else { return }
        appState.requestedSettingsCategory = nil
        selectedCategory = requested
    }

    /// Cards on the black page, like the Workspace's columns: the category
    /// sidebar, one card per settings section, and the save bar. No lines.
    private var settingsPane: some View {
        HStack(spacing: SettingsAgentCardLayout.spacing) {
            SettingsCategorySidebar(
                selection: $selectedCategory,
                style: style
            )
            .frame(width: style.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(
                SettingsSurfaceColor.cardFill,
                in: RoundedRectangle(cornerRadius: SettingsLayout.cardCornerRadius, style: .continuous)
            )

            VStack(spacing: SettingsLayout.sectionSpacing) {
                ScrollViewReader { proxy in
                    // Each category is its own page: the outgoing page sinks away
                    // at its own scroll position, then the next one rises in.
                    ZStack(alignment: .topLeading) {
                        RelayFadingScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                Color.clear
                                    .frame(height: 0)
                                    .id(selectedCategory)
                                selectedDetail
                                    .frame(maxWidth: style.detailMaxWidth, alignment: .topLeading)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                        .id(selectedCategory)
                        .transition(.relayReplacing(.surface))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .animation(RelayMotion.change(reduceMotion: reduceMotion), value: selectedCategory)
                    .onChange(of: scrollTarget) { _, target in
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                footer
            }
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch selectedCategory {
        case .permissions:
            PermissionsSettingsTab(appState: appState)
        case .speechToText:
            STTSettingsTab(
                config: $draft.stt,
                migrationState: appState.phononMigration?.state,
                onRetryMigration: { appState.phononMigration?.retry() },
                cameraPermission: appState.permissions,
                onTrueWhisperTemplatesChanged: { appState.trueWhisperTemplatesChanged() }
            )
        case .textToSpeech:
            TTSSettingsTab(config: $draft.tts, appState: appState)
        case .general:
            GeneralSettingsTab(
                config: $draft.general,
                onOpenExternalWindow: onOpenExternalWindow,
                projectRegistryAppState: appState,
                keepAwake: appState.keepAwake
            )
        case .awareness:
            AwarenessSettingsTab(config: $draft.awareness)
        case .relayRemote:
            RelayRemoteSettingsTab(controller: RelayRemoteController.shared)
        }
    }

    private var footer: some View {
        return AnyView(settingsFooter)
    }

    /// The save bar: a card whose status line appears only for unsaved
    /// changes, with Save as the primary action once there is something to save.
    private var settingsFooter: some View {
        HStack(spacing: 12) {
            if hasChanges {
                HStack(spacing: 6) {
                    Circle()
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text("Unsaved changes")
                        .font(AppTypography.font(.settingsDescription))
                }
                .foregroundStyle(SettingsSurfaceColor.neutralAccent)
                .transition(.relayText)
            }

            Spacer(minLength: 0)

            SettingsActionButton(
                title: "Revert",
                icon: .undo2,
                prominence: .secondary,
                isEnabled: hasChanges && !saving,
                accessibilityLabel: "Revert settings",
                helpText: hasChanges ? "Discard unsaved settings changes" : "No settings changes to revert"
            ) {
                draft = appState.config
            }

            SettingsFooterSaveButton(isEnabled: hasChanges && !saving) {
                saving = true
                appState.saveConfig(draft)
                saving = false
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: hasChanges)
        .padding(style.footerPadding)
        .frame(maxWidth: style.detailMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SettingsSurfaceColor.cardFill,
            in: RoundedRectangle(cornerRadius: SettingsLayout.cardCornerRadius, style: .continuous)
        )
    }

}

private struct SettingsFooterSaveButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        SettingsActionButton(
            title: "Save",
            icon: .check,
            prominence: isEnabled ? .primary : .secondary,
            isEnabled: isEnabled,
            accessibilityLabel: "Save settings",
            helpText: isEnabled ? "Save settings" : "No settings changes to save",
            action: action
        )
        .keyboardShortcut(.defaultAction)
    }
}

enum SettingsSemanticColor: Equatable {
    case neutralAccent
    case success
    case error
    case idle

    var color: Color {
        switch self {
        case .neutralAccent: return SettingsSurfaceColor.neutralAccent
        case .success: return SettingsSurfaceColor.success
        case .error: return SettingsSurfaceColor.error
        case .idle: return SettingsSurfaceColor.mutedText
        }
    }
}

private struct SettingsCategorySidebar: View {
    @Binding var selection: SettingsCategory
    let style: SettingsContentStyle
    @Namespace private var selectionHighlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Rows start where the Notes tab's list does: below a 60pt header
        // and an 18pt inset.
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(AppTypography.font(.workspaceHeading))
                .foregroundStyle(SettingsSurfaceColor.primaryText)
                .padding(.horizontal, 16)
                .padding(.top, style == .workspace ? 18 : 16)
                .frame(height: 60, alignment: .top)

            VStack(spacing: 4) {
                ForEach(SettingsCategory.allCases) { category in
                    SettingsCategoryButton(
                        category: category,
                        selected: selection == category,
                        action: { selection = category }
                    )
                    .background {
                        if selection == category {
                            let shape = RoundedRectangle(cornerRadius: SettingsLayout.sidebarCornerRadius, style: .continuous)
                            // One highlight glides between rows; Reduce Motion
                            // gives each row its own id so it only crossfades.
                            shape
                                .fill(BoardDarkSurfaceStyle.cardActiveFill)
                                .matchedGeometryEffect(
                                    id: reduceMotion ? category.id : "selection",
                                    in: selectionHighlight
                                )
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .animation(RelayMotion.change(reduceMotion: reduceMotion), value: selection)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
        .background(BoardDarkSurfaceStyle.panelFill)
        .onMoveCommand { direction in
            switch direction {
            case .up:
                selection = SettingsCategory.category(before: selection)
            case .down:
                selection = SettingsCategory.category(after: selection)
            default:
                break
            }
        }
    }
}

private struct SettingsCategoryButton: View {
    let category: SettingsCategory
    let selected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The selected fill is drawn by the sidebar so it can glide between rows.
        let presentation = SettingsNavigationPresentation.resolve(
            selected: selected,
            isHovered: isHovered,
            isFocused: isFocused,
            reduceMotion: reduceMotion
        )

        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                LucideImage(category.icon, size: 16)
                    .frame(width: 18)
                    .foregroundStyle(SettingsSurfaceColor.primaryText.opacity(presentation.foregroundOpacity))

                Text(category.navigationLabel)
                    .font(AppTypography.font(.button))
                    .foregroundStyle(SettingsSurfaceColor.primaryText.opacity(presentation.foregroundOpacity))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: SettingsLayout.sidebarRowHeight, alignment: .leading)
            .background {
                ZStack {
                    // Hover fills the row with the skeleton loader's
                    // shimmering dots; a selected row keeps its solid fill.
                    FluxDotsBackground(
                        cornerRadius: SettingsLayout.sidebarCornerRadius,
                        style: .standard,
                        isVisible: isHovered && !selected
                    )
                    RoundedRectangle(cornerRadius: SettingsLayout.sidebarCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(presentation.fillOverlayOpacity))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sidebarCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SettingsLayout.sidebarCornerRadius, style: .continuous))
        }
        .buttonStyle(.graphicalPress)
        .focusable()
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(presentation.animationDuration > 0 ? RelayMotion.hover : nil, value: presentation)
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .graphicalTooltip(category.title)
    }
}
