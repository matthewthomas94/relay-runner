import SwiftUI

/// The app's dropdown, as the Mac's Settings dropdowns (`SettingsMenuOptions`):
/// a field pill with the value and a chevron that opens the options in a
/// popover. Each option's name leads and the selected one's check sits at the
/// trailing edge, so no name moves when the selection does. iOS menus put the
/// check in front and push the names along (user, 2026-11-28).
struct RelayDropdown: View {
    let label: String
    let options: [(value: String, label: String)]
    let selection: String?
    /// A heading above the options, when the pill alone does not say what they are.
    var heading: String? = nil
    let choose: (String) -> Void
    @State private var isPresented = false

    private static let width: CGFloat = 240

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 6) {
                Text(label).relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .contentTransition(.opacity)
                    .animation(RelayMotion.enter, value: label)
                LucideImage(.chevronDown, size: 16).foregroundStyle(RelayColor.neutral7)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: RelayMetrics.controlHeight)
            .modifier(FieldSurface())
            .contentShape(Rectangle())
        }
        .buttonStyle(.relayPlain)
        .accessibilityValue(label)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            optionList.presentationCompactAdaptation(.popover)
        }
    }

    private var optionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let heading {
                Text(heading).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    choose(option.value)
                    isPresented = false
                } label: {
                    HStack(spacing: 12) {
                        Text(option.label).relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LucideImage(.check, size: 16).foregroundStyle(RelayColor.neutral10)
                            .opacity(selected ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: RelayMetrics.controlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.relayPlain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 6)
        .frame(width: Self.width)
    }
}
