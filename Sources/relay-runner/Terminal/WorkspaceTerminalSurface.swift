import SwiftUI

enum WorkspaceTerminalLayout {
    static let tabHeight: CGFloat = 40
    static let tabGap: CGFloat = 8
    static let tabCornerRadius: CGFloat = 12
    static let shoulderRadius = tabCornerRadius + tabGap
    static let horizontalPadding = BoardDarkSurfaceStyle.columnCornerRadius + shoulderRadius
}

/// The selected tab and terminal share one outline. Only that outline morphs
/// on selection, leaving the live terminal's layout and hit targets stationary.
struct WorkspaceTerminalSurface<Content: View>: View {
    let tabs: [(id: String, name: String)]
    let selectedID: String
    let badges: [String: Int]
    let select: (String) -> Void
    let readOut: (String) -> Void
    let close: (String) -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if !tabs.isEmpty {
                HStack(spacing: WorkspaceTerminalLayout.tabGap) {
                    ForEach(tabs, id: \.id) { tab in
                        WorkspaceSessionTab(
                            name: tab.name,
                            selected: tab.id == selectedID,
                            badgeCount: badges[tab.id] ?? 0,
                            select: { select(tab.id) },
                            readOut: { readOut(tab.id) },
                            close: { close(tab.id) }
                        )
                        .anchorPreference(key: TerminalTabBounds.self, value: .bounds) { [tab.id: $0] }
                        .transition(.relayElement)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: WorkspaceTerminalLayout.tabHeight)
                .padding(.horizontal, WorkspaceTerminalLayout.horizontalPadding)
                .padding(.bottom, WorkspaceTerminalLayout.tabGap)
            }
            content()
        }
        .backgroundPreferenceValue(TerminalTabBounds.self) { anchors in
            GeometryReader { proxy in
                let frame = anchors[selectedID].map { proxy[$0] } ?? .zero
                WorkspaceTerminalOutline(
                    tabFrame: frame,
                    contentTop: tabs.isEmpty ? 0 : WorkspaceTerminalLayout.tabHeight + WorkspaceTerminalLayout.tabGap
                )
                .fill(BoardDarkSurfaceStyle.panelFill)
                .overlay {
                    WorkspaceTerminalOutline(
                        tabFrame: frame,
                        contentTop: tabs.isEmpty ? 0 : WorkspaceTerminalLayout.tabHeight + WorkspaceTerminalLayout.tabGap
                    )
                    .stroke(BoardDarkSurfaceStyle.border, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
                .animation(reduceMotion ? nil : RelayMotion.change, value: frame)
            }
            .allowsHitTesting(false)
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: tabs.map(\.id))
    }
}

private struct TerminalTabBounds: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Rounded shoulders make the raised tab flow into the terminal. Interpolating
/// its position and width gives the selection one continuous, liquid contour.
struct WorkspaceTerminalOutline: Shape {
    var tabFrame: CGRect
    let contentTop: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(tabFrame.minX, tabFrame.width) }
        set { tabFrame.origin.x = newValue.first; tabFrame.size.width = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: 0.5, dy: 0.5)
        let top = bounds.minY + contentTop
        let radius = BoardDarkSurfaceStyle.columnCornerRadius - 0.5
        // Stroke centers sit half a point inside each surface. The concave
        // shoulder shares its center with the adjacent tab's convex corner.
        let shoulder = WorkspaceTerminalLayout.shoulderRadius + 0.5
        let cap = WorkspaceTerminalLayout.tabCornerRadius - 0.5
        let left = max(bounds.minX + radius + shoulder, tabFrame.minX + 0.5)
        let right = min(bounds.maxX - radius - shoulder, tabFrame.maxX - 0.5)
        var path = Path()
        path.move(to: CGPoint(x: bounds.minX, y: top + radius))
        path.addArc(tangent1End: CGPoint(x: bounds.minX, y: top), tangent2End: CGPoint(x: bounds.minX + radius, y: top), radius: radius)
        if contentTop > 0, right - left > cap * 2 {
            path.addLine(to: CGPoint(x: left - shoulder, y: top))
            path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left, y: top - shoulder), radius: shoulder)
            path.addLine(to: CGPoint(x: left, y: bounds.minY + cap))
            path.addArc(tangent1End: CGPoint(x: left, y: bounds.minY), tangent2End: CGPoint(x: left + cap, y: bounds.minY), radius: cap)
            path.addLine(to: CGPoint(x: right - cap, y: bounds.minY))
            path.addArc(tangent1End: CGPoint(x: right, y: bounds.minY), tangent2End: CGPoint(x: right, y: bounds.minY + cap), radius: cap)
            path.addLine(to: CGPoint(x: right, y: top - shoulder))
            path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right + shoulder, y: top), radius: shoulder)
        }
        path.addLine(to: CGPoint(x: bounds.maxX - radius, y: top))
        path.addArc(tangent1End: CGPoint(x: bounds.maxX, y: top), tangent2End: CGPoint(x: bounds.maxX, y: top + radius), radius: radius)
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: bounds.maxX, y: bounds.maxY), tangent2End: CGPoint(x: bounds.maxX - radius, y: bounds.maxY), radius: radius)
        path.addLine(to: CGPoint(x: bounds.minX + radius, y: bounds.maxY))
        path.addArc(tangent1End: CGPoint(x: bounds.minX, y: bounds.maxY), tangent2End: CGPoint(x: bounds.minX, y: bounds.maxY - radius), radius: radius)
        path.closeSubpath()
        return path
    }
}

private struct WorkspaceSessionTab: View {
    let name: String
    let selected: Bool
    let badgeCount: Int
    let select: () -> Void
    let readOut: () -> Void
    let close: () -> Void
    @State private var isHovered = false
    @State private var closeHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(AppTypography.font(.menuTab))
                        .lineLimit(1)
                    if badgeCount > 0 { SessionReplyBadge(count: badgeCount) }
                }
                .padding(.leading, 16)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { Button("Read Out Latest Reply", action: readOut) }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(AppTypography.symbolFont(size: 11))
                    .frame(width: 28, height: 28)
                    .background(closeHovered ? BoardDarkSurfaceStyle.hoverFill : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .onHover { closeHovered = $0 }
            .help("Stop \(name) session")
            .accessibilityLabel("Stop \(name) session")
        }
        .foregroundStyle(ProgramBoardStyle.primaryText)
        .background {
            if !selected {
                RoundedRectangle(cornerRadius: WorkspaceTerminalLayout.tabCornerRadius, style: .circular)
                    .fill(isHovered ? BoardDarkSurfaceStyle.hoverFill : BoardDarkSurfaceStyle.panelFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: WorkspaceTerminalLayout.tabCornerRadius, style: .circular)
                            .strokeBorder(BoardDarkSurfaceStyle.border, lineWidth: 1)
                    }
                    .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: selected)
        .animation(RelayMotion.hover, value: isHovered)
        .animation(RelayMotion.hover, value: closeHovered)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
