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

enum SettingsSurfaceColor {
    static let relayAccentNSColor = NSColor(srgbRed: 139 / 255, green: 92 / 255, blue: 246 / 255, alpha: 1)
    static let primaryTextNSColor = NSColor(srgbRed: 226 / 255, green: 232 / 255, blue: 240 / 255, alpha: 0.98)
    static let secondaryTextNSColor = NSColor(srgbRed: 148 / 255, green: 163 / 255, blue: 184 / 255, alpha: 0.95)
    static let mutedTextNSColor = NSColor(srgbRed: 148 / 255, green: 163 / 255, blue: 184 / 255, alpha: 0.72)
    static let errorNSColor = NSColor(srgbRed: 248 / 255, green: 113 / 255, blue: 113 / 255, alpha: 1)
    static let successNSColor = NSColor(srgbRed: 74 / 255, green: 222 / 255, blue: 128 / 255, alpha: 1)

    static let primaryText = Color(nsColor: primaryTextNSColor)
    static let secondaryText = Color(nsColor: secondaryTextNSColor)
    static let mutedText = Color(nsColor: mutedTextNSColor)
    static let relayAccent = Color(nsColor: relayAccentNSColor)
    static let dirtyAccent = relayAccent
    static let success = Color(nsColor: successNSColor)
    static let error = Color(nsColor: errorNSColor)
    static let rowFill = Color.white.opacity(0.035)
    static let rowFillHovered = Color.white.opacity(0.055)
    static let rowFillSelected = relayAccent.opacity(0.14)
    static let rowFillFocused = relayAccent.opacity(0.18)
    static let divider = Color.white.opacity(0.075)
    static let focusRing = relayAccent.opacity(0.78)
}
