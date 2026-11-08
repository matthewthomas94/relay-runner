import AppKit
import SwiftUI

struct SettingsStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .toggleStyle(SettingsSwitchStyle())
    }
}

struct SettingsSection<Content: View>: View {
    let title: String?
    let badge: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, badge: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.badge = badge
        self.content = content()
    }

    /// Each section is a card: its title and rows on the kit's neutral-2
    /// surface, separated from the next section by space rather than lines.
    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionTitleSpacing) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(AppTypography.font(.sectionHeading))
                        .foregroundStyle(SettingsSurfaceColor.primaryText)
                    if let badge {
                        Text(badge)
                            .font(AppTypography.font(.metadata))
                            .foregroundStyle(SettingsSurfaceColor.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(SettingsSurfaceColor.rowFill, in: Capsule())
                    }
                }
                .padding(.top, SettingsLayout.cardPadding - SettingsLayout.rowVerticalPadding)
            }

            VStack(spacing: 0) {
                content
            }
        }
        .padding(.horizontal, SettingsLayout.cardPadding)
        .padding(.vertical, SettingsLayout.cardPadding - SettingsLayout.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SettingsSurfaceColor.cardFill,
            in: RoundedRectangle(cornerRadius: SettingsLayout.cardCornerRadius, style: .continuous)
        )
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
                .toggleStyle(SettingsSwitchStyle(showsLabel: false))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, description: String? = nil) {
        self.title = title
        self.description = description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            RelaySwap(title, style: .text, alignment: .leading) { title in
                Text(title)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(SettingsSurfaceColor.primaryText)
            }
            if let description {
                RelaySwap(description, style: .text, alignment: .leading) { description in
                    Text(description)
                        .font(AppTypography.font(.settingsDescription))
                        .foregroundStyle(SettingsSurfaceColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.relayText)
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: description)
    }
}

/// A dropdown drawn like the Workspace ticket panel's project picker.
struct SettingsMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(label: String, value: Value)]
    @State private var isPresented = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, selection: Binding<Value>, options: [(label: String, value: Value)]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    private var selectedLabel: String {
        options.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8) {
                RelaySwap(selectedLabel, style: .text, alignment: .leading) { selectedLabel in
                    Text(selectedLabel)
                        .font(AppTypography.font(.field))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                LucideImage(.chevronDown, size: 12)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(isEnabled ? SettingsSurfaceColor.primaryText : SettingsSurfaceColor.disabledText)
            .padding(.horizontal, GraphicalTheme.spaceS)
            .frame(maxWidth: .infinity)
            .frame(height: GraphicalTheme.controlHeight)
            // Kit select: a black control on the panel, neutral-3 when disabled,
            // with the accent focus ring while open or focused.
            .background(
                RoundedRectangle(cornerRadius: GraphicalTheme.radiusS, style: .continuous)
                    .fill(isEnabled ? BoardDarkSurfaceStyle.contentFill : GraphicalTheme.neutral3)
                    .overlay(
                        RoundedRectangle(cornerRadius: GraphicalTheme.radiusS, style: .continuous)
                            .strokeBorder(
                                SettingsSurfaceColor.focusRing.opacity(isEnabled && (isFocused || isPresented) ? 1 : 0),
                                lineWidth: GraphicalTheme.focusRingWidth
                            )
                    )
            )
            .contentShape(
                RoundedRectangle(cornerRadius: GraphicalTheme.radiusS, style: .continuous)
            )
        }
        .buttonStyle(.graphicalPress)
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : RelayMotion.hover, value: isHovered || isFocused || isPresented)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
        .accessibilityValue(selectedLabel)
        .background {
            SettingsDropdownPresenter(isPresented: $isPresented) {
                SettingsMenuOptions(title: title, selection: $selection, options: options) {
                    isPresented = false
                }
                .environment(\.colorScheme, .dark)
            }
        }
    }
}

/// A segmented choice drawn like the Workspace ticket panel's execution-mode toggle.
struct SettingsSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(label: String, value: Value)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(_ title: String, selection: Binding<Value>, options: [(label: String, value: Value)]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    var body: some View {
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isHovered: isHovered, reduceMotion: reduceMotion
        )
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                SettingsSegmentButton(
                    title: option.label,
                    isSelected: selection == option.value,
                    action: { selection = option.value }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: SharedActionButtonMetrics.controlHeight)
        // The kit's tab list: neutral-3, radius m.
        .background(
            RoundedRectangle(cornerRadius: GraphicalTheme.radiusM, style: .continuous)
                .fill(WorkspaceNavigationStyle.listFill)
        )
        .onHover { isHovered = $0 }
        .animation(presentation.animation, value: presentation)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct SettingsSegmentButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var presentation: SettingsActionPresentation {
        SettingsActionPresentation.resolve(
            isEnabled: true,
            isHovered: isHovered,
            isFocused: isFocused,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: GraphicalTheme.radiusS,
            style: .continuous
        )
        // Kit tab triggers sit inside the list's 4 points of padding.
        let selectionInset = WorkspaceNavigationStyle.listPadding

        Button(action: action) {
            Text(title)
                .font(AppTypography.font(.button))
                .foregroundStyle(
                    (isSelected || isHovered || isFocused ? ProgramBoardStyle.primaryText : ProgramBoardStyle.mutedText)
                        .opacity(presentation.foregroundOpacity)
                )
                .frame(maxWidth: .infinity, minHeight: SharedActionButtonMetrics.controlHeight)
                .background {
                    // The selection sits inside the group's stroke; hovering it
                    // shimmers with the Settings sidebar's dots.
                    if isSelected {
                        RoundedRectangle(
                            cornerRadius: GraphicalTheme.radiusS,
                            style: .continuous
                        )
                        .fill(GraphicalTheme.neutral1.opacity(GraphicalTheme.fillThroughDotsOpacity))
                        .graphicalShadow(.s)
                        .background(FluxDotsBackground(
                            cornerRadius: GraphicalTheme.radiusS,
                            style: .standard,
                            isVisible: isHovered
                        ))
                        .padding(selectionInset)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.graphicalPress)
        .focusable(true)
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: presentation.animationDuration), value: presentation)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

enum SettingsLayout {
    /// The gap between section cards, like the gap between Workspace columns.
    static let sectionSpacing: CGFloat = GraphicalTheme.spaceXS
    static let sectionTitleSpacing: CGFloat = GraphicalTheme.spaceXXS
    static let cardPadding: CGFloat = GraphicalTheme.spaceM
    static let cardCornerRadius: CGFloat = GraphicalTheme.radiusM
    static let rowVerticalPadding: CGFloat = 11
    static let labelControlSpacing: CGFloat = 20
    static let controlMaxWidth: CGFloat = 280
    static let detailMaxWidth: CGFloat = .infinity
    static let sidebarRowHeight: CGFloat = GraphicalTheme.controlHeight
    static let sidebarCornerRadius: CGFloat = GraphicalTheme.radiusXS
    static let systemFocusEffectDisabled = true
}

enum SharedActionButtonProminence {
    case primary
    case secondary
    case icon
    /// The danger button: a dark red tint with a red label.
    case danger
}

enum SharedActionButtonMetrics {
    static let controlHeight: CGFloat = GraphicalTheme.controlHeight
    static let cornerRadius: CGFloat = GraphicalTheme.radiusS
    static let horizontalPadding: CGFloat = GraphicalTheme.spaceM
    static let iconSpacing: CGFloat = 6
}

struct SharedActionButtonPalette {
    let foreground: Color
    let fill: Color
    let stroke: Color
}

extension SharedActionButtonPalette {
    /// Kit secondary button: neutral-3 fill, white label, no border.
    static let settingsSecondary = SharedActionButtonPalette(
        foreground: SettingsSurfaceColor.primaryText,
        fill: GraphicalTheme.neutral3,
        stroke: SettingsSurfaceColor.focusRing
    )

    /// Danger button: a dark red tint with a red label and icon.
    static let settingsDanger = SharedActionButtonPalette(
        foreground: GraphicalTheme.dangerForeground,
        fill: GraphicalTheme.dangerFill,
        stroke: SettingsSurfaceColor.focusRing
    )

    /// Kit primary button: white fill, black label.
    static let settingsPrimary = SharedActionButtonPalette(
        foreground: GraphicalTheme.neutral1,
        fill: GraphicalTheme.neutral10,
        stroke: SettingsSurfaceColor.focusRing
    )
}

struct SharedActionButtonSurface: View {
    let prominence: SharedActionButtonProminence
    let presentation: SettingsActionPresentation
    let palette: SharedActionButtonPalette

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: SharedActionButtonMetrics.cornerRadius,
            style: .continuous
        )

        // Solid kit fills; a disabled button drops to neutral-3. Hover lays the
        // kit's translucent neutral-4 over the fill, or warms a danger tint.
        // Focus draws the accent ring.
        shape
            .fill(presentation.isEnabled ? palette.fill : GraphicalTheme.neutral3)
            // Kit primary and danger buttons lift with the small shadow on hover.
            .graphicalShadow(.s, isVisible: presentation.isHovered && (prominence == .primary || prominence == .danger))
            .overlay(shape.fill(GraphicalTheme.neutral4.opacity(presentation.sharedFillOpacity(for: prominence))))
            .overlay(shape.fill(GraphicalTheme.dangerForeground.opacity(
                prominence == .danger && presentation.isEnabled && presentation.isHovered ? 0.12 : 0
            )))
            .overlay(
                shape.stroke(
                    palette.stroke.opacity(presentation.sharedStrokeOpacity(for: prominence)),
                    lineWidth: GraphicalTheme.focusRingWidth
                )
            )
    }
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
                    SharedActionButtonSurface(
                        prominence: prominence,
                        presentation: presentation,
                        palette: palette
                    )
                )
                .contentShape(shape)
        }
        .buttonStyle(.graphicalPress)
        .disabled(!isEnabled)
        .focusable(isEnabled)
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(presentation.animationDuration > 0 ? RelayMotion.hover : nil, value: presentation)
        .accessibilityLabel(accessibilityLabel)
        .graphicalTooltip(helpText)
    }
}

struct SettingsActionButton: View {
    enum Prominence {
        case primary
        case secondary
        case icon
        case danger
    }

    let title: String
    let icon: LucideIcon?
    var prominence: Prominence = .secondary
    var isEnabled = true
    var accessibilityLabel: String?
    var helpText: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SharedActionButtonChrome(
            prominence: sharedProminence,
            isEnabled: isEnabled,
            accessibilityLabel: accessibilityLabel ?? title,
            helpText: helpText ?? title,
            palette: palette,
            action: action,
            label: {
            HStack(spacing: icon == nil || prominence == .icon ? 0 : SharedActionButtonMetrics.iconSpacing) {
                if let icon {
                    // Lucide icons sit at 1em of the label.
                    RelaySwap(icon) { icon in
                        LucideImage(icon, size: GraphicalTheme.textS)
                    }
                }
                if prominence != .icon {
                    RelaySwap(title, style: .text, alignment: .leading) { title in
                        Text(title)
                            .font(AppTypography.font(prominence == .secondary ? .button : .primaryButton))
                    }
                }
            }
            }
        )
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: title)
    }

    private var palette: SharedActionButtonPalette {
        switch prominence {
        case .primary: return .settingsPrimary
        case .danger: return .settingsDanger
        case .secondary, .icon: return .settingsSecondary
        }
    }

    private var sharedProminence: SharedActionButtonProminence {
        switch prominence {
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .icon:
            return .icon
        case .danger:
            return .danger
        }
    }
}

struct SettingsInlineStatus: View {
    let text: String?
    let semanticColor: SettingsSemanticColor
    var reservedWidth: CGFloat = 150
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            if let text {
                RelaySwap(text, style: .text, alignment: .trailing) { text in
                    HStack(spacing: 5) {
                        statusIcon
                            .foregroundStyle(semanticColor.color)
                            .accessibilityHidden(true)
                        Text(text)
                            .font(AppTypography.font(.settingsDescription))
                            .foregroundStyle(semanticColor.color)
                            .lineLimit(1)
                    }
                }
                .transition(.relayText)
            }
        }
        .frame(width: reservedWidth, alignment: .trailing)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text ?? "")
        .accessibilityHidden(text == nil)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch semanticColor {
        case .neutralAccent: Circle().frame(width: 6, height: 6).frame(width: 12, height: 12)
        case .success: LucideImage(.circleCheck, size: 12)
        case .error: LucideImage(.octagonX, size: 12)
        case .idle: LucideImage(.circle, size: 12)
        }
    }
}

enum SettingsNavigationPresentation {
    static func resolve(
        selected: Bool,
        isHovered: Bool,
        isFocused: Bool,
        reduceMotion: Bool
    ) -> ProgramBoardInteractionPresentation {
        ProgramBoardInteractionPresentation.resolve(
            surface: .ticketCard,
            isSelected: selected || isHovered,
            isHovered: isHovered,
            isFocused: isFocused,
            reduceMotion: reduceMotion
        )
    }
}

struct SettingsActionPresentation: Equatable {
    let isEnabled: Bool
    var isHovered = false
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
                isEnabled: false,
                fillOpacity: 0,
                strokeOpacity: 0,
                neutralFillOpacity: 0,
                neutralStrokeOpacity: 0,
                foregroundOpacity: boardPresentation.foregroundOpacity,
                accentOpacity: 0,
                animationDuration: boardPresentation.animationDuration
            )
        }

        // Kit states: primary has no hover tint; secondary hovers with neutral-4
        // at 20%; focus is the accent ring and nothing else.
        return SettingsActionPresentation(
            isEnabled: true,
            isHovered: isHovered,
            fillOpacity: 0,
            strokeOpacity: isFocused ? 1 : 0,
            neutralFillOpacity: isHovered ? 0.2 : 0,
            neutralStrokeOpacity: isFocused ? 1 : 0,
            foregroundOpacity: boardPresentation.foregroundOpacity,
            accentOpacity: isFocused ? 1 : 0,
            animationDuration: boardPresentation.animationDuration
        )
    }
}

extension SettingsActionPresentation {
    func sharedFillOpacity(for prominence: SharedActionButtonProminence) -> Double {
        switch prominence {
        case .primary, .danger:
            return fillOpacity
        case .secondary, .icon:
            return neutralFillOpacity
        }
    }

    func sharedStrokeOpacity(for prominence: SharedActionButtonProminence) -> Double {
        switch prominence {
        case .primary, .danger:
            return strokeOpacity
        case .secondary, .icon:
            return neutralStrokeOpacity
        }
    }
}

enum SettingsSurfaceColor {
    static let primaryTextNSColor = GraphicalTheme.neutral10NSColor
    static let neutralAccentNSColor = GraphicalTheme.neutral10NSColor
    static let secondaryTextNSColor = GraphicalTheme.neutral8NSColor
    static let mutedTextNSColor = GraphicalTheme.neutral7NSColor
    static let disabledTextNSColor = GraphicalTheme.neutral6NSColor
    static let errorNSColor = GraphicalTheme.errorNSColor
    static let successNSColor = NSColor(srgbRed: 52 / 255, green: 211 / 255, blue: 153 / 255, alpha: 1)

    static let primaryText = Color(nsColor: primaryTextNSColor)
    static let secondaryText = Color(nsColor: secondaryTextNSColor)
    static let mutedText = Color(nsColor: mutedTextNSColor)
    static let disabledText = Color(nsColor: disabledTextNSColor)
    static let neutralAccent = Color(nsColor: neutralAccentNSColor)
    static let dirtyAccent = neutralAccent
    static let success = Color(nsColor: successNSColor)
    static let error = Color(nsColor: errorNSColor)
    static let rowFill = GraphicalTheme.neutral3.opacity(GraphicalTheme.fillThroughDotsOpacity)
    static let rowFillHovered = GraphicalTheme.neutral4.opacity(GraphicalTheme.fillThroughDotsOpacity)
    static let rowFillSelected = GraphicalTheme.neutral3
    static let rowFillFocused = GraphicalTheme.neutral4
    /// Settings cards and the sidebar: the kit's neutral-2 surface on the black page.
    static let cardFill = GraphicalTheme.neutral2
    /// The kit separator: a one-pixel neutral-4 line.
    static let divider = GraphicalTheme.neutral4
    /// The kit focus ring: neutral-10 at 20%.
    static let focusRing = GraphicalTheme.focusRing
}
