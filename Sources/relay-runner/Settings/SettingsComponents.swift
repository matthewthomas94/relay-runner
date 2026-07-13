import SwiftUI

struct SettingsStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(AppTypography.font(.sectionHeading))
                    .foregroundStyle(SettingsSurfaceColor.primaryText)
            }

            VStack(spacing: 0) {
                content
            }
            .background(SettingsSurfaceColor.rowFill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SettingsSurfaceColor.rowBorder, lineWidth: 1)
            )
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsSurfaceColor.divider)
            .frame(height: 1)
    }
}

enum SettingsSurfaceColor {
    static let primaryText = Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.98)
    static let secondaryText = Color(.sRGB, red: 148 / 255, green: 163 / 255, blue: 184 / 255, opacity: 0.95)
    static let mutedText = Color(.sRGB, red: 148 / 255, green: 163 / 255, blue: 184 / 255, opacity: 0.72)
    static let rowFill = Color.white.opacity(0.035)
    static let rowFillHovered = Color.white.opacity(0.055)
    static let rowFillSelected = Color.white.opacity(0.09)
    static let rowBorder = Color.white.opacity(0.075)
    static let divider = Color.white.opacity(0.075)
    static let focusRing = Color(.sRGB, red: 125 / 255, green: 211 / 255, blue: 252 / 255, opacity: 0.72)
}
