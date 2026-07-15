import SwiftUI

struct SettingsWindow: View {
    @Bindable var appState: AppState

    var body: some View {
        SettingsContent(appState: appState, style: .window)
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
            .background(BoardDarkSurfaceBackground(cornerRadius: BoardDarkSurfaceStyle.columnCornerRadius))
            .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 10)
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
        case .window: return (720, 560)
        case .workspace: return nil
        }
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

    var systemImage: String {
        switch self {
        case .status: return "checkmark.shield"
        case .speechToText: return "mic"
        case .textToSpeech: return "speaker.wave.2"
        case .general: return "gearshape"
        case .awareness: return "eye"
        }
    }
}

private struct SettingsContent: View {
    @Bindable var appState: AppState
    let style: SettingsContentStyle
    let onOpenExternalWindow: () -> Void

    @State private var draft: AppConfig
    @State private var saving = false
    @State private var selectedCategory: SettingsCategory = .status

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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SettingsCategorySidebar(
                    selection: $selectedCategory,
                    style: style
                )
                .frame(width: style.sidebarWidth)

                Rectangle()
                    .fill(SettingsSurfaceColor.divider)
                    .frame(width: 1)

                VStack(spacing: 0) {
                    SettingsDetailHeader(category: selectedCategory)
                    SettingsDivider()
                    ScrollView(.vertical, showsIndicators: false) {
                        selectedDetail
                            .padding(style.detailPadding)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            SettingsDivider()
            footer
        }
        .background(BoardDarkSurfaceStyle.panelFill)
        .foregroundStyle(SettingsSurfaceColor.primaryText)
        .tint(SettingsSurfaceColor.focusRing)
        .environment(\.colorScheme, .dark)
        .frame(width: style.fixedFrame?.width, height: style.fixedFrame?.height)
        .onChange(of: appState.config) { _, newValue in
            draft = newValue
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch selectedCategory {
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

    private var footer: some View {
        HStack(spacing: 12) {
            Image(systemName: hasChanges ? "circle.fill" : "checkmark.circle.fill")
                .font(AppTypography.symbolFont(size: 10, weight: .semibold))
                .foregroundStyle(hasChanges ? Color.orange : Color.green)
                .accessibilityHidden(true)

            Text(hasChanges ? "Unsaved changes" : "Settings are up to date")
                .font(AppTypography.font(.caption))
                .foregroundStyle(SettingsSurfaceColor.secondaryText)

            Spacer(minLength: 0)

            Button("Save") {
                saving = true
                appState.saveConfig(draft)
                saving = false
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges || saving)
        }
        .padding(style.footerPadding)
    }
}

private struct SettingsDetailHeader: View {
    let category: SettingsCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.title)
                .font(AppTypography.font(.screenTitle))
                .foregroundStyle(SettingsSurfaceColor.primaryText)
            Text(category.subtitle)
                .font(AppTypography.font(.caption))
                .foregroundStyle(SettingsSurfaceColor.secondaryText)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
    }
}

private struct SettingsCategoryButton: View {
    let category: SettingsCategory
    let selected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: category.systemImage)
                    .font(AppTypography.symbolFont(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(selected ? SettingsSurfaceColor.primaryText : SettingsSurfaceColor.secondaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(AppTypography.font(.button))
                        .foregroundStyle(SettingsSurfaceColor.primaryText)
                    Text(category.subtitle)
                        .font(AppTypography.font(.smallCaption))
                        .foregroundStyle(SettingsSurfaceColor.mutedText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if selected {
                    Image(systemName: "chevron.right")
                        .font(AppTypography.symbolFont(size: 10, weight: .semibold))
                        .foregroundStyle(SettingsSurfaceColor.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(buttonFill)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isFocused ? SettingsSurfaceColor.focusRing : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(category.title), \(selected ? "selected" : "not selected")")
        .help(category.title)
    }

    private var buttonFill: Color {
        if selected { return SettingsSurfaceColor.rowFillSelected }
        if isFocused || isHovered { return SettingsSurfaceColor.rowFillHovered }
        return Color.clear
    }
}
