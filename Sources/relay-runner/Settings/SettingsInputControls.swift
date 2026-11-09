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

    /// Kit options: 4 points above and below a 20-point line; a subtitle adds a second line.
    private var rowHeight: CGFloat { subtitle == nil ? 28 : 48 }
    private static var rowSpacing: CGFloat { GraphicalTheme.spaceXXS }
    private static var popoverPadding: CGFloat { GraphicalTheme.spaceXXS }

    private var contentHeight: CGFloat {
        CGFloat(options.count) * rowHeight + CGFloat(max(0, options.count - 1)) * Self.rowSpacing
            + Self.popoverPadding * 2
    }

    var body: some View {
        ScrollViewReader { proxy in
            RelayFadingScrollView {
                VStack(spacing: Self.rowSpacing) {
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
                            .padding(.horizontal, GraphicalTheme.spaceXS)
                            .frame(height: rowHeight)
                            // Kit option: radius xs, neutral-3 when highlighted.
                            .background(
                                focusedIndex == index ? GraphicalTheme.neutral3 : .clear,
                                in: RoundedRectangle(cornerRadius: GraphicalTheme.radiusXS)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .focused($focusedIndex, equals: index)
                        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
                        .onHover { if $0 { focusedIndex = index } }
                        .accessibilityAddTraits(option.value == selection ? .isSelected : [])
                        .id(index)
                    }
                }
                .padding(Self.popoverPadding)
            }
            .frame(maxWidth: .infinity)
            .frame(height: min(284, contentHeight))
            // Kit popovers are neutral-2: radius s for a select, m for an action menu.
            .background(BoardDarkSurfaceBackground(
                cornerRadius: showsCheckmarks ? GraphicalTheme.radiusS : GraphicalTheme.radiusM
            ))
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
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    /// Kit switch: neutral-4 track, neutral-10 when on, neutral-3 when disabled.
    /// Slightly translucent so the hover dots behind it still read.
    private var trackFill: Color {
        guard isEnabled else { return GraphicalTheme.neutral3 }
        if configuration.isOn { return GraphicalTheme.neutral10.opacity(GraphicalTheme.fillThroughDotsOpacity) }
        return GraphicalTheme.neutral4.opacity(GraphicalTheme.fillThroughDotsOpacity)
    }

    /// Kit thumb: black, neutral-6 when disabled.
    private var knobFill: Color {
        isEnabled ? GraphicalTheme.neutral1 : GraphicalTheme.neutral6
    }

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                Capsule()
                    .fill(trackFill)
                    .background(FluxDotsBackground(
                        cornerRadius: SettingsSwitchMetrics.trackSize.height / 2,
                        style: .standard,
                        isVisible: isHovered
                    ))
                    .overlay {
                        Capsule().strokeBorder(
                            SettingsSurfaceColor.focusRing.opacity(isFocused ? 1 : 0),
                            lineWidth: GraphicalTheme.focusRingWidth)
                    }
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(knobFill)
                            .graphicalShadow(.s)
                            .frame(width: SettingsSwitchMetrics.knobDiameter, height: SettingsSwitchMetrics.knobDiameter)
                            .offset(x: SettingsSwitchMetrics.inset + (configuration.isOn ? SettingsSwitchMetrics.knobTravel : 0))
                    }
                    .frame(width: SettingsSwitchMetrics.trackSize.width, height: SettingsSwitchMetrics.trackSize.height)
                    .frame(minHeight: GraphicalTheme.controlHeight)
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
            .padding(.horizontal, GraphicalTheme.spaceS)
            .frame(width: 112, height: GraphicalTheme.controlHeight)
            .background(GraphicalInputSurface(isEnabled: isEnabled))
            SettingsActionButton(title: "Increase \(title)", systemImage: "plus", prominence: .icon,
                                 isEnabled: isEnabled && value < range.upperBound) {
                boundedValue.wrappedValue = value + 1
            }
            .buttonRepeatBehavior(.enabled)
        }
    }
}

/// A kit text input that saves once typing pauses for half a second, on Return, or
/// when focus leaves it, so a multi-character edit is one save rather than one per key.
struct SettingsTextField: View {
    let title: String
    @Binding var text: String
    var placeholder = ""
    @State private var edit = SettingsDeferredEdit<String>()
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, text: Binding<String>, placeholder: String = "") {
        self.title = title
        self._text = text
        self.placeholder = placeholder
    }

    var body: some View {
        let shown = edit.value ?? text
        // Reads live: ending an edit before the next render must not restore older text.
        let typed = Binding(get: { edit.value ?? text }, set: { typed in
            edit.update(typed, settlingAfter: SettingsAutoSave.editPause) { text = $0 }
        })
        // Binds its own focus, so it draws the kit input surface itself.
        TextField(title, text: typed, prompt: Text(""))
            .appPlaceholder(placeholder, when: shown.isEmpty)
            .textFieldStyle(.plain)
            .font(AppTypography.font(.field))
            .foregroundStyle(isEnabled ? SettingsSurfaceColor.primaryText : SettingsSurfaceColor.disabledText)
            .lineLimit(1)
            .padding(.horizontal, GraphicalTheme.spaceS)
            .frame(minHeight: GraphicalTheme.controlHeight)
            .background(GraphicalInputSurface(isFocused: isFocused, isEnabled: isEnabled))
            .focused($isFocused)
            .animation(reduceMotion ? nil : RelayMotion.hover, value: isFocused)
            .onSubmit { edit.flush() }
            .onChange(of: isFocused) { _, focused in if !focused { edit.flush() } }
            // Our own save lands here with nothing pending; a change made elsewhere replaces the edit.
            .onChange(of: text) { _, _ in edit.discard() }
            .onDisappear { edit.flush() }
    }
}

/// A slider in the session wheel's intensity style: a card track, a faint fill up to a thin
/// upright thumb, and the value printed on the wider side of the thumb. A drag or a held arrow
/// key moves it freely and writes the value once, on release.
struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var edit = SettingsDeferredEdit<Double>()
    @FocusState private var isFocused: Bool

    /// Keeps the thumb clear of the rounded ends.
    static let thumbInset: CGFloat = 8

    /// The value fill: the kit's neutral-10 indicator, neutral-5 when disabled,
    /// translucent so the hover dots behind it still read.
    static func fillColor(contrast: ColorSchemeContrast, isEnabled: Bool = true) -> Color {
        let opacity = contrast == .increased ? 1 : GraphicalTheme.fillThroughDotsOpacity
        return (isEnabled ? GraphicalTheme.neutral10 : GraphicalTheme.neutral5).opacity(opacity)
    }

    /// Text that sits on the value fill, dark on the light indicator.
    static func onFillColor(isEnabled: Bool) -> Color {
        isEnabled ? GraphicalTheme.neutral1 : GraphicalTheme.neutral7
    }

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double, label: @escaping (Double) -> String) {
        self._value = value
        self.range = range
        self.step = step
        self.label = label
    }

    /// The value under the thumb, including one still being dragged.
    private var shownValue: Double { edit.value ?? value }

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((shownValue - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
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
                    .background(FluxDotsBackground(
                        cornerRadius: SharedActionButtonMetrics.cornerRadius,
                        style: .standard,
                        isVisible: isEnabled && (isHovered || isDragging)
                    ))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: fraction >= 1 ? width : thumb)
                    }
                Capsule()
                    .fill(foreground)
                    .graphicalShadow(.s)
                    .frame(width: 2.5, height: height - 14)
                    .position(x: thumb, y: height / 2)
                // Kit value text: neutral-7 beside the fill, dark on it.
                Text(label(shownValue))
                    .font(AppTypography.font(.caption))
                    .monospacedDigit()
                    .foregroundStyle(fraction >= 0.5 ? Self.onFillColor(isEnabled: isEnabled)
                                     : (isEnabled ? ProgramBoardStyle.mutedText : foreground))
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
                    edit.flush()
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
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .up) { _ in edit.flush(); return .handled }
        .onChange(of: isFocused) { _, focused in if !focused { edit.flush() } }
        .onDisappear { edit.flush() }
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            // Each VoiceOver adjustment is one deliberate step, written at once.
            switch direction {
            case .increment: stepValue(1)
            case .decrement: stepValue(-1)
            @unknown default: break
            }
            edit.flush()
        }
    }

    /// A drag holds its value until release.
    private func setValue(atX x: CGFloat, width: CGFloat) {
        update(Self.value(atX: x, width: width, in: range, step: step), settlingAfter: nil)
    }

    /// Arrow keys write on key up, or once a held key pauses.
    private func stepValue(_ direction: Double) {
        update(Self.snapped(shownValue + direction * step, in: range, step: step),
               settlingAfter: SettingsAutoSave.editPause)
    }

    private func update(_ newValue: Double, settlingAfter delay: Duration?) {
        guard isEnabled, newValue != shownValue else { return }
        edit.update(newValue, settlingAfter: delay) { value = $0 }
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
