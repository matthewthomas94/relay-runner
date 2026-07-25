import AppKit
import SwiftUI

struct SettingsStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionTitleSpacing) {
            if let title {
                Text(title)
                    .font(AppTypography.font(.sectionHeading))
                    .foregroundStyle(SettingsSurfaceColor.primaryText)
            }

            VStack(spacing: 0) {
                content
            }
        }
    }
}

struct SettingsRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            content
        }
        .font(AppTypography.font(.body))
        .foregroundStyle(SettingsSurfaceColor.primaryText)
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsControlRow<Control: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let control: Control

    init(
        _ title: String,
        description: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        SettingsRow {
            SettingsRowLabel(title, description: description)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: SettingsLayout.labelControlSpacing)
            control
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: SettingsLayout.controlMaxWidth, alignment: .trailing)
        }
    }
}

struct SettingsStackedControlRow<Control: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let control: Control

    init(
        _ title: String,
        description: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 8) {
                SettingsRowLabel(title, description: description)
                control
                    .controlSize(.small)
            }
        }
    }
}

struct SettingsRowLabel: View {
    let title: String
    let description: String?

    init(_ title: String, description: String? = nil) {
        self.title = title
        self.description = description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppTypography.font(.body))
                .foregroundStyle(SettingsSurfaceColor.primaryText)
            if let description {
                Text(description)
                    .font(AppTypography.font(.settingsDescription))
                    .foregroundStyle(SettingsSurfaceColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsSurfaceColor.divider)
            .frame(height: 1)
    }
}

enum SettingsLayout {
    static let sectionSpacing: CGFloat = 24
    static let sectionTitleSpacing: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 11
    static let labelControlSpacing: CGFloat = 20
    static let controlMaxWidth: CGFloat = 280
    static let detailMaxWidth: CGFloat = 680
    static let sidebarRowHeight: CGFloat = 32
    static let sidebarCornerRadius: CGFloat = 6
    static let systemFocusEffectDisabled = true
}

enum SharedActionButtonProminence {
    case primary
    case secondary
    case icon
}

enum SharedActionButtonMetrics {
    static let controlHeight: CGFloat = 28
    static let cornerRadius: CGFloat = SettingsLayout.sidebarCornerRadius
    static let horizontalPadding: CGFloat = 11
    static let iconSpacing: CGFloat = 6
}

struct SharedActionButtonPalette {
    let foreground: Color
    let fill: Color
    let stroke: Color
}

struct SharedActionButtonChrome<Label: View>: View {
    let prominence: SharedActionButtonProminence
    let isEnabled: Bool
    let accessibilityLabel: String
    let helpText: String
    let palette: SharedActionButtonPalette
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(
        prominence: SharedActionButtonProminence,
        isEnabled: Bool,
        accessibilityLabel: String,
        helpText: String,
        palette: SharedActionButtonPalette,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.prominence = prominence
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.helpText = helpText
        self.palette = palette
        self.action = action
        self.label = label
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let presentation = SettingsActionPresentation.resolve(
            isEnabled: isEnabled,
            isHovered: isHovered,
            isFocused: isFocused,
            reduceMotion: reduceMotion
        )
        let shape = RoundedRectangle(cornerRadius: SharedActionButtonMetrics.cornerRadius, style: .continuous)

        Button(action: action) {
            label()
                .foregroundStyle(palette.foreground.opacity(presentation.foregroundOpacity))
                .padding(.horizontal, prominence == .icon ? 0 : SharedActionButtonMetrics.horizontalPadding)
                .frame(
                    width: prominence == .icon ? SharedActionButtonMetrics.controlHeight : nil,
                    height: SharedActionButtonMetrics.controlHeight
                )
                .background(
                    shape.fill(palette.fill.opacity(fillOpacity(from: presentation)))
                )
                .overlay(
                    shape.stroke(palette.stroke.opacity(strokeOpacity(from: presentation)), lineWidth: 1)
                )
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focusable(isEnabled)
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: presentation.animationDuration), value: presentation)
        .accessibilityLabel(accessibilityLabel)
        .help(helpText)
    }

    private func fillOpacity(from presentation: SettingsActionPresentation) -> Double {
        switch prominence {
        case .primary:
            return presentation.fillOpacity
        case .secondary, .icon:
            return presentation.neutralFillOpacity
        }
    }

    private func strokeOpacity(from presentation: SettingsActionPresentation) -> Double {
        switch prominence {
        case .primary:
            return presentation.strokeOpacity
        case .secondary, .icon:
            return presentation.neutralStrokeOpacity
        }
    }
}

struct SettingsActionButton: View {
    enum Prominence {
        case primary
        case secondary
        case icon
    }

    let title: String
    let systemImage: String?
    var prominence: Prominence = .secondary
    var isEnabled = true
    var accessibilityLabel: String?
    var helpText: String?
    let action: () -> Void

    var body: some View {
        SharedActionButtonChrome(
            prominence: sharedProminence,
            isEnabled: isEnabled,
            accessibilityLabel: accessibilityLabel ?? title,
            helpText: helpText ?? title,
            palette: SharedActionButtonPalette(
                foreground: foregroundColor,
                fill: fillColor,
                stroke: strokeColor
            ),
            action: action,
            label: {
            HStack(spacing: systemImage == nil || prominence == .icon ? 0 : SharedActionButtonMetrics.iconSpacing) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(AppTypography.symbolFont(size: prominence == .icon ? 12 : 10, weight: .bold))
                        .accessibilityHidden(true)
                }
                if prominence != .icon {
                    Text(title)
                        .font(AppTypography.font(.button))
                }
            }
            }
        )
    }

    private var fillColor: Color {
        prominence == .primary ? SettingsSurfaceColor.neutralAccent : Color.white
    }

    private var strokeColor: Color {
        prominence == .primary ? SettingsSurfaceColor.neutralAccent : SettingsSurfaceColor.focusRing
    }

    private var foregroundColor: Color {
        prominence == .primary ? SettingsSurfaceColor.primaryText : SettingsSurfaceColor.primaryText
    }

    private var sharedProminence: SharedActionButtonProminence {
        switch prominence {
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .icon:
            return .icon
        }
    }
}

struct SettingsInlineStatus: View {
    let text: String?
    let semanticColor: SettingsSemanticColor
    var reservedWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 5) {
            if let text {
                Image(systemName: iconName)
                    .font(AppTypography.symbolFont(size: 10, weight: .semibold))
                    .foregroundStyle(semanticColor.color)
                    .accessibilityHidden(true)
                Text(text)
                    .font(AppTypography.font(.settingsDescription))
                    .foregroundStyle(semanticColor.color)
                    .lineLimit(1)
            }
        }
        .frame(width: reservedWidth, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text ?? "")
        .accessibilityHidden(text == nil)
    }

    private var iconName: String {
        switch semanticColor {
        case .neutralAccent: return "circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .idle: return "circle"
        }
    }
}

struct SettingsNavigationPresentation: Equatable {
    let fillOpacity: Double
    let strokeOpacity: Double
    let foregroundOpacity: Double
    let animationDuration: Double

    static func resolve(
        selected: Bool,
        isHovered: Bool,
        isFocused: Bool,
        reduceMotion: Bool
    ) -> SettingsNavigationPresentation {
        let duration = reduceMotion ? 0 : ProgramBoardInteractionPresentation.motionDuration

        if selected {
            return SettingsNavigationPresentation(
                fillOpacity: WorkspaceNavigationStyle.selectedFillOpacity,
                strokeOpacity: isFocused ? 0.24 : 0,
                foregroundOpacity: WorkspaceNavigationStyle.activeTextOpacity,
                animationDuration: duration
            )
        }

        if isFocused {
            return SettingsNavigationPresentation(
                fillOpacity: WorkspaceNavigationStyle.focusedFillOpacity,
                strokeOpacity: 0.24,
                foregroundOpacity: WorkspaceNavigationStyle.activeTextOpacity,
                animationDuration: duration
            )
        }

        if isHovered {
            return SettingsNavigationPresentation(
                fillOpacity: WorkspaceNavigationStyle.hoveredFillOpacity,
                strokeOpacity: 0,
                foregroundOpacity: WorkspaceNavigationStyle.activeTextOpacity,
                animationDuration: duration
            )
        }

        return SettingsNavigationPresentation(
            fillOpacity: 0,
            strokeOpacity: 0,
            foregroundOpacity: WorkspaceNavigationStyle.inactiveTextOpacity,
            animationDuration: duration
        )
    }
}

struct SettingsActionPresentation: Equatable {
    let fillOpacity: Double
    let strokeOpacity: Double
    let neutralFillOpacity: Double
    let neutralStrokeOpacity: Double
    let foregroundOpacity: Double
    let accentOpacity: Double
    let animationDuration: Double

    static func resolve(
        isEnabled: Bool,
        isHovered: Bool,
        isFocused: Bool,
        reduceMotion: Bool
    ) -> SettingsActionPresentation {
        let boardPresentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control,
            isEnabled: isEnabled,
            isSelected: isEnabled,
            isHovered: isHovered,
            isFocused: isFocused,
            reduceMotion: reduceMotion
        )

        guard isEnabled else {
            return SettingsActionPresentation(
                fillOpacity: 0.02,
                strokeOpacity: 0.10,
                neutralFillOpacity: 0.02,
                neutralStrokeOpacity: 0.10,
                foregroundOpacity: boardPresentation.foregroundOpacity,
                accentOpacity: 0,
                animationDuration: boardPresentation.animationDuration
            )
        }

        return SettingsActionPresentation(
            fillOpacity: isHovered ? 0.10 : 0.07,
            strokeOpacity: isFocused ? 0.34 : 0.22,
            neutralFillOpacity: isFocused ? 0.08 : (isHovered ? 0.06 : 0.035),
            neutralStrokeOpacity: isFocused ? 0.30 : (isHovered ? 0.18 : 0.12),
            foregroundOpacity: boardPresentation.foregroundOpacity,
            accentOpacity: isFocused ? 0.34 : 0.22,
            animationDuration: boardPresentation.animationDuration
        )
    }
}

enum SettingsSurfaceColor {
    static let primaryTextNSColor = NSColor(srgbRed: 226 / 255, green: 232 / 255, blue: 240 / 255, alpha: 0.98)
    static let neutralAccentNSColor = primaryTextNSColor.withAlphaComponent(1)
    static let secondaryTextNSColor = NSColor(srgbRed: 203 / 255, green: 213 / 255, blue: 225 / 255, alpha: 0.82)
    static let mutedTextNSColor = NSColor(srgbRed: 148 / 255, green: 163 / 255, blue: 184 / 255, alpha: 0.68)
    static let disabledTextNSColor = NSColor(srgbRed: 148 / 255, green: 163 / 255, blue: 184 / 255, alpha: 0.45)
    static let errorNSColor = NSColor(srgbRed: 251 / 255, green: 113 / 255, blue: 133 / 255, alpha: 1)
    static let successNSColor = NSColor(srgbRed: 52 / 255, green: 211 / 255, blue: 153 / 255, alpha: 1)

    static let primaryText = Color(nsColor: primaryTextNSColor)
    static let secondaryText = Color(nsColor: secondaryTextNSColor)
    static let mutedText = Color(nsColor: mutedTextNSColor)
    static let disabledText = Color(nsColor: disabledTextNSColor)
    static let neutralAccent = Color(nsColor: neutralAccentNSColor)
    static let dirtyAccent = neutralAccent
    static let success = Color(nsColor: successNSColor)
    static let error = Color(nsColor: errorNSColor)
    static let rowFill = Color.white.opacity(0.035)
    static let rowFillHovered = Color.white.opacity(0.055)
    static let rowFillSelected = Color.white.opacity(WorkspaceNavigationStyle.selectedFillOpacity)
    static let rowFillFocused = Color.white.opacity(WorkspaceNavigationStyle.focusedFillOpacity)
    static let divider = Color.white.opacity(0.075)
    static let focusRing = neutralAccent.opacity(0.78)
}
