import SwiftUI

struct SettingsMenuOptions<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(label: String, value: Value)]
    let dismiss: () -> Void
    @FocusState private var focusedIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(options.indices, id: \.self) { index in
                        let option = options[index]
                        Button {
                            selection = option.value
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark")
                                    .font(AppTypography.symbolFont(size: 10, weight: .semibold))
                                    .opacity(option.value == selection ? 1 : 0)
                                    .frame(width: 12)
                                    .accessibilityHidden(true)
                                Text(option.label)
                                    .font(AppTypography.font(.action))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .foregroundStyle(SettingsSurfaceColor.primaryText)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(
                                focusedIndex == index ? BoardDarkSurfaceStyle.cardActiveFill : .clear,
                                in: RoundedRectangle(cornerRadius: SettingsLayout.sidebarCornerRadius)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .focused($focusedIndex, equals: index)
                        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
                        .onHover { if $0 { focusedIndex = index } }
                        .accessibilityAddTraits(option.value == selection ? .isSelected : [])
                        .help(option.label)
                        .id(index)
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: min(284, CGFloat(options.count) * 34 + 10))
            .background(BoardDarkSurfaceBackground(cornerRadius: 12))
            .onAppear { focusedIndex = options.firstIndex { $0.value == selection } ?? options.indices.first }
            .onChange(of: focusedIndex) { _, index in
                if let index { proxy.scrollTo(index) }
            }
            .onMoveCommand { direction in
                guard !options.isEmpty else { return }
                let index = focusedIndex ?? 0
                if direction == .down { focusedIndex = min(index + 1, options.count - 1) }
                if direction == .up { focusedIndex = max(index - 1, 0) }
            }
            .onKeyPress(.return) {
                guard let index = focusedIndex, options.indices.contains(index) else { return .ignored }
                selection = options[index].value
                dismiss()
                return .handled
            }
            .onExitCommand(perform: dismiss)
            .animation(reduceMotion ? nil : RelayMotion.hover, value: focusedIndex)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
    }
}

struct SettingsCheckboxStyle: ToggleStyle {
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        SettingsCheckbox(configuration: configuration, showsLabel: showsLabel)
    }
}

private struct SettingsCheckbox: View {
    let configuration: ToggleStyleConfiguration
    let showsLabel: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(AppTypography.symbolFont(size: 10, weight: .semibold))
                    .opacity(configuration.isOn ? 1 : 0)
                    .frame(width: 20, height: 20)
                    .background(BoardDarkSurfaceBackground(
                        cornerRadius: 5,
                        fill: configuration.isOn || isHovered || isFocused
                            ? BoardDarkSurfaceStyle.cardActiveFill : BoardDarkSurfaceStyle.contentFill
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(SettingsSurfaceColor.focusRing.opacity(isFocused ? 0.3 : 0.12), lineWidth: 1)
                    }
                    .frame(minWidth: 28, minHeight: 28)
                if showsLabel { configuration.label }
            }
            .font(AppTypography.font(.body))
            .foregroundStyle(isEnabled ? SettingsSurfaceColor.primaryText : SettingsSurfaceColor.disabledText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : RelayMotion.hover, value: configuration.isOn || isHovered || isFocused)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}

struct SettingsStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String
    @Environment(\.isEnabled) private var isEnabled

    private var boundedValue: Binding<Int> {
        Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) })
    }

    var body: some View {
        HStack(spacing: 8) {
            SettingsActionButton(title: "Decrease \(title)", systemImage: "minus", prominence: .icon,
                                 isEnabled: isEnabled && value > range.lowerBound) {
                boundedValue.wrappedValue = value - 1
            }
            .buttonRepeatBehavior(.enabled)
            HStack(spacing: 4) {
                TextField(title, value: boundedValue, format: .number.grouping(.never))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityValue("\(value) \(unit)")
                Text(unit).accessibilityHidden(true)
            }
            .font(AppTypography.font(.field))
            .monospacedDigit()
            .foregroundStyle(isEnabled ? SettingsSurfaceColor.primaryText : SettingsSurfaceColor.disabledText)
            .padding(.horizontal, 10)
            .frame(width: 112, height: 34)
            .background(BoardDarkSurfaceBackground(cornerRadius: SettingsLayout.sidebarCornerRadius,
                                                   fill: BoardDarkSurfaceStyle.contentFill))
            SettingsActionButton(title: "Increase \(title)", systemImage: "plus", prominence: .icon,
                                 isEnabled: isEnabled && value < range.upperBound) {
                boundedValue.wrappedValue = value + 1
            }
            .buttonRepeatBehavior(.enabled)
        }
    }
}
