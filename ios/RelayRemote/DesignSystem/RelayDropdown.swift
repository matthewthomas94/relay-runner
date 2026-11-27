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
        // No arrow edge: iOS opens the list above or below the pill, wherever
        // there is more room. Pinned below, a pill low on the screen squeezed
        // the list and hid its last options (user, 2026-11-28).
        .popover(isPresented: $isPresented, arrowEdge: nil) {
            optionList.presentationCompactAdaptation(.popover)
        }
    }

    /// The heading's room: clear of the popover's rounded top corners.
    private static let headingHeight: CGFloat = 40
    private static let listPadding: CGFloat = 8
    /// At most this tall; past it the options scroll.
    private static let maxHeight: CGFloat = 360

    /// The list asks for its full height up to `maxHeight`; when iOS gives
    /// the popover less than that, the options scroll rather than being cut off.
    private var optionList: some View {
        let full = CGFloat(options.count) * RelayMetrics.controlHeight + 2 * Self.listPadding
            + (heading == nil ? 0 : Self.headingHeight)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let heading {
                    Text(heading).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .frame(height: Self.headingHeight, alignment: .bottomLeading)
                }
                rows
            }
            .padding(.vertical, Self.listPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.width, height: min(full, Self.maxHeight))
    }

    @ViewBuilder private var rows: some View {
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
}
