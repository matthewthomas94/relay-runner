import SwiftUI

/// The buttons on the styles board: 44 pt tall, radius 12.
/// - primary: white with a black label, one per screen at most.
/// - secondary: glass (#171a1e at 75%) with a white label.
/// - danger: the secondary surface with a #f41509 label and icon, never a red fill.
struct RelayButtonStyle: ButtonStyle {
    enum Role: Equatable {
        case primary, secondary, danger
    }

    var role: Role
    var height: CGFloat = RelayMetrics.controlHeight
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        RelayButtonBody(configuration: configuration, role: role, height: height, fullWidth: fullWidth)
    }
}

private struct RelayButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let role: RelayButtonStyle.Role
    let height: CGFloat
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RelayMetrics.buttonRadius, style: .continuous)
        configuration.label
            .relayTextStyle(.control)
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .frame(minWidth: height, maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background {
                if role == .primary {
                    RelayGlassBackground(glass: configuration.isPressed ? .primaryPressed : .primary, shape: shape)
                } else {
                    RelayGlassBackground(glass: configuration.isPressed ? .selected : .control, shape: shape)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(RelayMotion.press, value: configuration.isPressed)
            .animation(RelayMotion.enter, value: isEnabled)
            .relayPressed(configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .primary: return RelayColor.neutral1
        case .secondary: return RelayColor.neutral10
        case .danger: return RelayColor.error
        }
    }
}

extension ButtonStyle where Self == RelayButtonStyle {
    static var relayPrimary: RelayButtonStyle { RelayButtonStyle(role: .primary) }
    static var relaySecondary: RelayButtonStyle { RelayButtonStyle(role: .secondary) }
    static var relayDanger: RelayButtonStyle { RelayButtonStyle(role: .danger) }
}

/// A button label: an optional outline icon before the title. With no title
/// it is an icon-only square control.
struct RelayButtonLabel: View {
    let title: String?
    let icon: LucideIcon?

    init(_ title: String? = nil, icon: LucideIcon? = nil) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon { LucideImage(icon, size: 20) }
            if let title { Text(title) }
        }
        .accessibilityElement(children: .combine)
    }
}
