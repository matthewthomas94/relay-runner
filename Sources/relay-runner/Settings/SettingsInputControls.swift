import SwiftUI

struct SettingsMenuOptions<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(label: String, value: Value)]
    /// False for a list of actions, where nothing is "selected".
    var showsCheckmarks = true
    /// A secondary line under an option's label, when it has one.
    var subtitle: ((Value) -> String?)? = nil
    let dismiss: () -> Void
    @FocusState private var focusedIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rowHeight: CGFloat { subtitle == nil ? 32 : 48 }

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
                                if showsCheckmarks {
                                    Image(systemName: "checkmark")
                                        .font(AppTypography.symbolFont(size: 10, weight: .semibold))
                                        .opacity(option.value == selection ? 1 : 0)
                                        .frame(width: 12)
                                        .accessibilityHidden(true)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(AppTypography.font(.action))
                                        .lineLimit(1)
                                    if let detail = subtitle?(option.value) {
                                        Text(detail)
                                            .font(AppTypography.font(.settingsDescription))
                                            .foregroundStyle(SettingsSurfaceColor.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .foregroundStyle(SettingsSurfaceColor.primaryText)
                            .padding(.horizontal, 10)
                            .frame(height: rowHeight)
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
            .frame(height: min(284, CGFloat(options.count) * (rowHeight + 2) + 10))
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

struct SettingsSwitchStyle: ToggleStyle {
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        SettingsSwitch(configuration: configuration, showsLabel: showsLabel)
    }
}

enum SettingsSwitchMetrics {
    static let trackSize = CGSize(width: 34, height: 20)
    static let knobDiameter: CGFloat = 14
    static let inset: CGFloat = 3
    static var knobTravel: CGFloat { trackSize.width - knobDiameter - inset * 2 }
}

private struct SettingsSwitch: View {
    let configuration: ToggleStyleConfiguration
    let showsLabel: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var trackFill: Color {
        if configuration.isOn { return SettingsSurfaceColor.neutralAccent.opacity(isHovered ? 0.4 : 0.34) }
        return isHovered || isFocused ? SettingsSurfaceColor.rowFillHovered : SettingsSurfaceColor.rowFill
    }

    private var knobFill: Color {
        configuration.isOn ? SettingsSurfaceColor.primaryText : SettingsSurfaceColor.mutedText
    }

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                Capsule()
                    .fill(trackFill)
                    .overlay {
                        Capsule().strokeBorder(
                            SettingsSurfaceColor.focusRing.opacity(isFocused ? 0.3 : 0.12), lineWidth: 1)
                    }
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(knobFill)
                            .frame(width: SettingsSwitchMetrics.knobDiameter, height: SettingsSwitchMetrics.knobDiameter)
                            .offset(x: SettingsSwitchMetrics.inset + (configuration.isOn ? SettingsSwitchMetrics.knobTravel : 0))
                    }
                    .frame(width: SettingsSwitchMetrics.trackSize.width, height: SettingsSwitchMetrics.trackSize.height)
                    .frame(minHeight: 28)
                if showsLabel { configuration.label }
            }
            .font(AppTypography.font(.body))
            .foregroundStyle(isEnabled ? SettingsSurfaceColor.primaryText : SettingsSurfaceColor.disabledText)
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .onHover { isHovered = $0 }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: configuration.isOn)
        .animation(reduceMotion ? nil : RelayMotion.hover, value: isHovered || isFocused)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
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

/// A slider in the session wheel's intensity style: a card track, a faint fill up to a thin
/// upright thumb, and the value printed on the wider side of the thumb.
struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false
    @State private var isDragging = false
    @FocusState private var isFocused: Bool

    /// Keeps the thumb clear of the rounded ends.
    static let thumbInset: CGFloat = 8

    /// The value fill, also used for the segmented picker's selection.
    static func fillColor(contrast: ColorSchemeContrast, isEnabled: Bool = true) -> Color {
        contrast == .increased
            ? Color.white.opacity(isEnabled ? 0.22 : 0.04)
            : ProgramBoardStyle.mutedText.opacity(isEnabled ? 0.06 : 0.02)
    }

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double, label: String) {
        self._value = value
        self.range = range
        self.step = step
        self.label = label
    }

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    var body: some View {
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isEnabled: isEnabled, isHovered: isHovered || isDragging,
            isFocused: isFocused, reduceMotion: reduceMotion
        )
        let shape = RoundedRectangle(cornerRadius: SharedActionButtonMetrics.cornerRadius, style: .continuous)
        let foreground = isEnabled ? ProgramBoardStyle.primaryText
            : (contrast == .increased ? ProgramBoardStyle.disabledText : ProgramBoardStyle.mutedText.opacity(0.5))
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let thumb = Self.thumbInset + (width - Self.thumbInset * 2) * fraction
            ZStack {
                ProgramBoardInteractiveBackground(shape: .custom(AnyShape(shape)), presentation: presentation,
                                                  disabled: !isEnabled, usesCardStyle: true)
                shape.fill(Self.fillColor(contrast: contrast, isEnabled: isEnabled))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: fraction >= 1 ? width : thumb)
                    }
                Capsule()
                    .fill(foreground)
                    .frame(width: 2.5, height: height - 14)
                    .position(x: thumb, y: height / 2)
                Text(label)
                    .font(AppTypography.font(.action, size: 10))
                    .monospacedDigit()
                    .foregroundStyle(foreground)
                    .fixedSize()
                    .position(x: fraction >= 0.5 ? thumb / 2 : (thumb + width) / 2, y: height / 2)
            }
            .contentShape(shape)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    isDragging = true
                    setValue(atX: drag.location.x, width: width)
                }
                .onEnded { drag in
                    setValue(atX: drag.location.x, width: width)
                    isDragging = false
                })
        }
        .frame(height: SharedActionButtonMetrics.controlHeight)
        // The geometry reader hides the label's baseline; rows align to a centred line of text instead.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .animation(presentation.animation, value: presentation)
        .onHover { isHovered = $0 }
        .focusable(isEnabled)
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .focused($isFocused)
        .onKeyPress(.leftArrow) { stepValue(-1); return .handled }
        .onKeyPress(.rightArrow) { stepValue(1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: stepValue(1)
            case .decrement: stepValue(-1)
            @unknown default: break
            }
        }
    }

    private func setValue(atX x: CGFloat, width: CGFloat) {
        update(Self.value(atX: x, width: width, in: range, step: step))
    }

    private func stepValue(_ direction: Double) {
        update(Self.snapped(value + direction * step, in: range, step: step))
    }

    private func update(_ newValue: Double) {
        guard isEnabled, newValue != value else { return }
        value = newValue
    }

    /// The snapped value under a pointer at `x` in a track `width` wide.
    static func value(atX x: CGFloat, width: CGFloat, in range: ClosedRange<Double>, step: Double) -> Double {
        let fraction = Double((x - thumbInset) / max(1, width - thumbInset * 2))
        return snapped(range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound),
                       in: range, step: step)
    }

    /// Snaps to `step` from the lower bound, staying inside the range and free of floating-point drift.
    static func snapped(_ raw: Double, in range: ClosedRange<Double>, step: Double) -> Double {
        let steps = ((raw - range.lowerBound) / step).rounded()
        let snapped = min(max(range.lowerBound + steps * step, range.lowerBound), range.upperBound)
        return (snapped * 1_000_000).rounded() / 1_000_000
    }
}
