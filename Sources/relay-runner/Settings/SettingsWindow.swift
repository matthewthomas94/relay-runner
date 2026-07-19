import SwiftUI

struct SettingsWindow: View {
    @Bindable var appState: AppState
    @Bindable var onboardingPresentation: OnboardingPresentationState

    init(appState: AppState) {
        self.appState = appState
        self.onboardingPresentation = appState.onboarding.presentation
    }

    var body: some View {
        SettingsContent(
            appState: appState,
            onboardingPresentation: onboardingPresentation,
            style: .window
        )
    }
}

struct WorkspaceSettingsPanel: View {
    @Bindable var appState: AppState
    @Bindable var onboardingPresentation: OnboardingPresentationState
    let onOpenExternalWindow: () -> Void

    init(
        appState: AppState,
        onOpenExternalWindow: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.onboardingPresentation = appState.onboarding.presentation
        self.onOpenExternalWindow = onOpenExternalWindow
    }

    var body: some View {
        SettingsContent(
            appState: appState,
            onboardingPresentation: onboardingPresentation,
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
        case .window: return EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16)
        case .workspace: return EdgeInsets(top: 12, leading: 18, bottom: 14, trailing: 18)
        }
    }

    var fixedFrame: (width: CGFloat, height: CGFloat)? {
        switch self {
        case .window: return (860, 640)
        case .workspace: return nil
        }
    }

    var detailMaxWidth: CGFloat {
        switch self {
        case .window: return 620
        case .workspace: return SettingsLayout.detailMaxWidth
        }
    }

    var usesStandaloneChrome: Bool {
        self == .window
    }

    var embeddedCornerRadius: CGFloat {
        usesStandaloneChrome ? 0 : BoardDarkSurfaceStyle.columnCornerRadius
    }

    var showsEmbeddedHairline: Bool {
        !usesStandaloneChrome
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case status
    case speechToText
    case textToSpeech
    case general
    case awareness

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "Status"
        case .speechToText: return "Speech-to-Text"
        case .textToSpeech: return "Text-to-Speech"
        case .general: return "General"
        case .awareness: return "Awareness"
        }
    }

    var subtitle: String {
        switch self {
        case .status: return "Permissions and runtime"
        case .speechToText: return "Input model and trigger"
        case .textToSpeech: return "Voice and playback"
        case .general: return "Provider and workspace"
        case .awareness: return "Overlay visibility"
        }
    }

    var navigationLabel: String { title }

    var systemImage: String {
        switch self {
        case .status: return "checkmark.shield"
        case .speechToText: return "mic"
        case .textToSpeech: return "speaker.wave.2"
        case .general: return "gearshape"
        case .awareness: return "eye"
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

    static func visibleSelection(
        current: SettingsCategory,
        onboardingActive: Bool
    ) -> SettingsCategory {
        onboardingActive ? .status : current
    }
}

private struct SettingsContent: View {
    @Bindable var appState: AppState
    @Bindable var onboardingPresentation: OnboardingPresentationState
    let style: SettingsContentStyle
    let onOpenExternalWindow: () -> Void

    @State private var draft: AppConfig
    @State private var saving = false
    @State private var selectedCategory: SettingsCategory = .status
    @State private var scrollTarget: SettingsCategory = .status

    init(
        appState: AppState,
        onboardingPresentation: OnboardingPresentationState,
        style: SettingsContentStyle,
        onOpenExternalWindow: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.onboardingPresentation = onboardingPresentation
        self.style = style
        self.onOpenExternalWindow = onOpenExternalWindow
        self._draft = State(initialValue: appState.config)
    }

    private var hasChanges: Bool { draft != appState.config }
    private var onboardingActive: Bool { onboardingPresentation.isPresented }
    private var visibleCategory: SettingsCategory {
        SettingsCategory.visibleSelection(
            current: selectedCategory,
            onboardingActive: onboardingActive
        )
    }

    private var sidebarSelection: Binding<SettingsCategory> {
        Binding(
            get: { visibleCategory },
            set: { newValue in
                guard !onboardingActive else { return }
                selectedCategory = newValue
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsCategorySidebar(
                selection: sidebarSelection,
                style: style
            )
            .frame(width: style.sidebarWidth)

            Rectangle()
                .fill(SettingsSurfaceColor.divider)
                .frame(width: 1)

            VStack(spacing: 0) {
                SettingsDetailHeader(
                    presentation: onboardingActive
                        ? SettingsDetailHeaderPresentation(onboarding: onboardingPresentation.detail)
                        : SettingsDetailHeaderPresentation(category: visibleCategory),
                    style: style
                )
                SettingsDivider()
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: 0)
                                .id(visibleCategory)
                            selectedDetail
                                .padding(style.detailPadding)
                                .frame(maxWidth: style.detailMaxWidth, alignment: .topLeading)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.bottom, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onChange(of: scrollTarget) { _, target in
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                SettingsDivider()
                footer
            }
        }
        .background(BoardDarkSurfaceStyle.panelFill)
        .foregroundStyle(SettingsSurfaceColor.primaryText)
        .tint(SettingsSurfaceColor.focusRing)
        .environment(\.colorScheme, .dark)
        .frame(width: style.fixedFrame?.width, height: style.fixedFrame?.height)
        .clipShape(RoundedRectangle(cornerRadius: style.embeddedCornerRadius, style: .continuous))
        .overlay {
            if style.showsEmbeddedHairline {
                RoundedRectangle(cornerRadius: style.embeddedCornerRadius, style: .continuous)
                    .stroke(BoardDarkSurfaceStyle.border, lineWidth: 1)
            }
        }
        .onChange(of: appState.config) { _, newValue in
            draft = newValue
        }
        .onChange(of: selectedCategory) { _, newValue in
            scrollTarget = newValue
        }
        .onChange(of: onboardingActive) { _, isActive in
            guard isActive else { return }
            selectedCategory = .status
            scrollTarget = .status
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        if onboardingActive, let rootView = onboardingPresentation.rootView {
            if style == .workspace {
                ZStack(alignment: .topLeading) {
                    rootView
                        .opacity(onboardingPresentation.contentVisible ? 1 : 0)
                        .accessibilityHidden(!onboardingPresentation.contentVisible)
                    if !onboardingPresentation.contentVisible {
                        OnboardingPermissionWaitView()
                    }
                }
            } else {
                OnboardingRoutedToWorkspaceView(openWorkspace: appState.showWorkspaceSettings)
            }
        } else {
            switch visibleCategory {
        case .status:
            StatusSettingsTab(appState: appState)
        case .speechToText:
            STTSettingsTab(config: $draft.stt)
        case .textToSpeech:
            TTSSettingsTab(config: $draft.tts)
        case .general:
            GeneralSettingsTab(
                config: $draft.general,
                onOpenExternalWindow: onOpenExternalWindow
            )
        case .awareness:
            AwarenessSettingsTab(config: $draft.awareness)
            }
        }
    }

    private var footer: some View {
        if onboardingActive {
            if style == .workspace {
                return AnyView(onboardingFooter)
            }
            return AnyView(onboardingRouteFooter)
        }
        return AnyView(settingsFooter)
    }

    private var settingsFooter: some View {
        let presentation = SettingsFooterPresentation(hasChanges: hasChanges)
        return HStack(spacing: 12) {
            Image(systemName: presentation.iconName)
                .font(AppTypography.symbolFont(size: 10, weight: .semibold))
                .foregroundStyle(presentation.iconColor)
                .accessibilityHidden(true)

            Text(presentation.statusText)
                .font(AppTypography.font(.settingsDescription))
                .foregroundStyle(presentation.textColor)

            Spacer(minLength: 0)

            SettingsActionButton(
                title: "Revert",
                systemImage: "arrow.uturn.backward",
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
        .padding(style.footerPadding)
        .frame(maxWidth: style.detailMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var onboardingRouteFooter: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(AppTypography.symbolFont(size: 10, weight: .semibold))
                .foregroundStyle(SettingsSurfaceColor.relayAccent)
                .accessibilityHidden(true)

            Text("Setup walkthrough")
                .font(AppTypography.font(.settingsDescription))
                .foregroundStyle(SettingsSurfaceColor.secondaryText)

            Spacer(minLength: 0)

            SettingsActionButton(
                title: "Open Workspace Settings",
                systemImage: "rectangle.connected.to.line.below",
                prominence: .primary,
                action: appState.showWorkspaceSettings
            )
        }
        .padding(style.footerPadding)
        .frame(maxWidth: style.detailMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var onboardingFooter: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(AppTypography.symbolFont(size: 10, weight: .semibold))
                .foregroundStyle(SettingsSurfaceColor.relayAccent)
                .accessibilityHidden(true)

            Text(onboardingPresentation.detail.progress ?? "Setup walkthrough")
                .font(AppTypography.font(.settingsDescription))
                .foregroundStyle(SettingsSurfaceColor.secondaryText)

            Spacer(minLength: 0)

            if let secondary = onboardingPresentation.secondaryAction {
                onboardingActionButton(secondary)
            }
            if let primary = onboardingPresentation.primaryAction {
                onboardingActionButton(primary)
            }
        }
        .padding(style.footerPadding)
        .frame(maxWidth: style.detailMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func onboardingActionButton(_ action: OnboardingFooterAction) -> some View {
        switch action.shortcut {
        case .default:
            onboardingActionButtonContent(action)
                .keyboardShortcut(.defaultAction)
        case .cancel:
            onboardingActionButtonContent(action)
                .keyboardShortcut(.cancelAction)
        case nil:
            onboardingActionButtonContent(action)
        }
    }

    private func onboardingActionButtonContent(_ action: OnboardingFooterAction) -> SettingsActionButton {
        SettingsActionButton(
            title: action.title,
            systemImage: action.systemImage,
            prominence: action.prominence,
            isEnabled: action.isEnabled,
            accessibilityLabel: action.accessibilityLabel,
            helpText: action.helpText,
            action: action.perform
        )
    }
}

private struct SettingsFooterSaveButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        SettingsActionButton(
            title: "Save",
            systemImage: "checkmark",
            prominence: .primary,
            isEnabled: isEnabled,
            accessibilityLabel: "Save settings",
            helpText: isEnabled ? "Save settings" : "No settings changes to save",
            action: action
        )
        .keyboardShortcut(.defaultAction)
    }
}

enum SettingsSemanticColor: Equatable {
    case relayAccent
    case success
    case error
    case idle

    var color: Color {
        switch self {
        case .relayAccent: return SettingsSurfaceColor.relayAccent
        case .success: return SettingsSurfaceColor.success
        case .error: return SettingsSurfaceColor.error
        case .idle: return SettingsSurfaceColor.mutedText
        }
    }
}

struct SettingsFooterPresentation: Equatable {
    let hasChanges: Bool

    var iconName: String {
        hasChanges ? "circle.fill" : "checkmark.circle.fill"
    }

    var statusText: String {
        hasChanges ? "Unsaved changes" : "Settings are up to date"
    }

    var iconSemanticColor: SettingsSemanticColor {
        hasChanges ? .relayAccent : .idle
    }

    var iconColor: Color { iconSemanticColor.color }

    var textColor: Color {
        hasChanges ? SettingsSurfaceColor.relayAccent : SettingsSurfaceColor.secondaryText
    }

    var actionTint: Color { hasChanges ? SettingsSurfaceColor.dirtyAccent : SettingsSurfaceColor.mutedText }
}

struct SettingsDetailHeaderPresentation: Equatable {
    let title: String
    let subtitle: String
    let trailingText: String?

    init(category: SettingsCategory) {
        self.title = category.title
        self.subtitle = category.subtitle
        self.trailingText = nil
    }

    init(onboarding: OnboardingDetailPresentation) {
        self.title = onboarding.title
        self.subtitle = onboarding.subtitle
        self.trailingText = onboarding.progress
    }
}

private struct SettingsDetailHeader: View {
    let presentation: SettingsDetailHeaderPresentation
    let style: SettingsContentStyle

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(AppTypography.font(.screenTitle))
                    .foregroundStyle(SettingsSurfaceColor.primaryText)
                Text(presentation.subtitle)
                    .font(AppTypography.font(.settingsDescription))
                    .foregroundStyle(SettingsSurfaceColor.secondaryText)
            }
            Spacer(minLength: 0)
            if let trailingText = presentation.trailingText {
                Text(trailingText)
                    .font(AppTypography.font(.label))
                    .foregroundStyle(SettingsSurfaceColor.secondaryText)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: style.detailMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingPermissionWaitView: View {
    var body: some View {
        SettingsStack {
            SettingsSection("Permission Setup") {
                SettingsRow {
                    ProgressView()
                        .controlSize(.small)
                    SettingsRowLabel(
                        "Waiting for macOS",
                        description: "Continue in the system prompt or Privacy & Security. Relay Runner resumes this walkthrough here when the permission step finishes."
                    )
                }
            }
        }
    }
}

private struct OnboardingRoutedToWorkspaceView: View {
    let openWorkspace: () -> Void

    var body: some View {
        SettingsStack {
            SettingsSection("Setup Walkthrough") {
                SettingsRow {
                    Image(systemName: "rectangle.connected.to.line.below")
                        .font(AppTypography.symbolFont(size: 17, weight: .semibold))
                        .foregroundStyle(SettingsSurfaceColor.relayAccent)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    SettingsRowLabel(
                        "Open in Workspace Settings",
                        description: "The walkthrough is hosted in the Workspace Settings detail plane so the Workspace navigation and Settings sidebar stay visible."
                    )
                    Spacer(minLength: 0)
                    SettingsActionButton(
                        title: "Open",
                        systemImage: "arrow.right",
                        prominence: .secondary,
                        action: openWorkspace
                    )
                }
            }
        }
    }
}

private struct SettingsCategorySidebar: View {
    @Binding var selection: SettingsCategory
    let style: SettingsContentStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(AppTypography.font(.workspaceHeading))
                .foregroundStyle(SettingsSurfaceColor.primaryText)
                .padding(.horizontal, 16)
                .padding(.top, style == .workspace ? 18 : 16)

            VStack(spacing: 4) {
                ForEach(SettingsCategory.allCases) { category in
                    SettingsCategoryButton(
                        category: category,
                        selected: selection == category,
                        action: { selection = category }
                    )
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
        .background(BoardDarkSurfaceStyle.contentFill.opacity(0.48))
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
        let presentation = SettingsNavigationPresentation.resolve(
            selected: selected,
            isHovered: isHovered,
            isFocused: isFocused,
            reduceMotion: reduceMotion
        )

        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: category.systemImage)
                    .font(AppTypography.symbolFont(size: 13, weight: .semibold))
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
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.sidebarCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(presentation.fillOpacity))
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sidebarCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.sidebarCornerRadius, style: .continuous)
                    .stroke(SettingsSurfaceColor.focusRing.opacity(presentation.strokeOpacity), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: SettingsLayout.sidebarCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: presentation.animationDuration), value: presentation)
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(category.title)
    }
}
