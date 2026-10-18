import SwiftUI

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

    static var tabHeight: CGFloat { 40 }
    static var tabGap: CGFloat { 8 }

    var body: some View {
        VStack(spacing: 0) {
            if !tabs.isEmpty {
                HStack(spacing: Self.tabGap) {
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
                .frame(height: Self.tabHeight)
                .padding(.horizontal, 24)
                .padding(.bottom, Self.tabGap)
            }
            content()
        }
        .backgroundPreferenceValue(TerminalTabBounds.self) { anchors in
            GeometryReader { proxy in
                let frame = anchors[selectedID].map { proxy[$0] } ?? .zero
                WorkspaceTerminalOutline(
                    tabFrame: frame,
                    contentTop: tabs.isEmpty ? 0 : Self.tabHeight + Self.tabGap
                )
                .fill(BoardDarkSurfaceStyle.panelFill)
                .overlay {
                    WorkspaceTerminalOutline(
                        tabFrame: frame,
                        contentTop: tabs.isEmpty ? 0 : Self.tabHeight + Self.tabGap
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
        let radius = BoardDarkSurfaceStyle.columnCornerRadius
        let shoulder: CGFloat = 8
        let cap: CGFloat = 12
        let left = max(bounds.minX + radius + shoulder, tabFrame.minX)
        let right = min(bounds.maxX - radius - shoulder, tabFrame.maxX)
        var path = Path()
        path.move(to: CGPoint(x: bounds.minX, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: bounds.minX + radius, y: top), control: CGPoint(x: bounds.minX, y: top))
        if contentTop > 0, right - left > cap * 2 {
            path.addLine(to: CGPoint(x: left - shoulder, y: top))
            path.addQuadCurve(to: CGPoint(x: left, y: top - shoulder), control: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: left, y: bounds.minY + cap))
            path.addQuadCurve(to: CGPoint(x: left + cap, y: bounds.minY), control: CGPoint(x: left, y: bounds.minY))
            path.addLine(to: CGPoint(x: right - cap, y: bounds.minY))
            path.addQuadCurve(to: CGPoint(x: right, y: bounds.minY + cap), control: CGPoint(x: right, y: bounds.minY))
            path.addLine(to: CGPoint(x: right, y: top - shoulder))
            path.addQuadCurve(to: CGPoint(x: right + shoulder, y: top), control: CGPoint(x: right, y: top))
        }
        path.addLine(to: CGPoint(x: bounds.maxX - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: bounds.maxX, y: top + radius), control: CGPoint(x: bounds.maxX, y: top))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: bounds.maxX - radius, y: bounds.maxY), control: CGPoint(x: bounds.maxX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX + radius, y: bounds.maxY))
        path.addQuadCurve(to: CGPoint(x: bounds.minX, y: bounds.maxY - radius), control: CGPoint(x: bounds.minX, y: bounds.maxY))
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
                BoardDarkSurfaceBackground(
                    cornerRadius: 12,
                    fill: isHovered ? BoardDarkSurfaceStyle.hoverFill : BoardDarkSurfaceStyle.panelFill
                )
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
