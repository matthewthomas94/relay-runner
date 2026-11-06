import AppKit
import QuartzCore
import SwiftUI

/// What a skeleton loader stands in for.
enum SkeletonLoaderLayout: Equatable {
    /// The Workspace board, with its columns starting `columnTop` points
    /// below the loader's top edge.
    case board(columnTop: CGFloat)
    /// A provider session in the embedded terminal.
    case terminal
    /// The Notes tab: the list of notes beside the open note.
    case notes
    /// The Settings tab: categories, their settings, and the agent card.
    case settings
    /// Workspace History: the archived tickets beside the open one.
    case history
}

/// A placeholder shape in a skeleton loader.
struct SkeletonBone: Equatable {
    enum Style: Equatable {
        case fill
        case outline
    }

    var rect: CGRect
    var radius: CGFloat
    var style: Style
}

/// A dot in a filled bone.
struct SkeletonDot: Equatable {
    var centre: CGPoint
    /// Where the dot sits along its column's snake, from 0 to 4: the head
    /// lights position 0 first and position 4 last.
    var snakePosition: Int
    /// Which cohort the dot arrives and leaves with when the field
    /// disintegrates in or out.
    var cohort: Int
}

/// A loading state that sketches the screen it stands in for: bare shapes
/// that shimmer. It shows no text; its label is for VoiceOver only.
///
/// Filled bones are drawn as a dot matrix, a grid of round dots; outlines
/// stay solid lines. The dots shimmer as column snakes: in each column a
/// bright head steps along with a dimming tail, alternate columns rising
/// and falling.
///
/// The shimmer is a Core Animation keyframe animation on each phase's
/// layer, so it runs on the render server without per-frame work on the
/// main thread. Reduce Motion holds it still.
final class SkeletonLoaderView: NSView {
    static let boneBaseColor = NSColor(srgbRed: 22 / 255, green: 27 / 255, blue: 36 / 255, alpha: 1)
    static let boneHighlightColor = NSColor(srgbRed: 52 / 255, green: 60 / 255, blue: 74 / 255, alpha: 1)
    static let outlineWidth: CGFloat = 1.5
    /// The outlines sit back at a third opacity.
    static let outlineOpacity: Float = 0.33
    /// The dots sit on the notch glyph's grid, at its dot size.
    static let dotPitch: CGFloat = 5
    static let dotDiameter: CGFloat = 3
    static let shimmerKey = "skeletonShimmer"

    let skeleton: SkeletonLoaderLayout

    private let panelsLayer = CAShapeLayer()
    private let dots = FluxDotLayers()
    private let outlineLayer = CAShapeLayer()

    private(set) var bones: [SkeletonBone] = []

    override var isFlipped: Bool { true }

    init(layout: SkeletonLoaderLayout, label: String) {
        self.skeleton = layout
        super.init(frame: .zero)
        wantsLayer = true

        panelsLayer.fillColor = BoardDarkSurfaceStyle.panelFillNSColor.cgColor
        panelsLayer.strokeColor = BoardDarkSurfaceStyle.borderNSColor.cgColor
        panelsLayer.lineWidth = 1
        layer?.addSublayer(panelsLayer)

        layer?.addSublayer(dots.container)
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = Self.boneBaseColor.cgColor
        outlineLayer.lineWidth = Self.outlineWidth
        outlineLayer.opacity = Self.outlineOpacity
        layer?.addSublayer(outlineLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        bones = Self.bones(for: skeleton, in: bounds)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let panels = CGMutablePath()
        for panel in Self.panels(for: skeleton, in: bounds) {
            panels.addRoundedRect(in: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 16, cornerHeight: 16)
        }
        panelsLayer.frame = bounds
        panelsLayer.path = panels
        let outlines = CGMutablePath()
        for bone in bones where bone.style == .outline {
            let inset = Self.outlineWidth / 2
            outlines.addRoundedRect(
                in: bone.rect.insetBy(dx: inset, dy: inset),
                cornerWidth: bone.radius,
                cornerHeight: bone.radius
            )
        }
        outlineLayer.frame = bounds
        outlineLayer.path = outlines
        CATransaction.commit()

        dots.fill(bones.filter { $0.style == .fill }.map { ($0.rect, $0.radius) }, in: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Changes what VoiceOver announces.
    func setLabel(_ label: String) {
        setAccessibilityLabel(label)
    }

    /// Shows the share of the dots present, from 0 (none) to 1 (all), at
    /// once; SwiftUI drives this frame by frame through the disintegrate
    /// transition.
    func setPresence(_ presence: Double) {
        dots.setPresence(presence)
    }

    /// Disintegrates the dots in (to 1) or out (to 0) over `duration`.
    func animatePresence(to presence: Double, duration: TimeInterval, completion: (() -> Void)? = nil) {
        dots.animatePresence(to: presence, duration: duration, completion: completion)
    }

    // MARK: Dots

    /// A filled bone's dots: a grid centred in it, whose own corners round
    /// like the bone's. The area the dot centres span is the bone scaled
    /// down, corner radius included, and a dot stays if it touches that
    /// rounded area, so the corner dots drop where the bone curves. Two
    /// rows or columns are too few to show a curve, so they keep every
    /// dot. The snakes' rows count from the loader's top rather than the
    /// bone's, so bones at different heights light at different moments.
    static func dots(in rect: CGRect, cornerRadius: CGFloat) -> [SkeletonDot] {
        let columns = max(1, Int(((rect.width - dotDiameter) / dotPitch).rounded(.down)) + 1)
        let rows = max(1, Int(((rect.height - dotDiameter) / dotPitch).rounded(.down)) + 1)
        let left = rect.midX - CGFloat(columns - 1) * dotPitch / 2
        let top = rect.midY - CGFloat(rows - 1) * dotPitch / 2
        let span = CGRect(
            x: left,
            y: top,
            width: CGFloat(columns - 1) * dotPitch,
            height: CGFloat(rows - 1) * dotPitch
        )
        let scale = rect.width > 0 && rect.height > 0 ? min(span.width / rect.width, span.height / rect.height) : 0
        let corner = rows < 3 || columns < 3
            ? 0
            : min(cornerRadius * scale, span.width / 2, span.height / 2)
        let core = span.insetBy(dx: corner, dy: corner)
        var dots: [SkeletonDot] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: left + CGFloat(column) * dotPitch, y: top + CGFloat(row) * dotPitch)
                let dx = max(core.minX - point.x, point.x - core.maxX, 0)
                let dy = max(core.minY - point.y, point.y - core.maxY, 0)
                if hypot(dx, dy) <= corner + dotDiameter / 2 {
                    let loaderColumn = Int((point.x / dotPitch).rounded())
                    let loaderRow = Int((point.y / dotPitch).rounded())
                    dots.append(SkeletonDot(
                        centre: point,
                        snakePosition: DotColumnSnakeAnimation.position(column: loaderColumn, row: loaderRow),
                        cohort: DotPresence.cohort(column: loaderColumn, row: loaderRow)
                    ))
                }
            }
        }
        return dots
    }

    // MARK: Geometry

    /// The surfaces behind the bones: the board's columns, the Notes
    /// library, or the Settings pane and its agent card. History sits on
    /// its own panel, so it needs none.
    static func panels(for layout: SkeletonLoaderLayout, in bounds: CGRect) -> [CGRect] {
        switch layout {
        case .board(let top):
            return boardPanels(columnTop: top, in: bounds)
        case .terminal:
            return []
        case .notes:
            return bounds.width > 0 && bounds.height > 0 ? [bounds] : []
        case .settings:
            let cardWidth = SettingsAgentCardLayout.width(availableWidth: bounds.width)
            let paneWidth = bounds.width - cardWidth - SettingsAgentCardLayout.spacing
            guard paneWidth > SettingsContentStyle.workspace.sidebarWidth + 1 + 160, bounds.height > 0 else { return [] }
            return [
                CGRect(x: bounds.minX, y: bounds.minY, width: paneWidth, height: bounds.height),
                CGRect(x: bounds.maxX - cardWidth, y: bounds.minY, width: cardWidth, height: bounds.height),
            ]
        case .history:
            return []
        }
    }

    private static func boardPanels(columnTop top: CGFloat, in bounds: CGRect) -> [CGRect] {
        let padding = BoardSurfaceLayout.horizontalPadding
        let spacing = BoardSurfaceLayout.columnSpacing
        let count = CGFloat(ProgramBoardLane.allCases.count + 1)
        let width = (bounds.width - padding * 2 - spacing * (count - 1)) / count
        let height = min(
            BoardSurfaceLayout.columnHeight,
            bounds.height - top - ProgramBoardBackdropStyle.bottomPadding
        )
        guard width > 0, height > 0 else { return [] }
        return (0..<Int(count)).map { index in
            CGRect(
                x: bounds.minX + padding + CGFloat(index) * (width + spacing),
                y: bounds.minY + top,
                width: width,
                height: height
            )
        }
    }

    static func bones(for layout: SkeletonLoaderLayout, in bounds: CGRect) -> [SkeletonBone] {
        switch layout {
        case .board:
            return boardBones(panels: panels(for: layout, in: bounds))
        case .terminal:
            return terminalBones(in: bounds)
        case .notes:
            return notesBones(in: bounds)
        case .settings:
            return settingsBones(panels: panels(for: layout, in: bounds))
        case .history:
            return historyBones(in: bounds)
        }
    }

    /// Card heights for each lane, so the lanes read as different lists.
    private static let laneCardHeights: [[CGFloat]] = [
        [88, 72, 96, 72, 88],
        [72, 88],
        [96, 72, 88],
        [72, 72, 88, 72, 96, 72],
    ]

    private static func boardBones(panels: [CGRect]) -> [SkeletonBone] {
        var bones: [SkeletonBone] = []
        for (index, panel) in panels.enumerated() {
            // The column header: a title and an action.
            let headerMidY = panel.minY + ProgramBoardLayout.panelVerticalPadding
                + ProgramBoardLayout.workHeaderHeight / 2
            let titleWidth = min(96, panel.width * 0.3)
            bones.append(SkeletonBone(
                rect: CGRect(x: panel.minX + 24, y: headerMidY - 6, width: titleWidth, height: 12),
                radius: 6,
                style: .fill
            ))
            bones.append(SkeletonBone(
                rect: CGRect(x: panel.maxX - 24 - 24, y: headerMidY - 12, width: 24, height: 24),
                radius: 8,
                style: .fill
            ))

            // The cards, stacked until the column ends.
            let overview = index == 0
            let heights = overview
                ? Array(repeating: ProgramBoardLayout.projectCardHeight, count: 4)
                : laneCardHeights[(index - 1) % laneCardHeights.count]
            let spacing: CGFloat = overview ? ProgramBoardLayout.projectCardSpacing : 6
            var y = overview
                ? headerMidY + ProgramBoardLayout.workHeaderHeight / 2 + ProgramBoardLayout.projectHeaderToListSpacing
                : panel.minY + ProgramBoardLayout.workCardTopOffset
            for height in heights {
                let card = CGRect(x: panel.minX + 8, y: y, width: panel.width - 16, height: height)
                guard card.maxY <= panel.maxY - 16 else { break }
                bones.append(SkeletonBone(rect: card, radius: 14, style: .outline))
                bones.append(contentsOf: cardLines(in: card, wide: overview))
                y = card.maxY + spacing
            }
        }
        return bones
    }

    /// A title line and a shorter detail line inside a card.
    private static func cardLines(in card: CGRect, wide: Bool) -> [SkeletonBone] {
        let inset: CGFloat = 16
        let available = card.width - inset * 2
        guard available > 24 else { return [] }
        return [
            SkeletonBone(
                rect: CGRect(x: card.minX + inset, y: card.minY + inset, width: available * (wide ? 0.55 : 0.7), height: 10),
                radius: 5,
                style: .fill
            ),
            SkeletonBone(
                rect: CGRect(x: card.minX + inset, y: card.minY + inset + 20, width: available * (wide ? 0.8 : 0.45), height: 8),
                radius: 4,
                style: .fill
            ),
        ]
    }

    private static func terminalBones(in bounds: CGRect) -> [SkeletonBone] {
        let inset: CGFloat = 20
        let contentWidth = bounds.width - inset * 2
        guard contentWidth > 80, bounds.height > inset * 2 + 120 else { return [] }
        var bones: [SkeletonBone] = []

        // The provider's welcome box.
        let welcome = CGRect(x: bounds.minX + inset, y: bounds.minY + inset, width: min(contentWidth, 520), height: 112)
        bones.append(SkeletonBone(rect: welcome, radius: 10, style: .outline))
        for (offset, width, height) in [(26, 180, 12), (50, 280, 10), (70, 230, 10)] as [(CGFloat, CGFloat, CGFloat)] {
            bones.append(SkeletonBone(
                rect: CGRect(x: welcome.minX + 20, y: welcome.minY + offset, width: min(width, welcome.width - 40), height: height),
                radius: height / 2,
                style: .fill
            ))
        }

        // The prompt box, its footer, and the output lines above it.
        let footer = CGRect(x: bounds.minX + inset + 4, y: bounds.maxY - inset - 8, width: min(120, contentWidth), height: 8)
        let prompt = CGRect(x: bounds.minX + inset, y: footer.minY - 14 - 44, width: contentWidth, height: 44)
        let lineWidth = min(contentWidth, 640)
        var y = welcome.maxY + 24
        for fraction in [0.62, 0.48, 0.7, 0.36] as [CGFloat] {
            let line = CGRect(x: bounds.minX + inset, y: y, width: lineWidth * fraction, height: 10)
            guard line.maxY <= prompt.minY - 24 else { break }
            bones.append(SkeletonBone(rect: line, radius: 5, style: .fill))
            y += 22
        }
        guard prompt.minY > welcome.maxY + 24 else { return bones }
        bones.append(SkeletonBone(rect: prompt, radius: 10, style: .outline))
        bones.append(SkeletonBone(
            rect: CGRect(x: prompt.minX + 16, y: prompt.midY - 6, width: 10, height: 12),
            radius: 3,
            style: .fill
        ))
        bones.append(SkeletonBone(
            rect: CGRect(x: prompt.minX + 36, y: prompt.midY - 5, width: min(140, prompt.width - 52), height: 10),
            radius: 5,
            style: .fill
        ))
        bones.append(SkeletonBone(rect: footer, radius: 4, style: .fill))
        return bones
    }

    static let notesHeaderHeight: CGFloat = 60
    static let notesListWidth: CGFloat = 330
    private static let noteCardHeights: [CGFloat] = [84, 68, 84, 76, 68, 84, 76, 68]

    /// Mirrors the Notes library: a header with the note count, the list of
    /// notes under a search field, and the open note beside it.
    private static func notesBones(in bounds: CGRect) -> [SkeletonBone] {
        guard bounds.width > notesListWidth + 160, bounds.height > notesHeaderHeight + 120 else { return [] }
        var bones: [SkeletonBone] = []

        // The header's note count.
        bones.append(SkeletonBone(
            rect: CGRect(x: bounds.minX + 22, y: bounds.minY + notesHeaderHeight / 2 - 6, width: 96, height: 12),
            radius: 6,
            style: .fill
        ))

        // The search field and the notes under it.
        let bodyTop = bounds.minY + notesHeaderHeight + 1
        let list = CGRect(x: bounds.minX, y: bodyTop, width: notesListWidth, height: bounds.maxY - bodyTop)
            .insetBy(dx: 18, dy: 18)
        let search = CGRect(x: list.minX, y: list.minY, width: list.width, height: ProgramTicketPanelStyle.compactFieldHeight)
        bones.append(SkeletonBone(rect: search, radius: 8, style: .outline))
        var y = search.maxY + 12
        for height in noteCardHeights {
            let card = CGRect(x: list.minX, y: y, width: list.width, height: height)
            guard card.maxY <= list.maxY else { break }
            bones.append(SkeletonBone(rect: card, radius: 12, style: .outline))
            bones.append(contentsOf: cardLines(in: card, wide: false))
            y = card.maxY + 8
        }

        // The open note: a title, a byline, then its paragraphs.
        let detailMinX = bounds.minX + notesListWidth + 1 + 28
        let detailWidth = bounds.maxX - 28 - detailMinX
        let top = bodyTop + 28
        bones.append(SkeletonBone(
            rect: CGRect(x: detailMinX, y: top, width: min(320, detailWidth * 0.5), height: 16),
            radius: 8,
            style: .fill
        ))
        bones.append(SkeletonBone(
            rect: CGRect(x: detailMinX, y: top + 28, width: min(180, detailWidth * 0.3), height: 8),
            radius: 4,
            style: .fill
        ))
        y = top + 64
        for fraction in [0.92, 0.86, 0.9, 0.64, 0.88, 0.94, 0.8, 0.52] as [CGFloat] {
            let line = CGRect(x: detailMinX, y: y, width: min(detailWidth, 720) * fraction, height: 10)
            guard line.maxY <= bounds.maxY - 28 else { break }
            bones.append(SkeletonBone(rect: line, radius: 5, style: .fill))
            y += 20
        }
        return bones
    }

    static let historyListWidth: CGFloat = 330
    private static let historyCardHeights: [CGFloat] = [98, 82, 98, 98, 82]

    /// Mirrors Workspace History before a ticket is chosen: the search
    /// field, the archive policy and the archived tickets on the left, and
    /// the empty placeholder on the right.
    private static func historyBones(in bounds: CGRect) -> [SkeletonBone] {
        guard bounds.width > historyListWidth + 160, bounds.height > 240 else { return [] }
        var bones: [SkeletonBone] = []

        // The search field and its button.
        let list = CGRect(x: bounds.minX, y: bounds.minY, width: historyListWidth, height: bounds.height)
            .insetBy(dx: 18, dy: 18)
        let button = SharedActionButtonMetrics.controlHeight
        let field = ProgramTicketPanelStyle.compactFieldHeight
        let search = CGRect(x: list.minX, y: list.minY, width: list.width - 8 - button, height: field)
        bones.append(SkeletonBone(rect: search, radius: 8, style: .outline))
        bones.append(SkeletonBone(
            rect: CGRect(x: search.maxX + 8, y: search.midY - button / 2, width: button, height: button),
            radius: 8,
            style: .outline
        ))

        // The archive policy.
        var y = search.maxY + 12
        for fraction in [0.9, 0.94, 0.4] as [CGFloat] {
            bones.append(SkeletonBone(
                rect: CGRect(x: list.minX, y: y + 3, width: list.width * fraction, height: 8),
                radius: 4,
                style: .fill
            ))
            y += 15
        }

        // The archived tickets: an id and status, a title, then the badge.
        y += 12
        for height in historyCardHeights {
            let card = CGRect(x: list.minX, y: y, width: list.width, height: height)
            guard card.maxY <= list.maxY else { break }
            bones.append(SkeletonBone(rect: card, radius: BoardDarkSurfaceStyle.nestedCardCornerRadius, style: .outline))
            let inset: CGFloat = 12
            let available = card.width - inset * 2
            bones.append(SkeletonBone(
                rect: CGRect(x: card.minX + inset, y: card.minY + 14, width: 52, height: 8),
                radius: 4,
                style: .fill
            ))
            bones.append(SkeletonBone(
                rect: CGRect(x: card.maxX - inset - 36, y: card.minY + 14, width: 36, height: 8),
                radius: 4,
                style: .fill
            ))
            var lineY = card.minY + 34
            for fraction in (height >= 98 ? [0.85, 0.5] : [0.7]) as [CGFloat] {
                bones.append(SkeletonBone(
                    rect: CGRect(x: card.minX + inset, y: lineY, width: available * fraction, height: 10),
                    radius: 5,
                    style: .fill
                ))
                lineY += 18
            }
            bones.append(SkeletonBone(
                rect: CGRect(x: card.minX + inset, y: card.maxY - 22, width: available * 0.4, height: 8),
                radius: 4,
                style: .fill
            ))
            y = card.maxY + 8
        }

        // The placeholder: an icon over a title and a supporting line.
        let detail = CGRect(x: bounds.minX + historyListWidth + 1, y: bounds.minY, width: bounds.width - historyListWidth - 1, height: bounds.height)
        let top = detail.midY - (28 + 10 + 12 + 10 + 8) / 2
        bones.append(SkeletonBone(
            rect: CGRect(x: detail.midX - 14, y: top, width: 28, height: 28),
            radius: 14,
            style: .fill
        ))
        bones.append(SkeletonBone(
            rect: CGRect(x: detail.midX - 80, y: top + 38, width: 160, height: 12),
            radius: 6,
            style: .fill
        ))
        let subtitleWidth = min(260, detail.width - 56)
        bones.append(SkeletonBone(
            rect: CGRect(x: detail.midX - subtitleWidth / 2, y: top + 60, width: subtitleWidth, height: 8),
            radius: 4,
            style: .fill
        ))
        return bones
    }

    static let settingsFooterHeight: CGFloat = 54

    /// Mirrors the Settings tab: the category sidebar, a column of settings
    /// with their controls above the footer, and the agent card.
    private static func settingsBones(panels: [CGRect]) -> [SkeletonBone] {
        guard panels.count == 2 else { return [] }
        let pane = panels[0]
        let card = panels[1]
        let style = SettingsContentStyle.workspace
        var bones: [SkeletonBone] = []

        // The sidebar's heading and categories.
        bones.append(SkeletonBone(
            rect: CGRect(x: pane.minX + 16, y: pane.minY + 22, width: 72, height: 14),
            radius: 7,
            style: .fill
        ))
        let rowWidth = style.sidebarWidth - 20
        for index in 0..<SettingsCategory.allCases.count {
            let row = CGRect(
                x: pane.minX + 10,
                y: pane.minY + 78 + CGFloat(index) * (SettingsLayout.sidebarRowHeight + 4),
                width: rowWidth,
                height: SettingsLayout.sidebarRowHeight
            )
            guard row.maxY <= pane.maxY - 16 else { break }
            bones.append(SkeletonBone(
                rect: CGRect(x: row.minX + 10, y: row.midY - 6, width: 12, height: 12),
                radius: 3,
                style: .fill
            ))
            bones.append(SkeletonBone(
                rect: CGRect(x: row.minX + 32, y: row.midY - 5, width: rowWidth * (index.isMultiple(of: 2) ? 0.55 : 0.45), height: 10),
                radius: 5,
                style: .fill
            ))
        }

        // The settings: section titles, each over rows of a label and a control.
        let detailMinX = pane.minX + style.sidebarWidth + 1
        let columnWidth = min(style.detailMaxWidth, pane.maxX - detailMinX)
        let contentMinX = detailMinX + style.detailPadding.leading
        let contentWidth = columnWidth - style.detailPadding.leading - style.detailPadding.trailing
        let footerTop = pane.maxY - settingsFooterHeight
        let controlWidth = min(160, contentWidth * 0.3)
        let rowHeight = SharedActionButtonMetrics.controlHeight + SettingsLayout.rowVerticalPadding * 2
        var y = pane.minY + style.detailPadding.top
        sections: for rowCount in [3, 2, 3] {
            let title = CGRect(x: contentMinX, y: y, width: 120, height: 12)
            guard title.maxY + SettingsLayout.sectionTitleSpacing + rowHeight <= footerTop - style.detailPadding.bottom else { break }
            bones.append(SkeletonBone(rect: title, radius: 6, style: .fill))
            y = title.maxY + SettingsLayout.sectionTitleSpacing
            for row in 0..<rowCount {
                guard y + rowHeight <= footerTop - style.detailPadding.bottom else { break sections }
                let midY = y + rowHeight / 2
                bones.append(SkeletonBone(
                    rect: CGRect(x: contentMinX, y: midY - 5, width: min(220, contentWidth * (row.isMultiple(of: 2) ? 0.4 : 0.3)), height: 10),
                    radius: 5,
                    style: .fill
                ))
                bones.append(SkeletonBone(
                    rect: CGRect(
                        x: contentMinX + contentWidth - controlWidth,
                        y: midY - SharedActionButtonMetrics.controlHeight / 2,
                        width: controlWidth,
                        height: SharedActionButtonMetrics.controlHeight
                    ),
                    radius: 6,
                    style: .outline
                ))
                y += rowHeight
            }
            y += SettingsLayout.sectionSpacing
        }

        // The footer: a status on the left and an action on the right.
        let footerMidY = footerTop + settingsFooterHeight / 2
        let footerMinX = detailMinX + style.footerPadding.leading
        let footerMaxX = pane.maxX - style.footerPadding.trailing
        bones.append(SkeletonBone(
            rect: CGRect(x: footerMinX, y: footerMidY - 5, width: 10, height: 10),
            radius: 5,
            style: .fill
        ))
        bones.append(SkeletonBone(
            rect: CGRect(x: footerMinX + 18, y: footerMidY - 4, width: min(160, (footerMaxX - footerMinX) * 0.4), height: 8),
            radius: 4,
            style: .fill
        ))
        bones.append(SkeletonBone(
            rect: CGRect(x: footerMaxX - 72, y: footerMidY - SharedActionButtonMetrics.controlHeight / 2, width: 72, height: SharedActionButtonMetrics.controlHeight),
            radius: 6,
            style: .outline
        ))

        // The agent card's name and subtitle.
        let nameWidth = min(160, card.width * 0.6)
        bones.append(SkeletonBone(
            rect: CGRect(x: card.midX - nameWidth / 2, y: card.minY + 64, width: nameWidth, height: 18),
            radius: 9,
            style: .fill
        ))
        let subtitleWidth = min(120, card.width * 0.45)
        bones.append(SkeletonBone(
            rect: CGRect(x: card.midX - subtitleWidth / 2, y: card.minY + 64 + 18 + 12, width: subtitleWidth, height: 10),
            radius: 5,
            style: .fill
        ))
        return bones
    }
}

/// The repeating shimmer, after Dotm Square 6 in the dotmatrix loaders
/// (github.com/zzzzshawn/matrix, main at e30b80a9): each column of dots is
/// a snake whose bright head steps one dot along it every fifth of a cycle,
/// leaving a tail that dims behind it. Alternate columns run up and down.
/// The dots are drawn in the style's highlight, and only their opacity
/// moves. Dotm steps between levels; here each dot glides from one level
/// to the next so the snake reads as smooth motion at the display's rate.
enum DotColumnSnakeAnimation {
    /// Dotm's `speed`: a cycle lasts 1.5 s divided by it.
    static let speed: Double = 1.25
    static let cycle: TimeInterval = 1.5 / speed
    /// A snake is five dots long, so a column repeats every five rows.
    static let phases = 5
    /// Dotm's opacity triplet, `opacityBase`, `opacityMid` and
    /// `opacityPeak`, from which the head and tail levels derive.
    static let opacityBase: Float = 0.12
    static let opacityMid: Float = 0.42
    static let opacityPeak: Float = 1
    /// The levels a dot steps through, from the head back along the tail.
    static var levels: [Float] {
        [
            0.6 * opacityPeak + 0.25 * opacityMid + 0.15 * opacityBase,
            0.3 * opacityPeak + 0.5 * opacityMid + 0.2 * opacityBase,
            0.6 * opacityMid + 0.4 * opacityBase,
            0.2 * opacityMid + 0.8 * opacityBase,
            0.625 * opacityBase,
        ]
    }
    /// Each level is reached a fifth of a cycle after the last.
    static let keyTimes: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 1]
    /// The levels in order, closing back on the head so the loop is seamless.
    static var loopValues: [Float] { levels + [levels[0]] }

    /// Where a dot sits along its column's snake, from 0 (lit first) to 4.
    /// Even columns rise, so their snake starts at the bottom of each run
    /// of five rows; odd columns fall.
    static func position(column: Int, row: Int) -> Int {
        let raw = column % 2 == 0 ? -row - 1 : row
        return (raw % phases + phases) % phases
    }

    /// How far into a cycle a position's dots start: a fifth per position.
    static func delay(forPhase phase: Int) -> TimeInterval {
        Double(phase) / Double(phases) * cycle
    }

    /// The brightness a position holds when the snake cannot move: Dotm's
    /// still gradient along the column, mapped onto the triplet.
    static func restingOpacity(forPhase phase: Int) -> Float {
        remapped(0.22 + Float(phase) / Float(phases - 1) * 0.66)
    }

    /// Dotm's piecewise map from its source opacities (0.08, 0.34, 0.94)
    /// onto the configured triplet.
    static func remapped(_ opacity: Float) -> Float {
        let source: [Float] = [0, 0.08, 0.34, 0.94, 1]
        let target: [Float] = [0, opacityBase, opacityMid, opacityPeak, 1]
        let value = min(1, max(0, opacity))
        for index in 1..<source.count where value <= source[index] {
            let progress = (value - source[index - 1]) / (source[index] - source[index - 1])
            return target[index - 1] + (target[index] - target[index - 1]) * progress
        }
        return 1
    }

    /// The glided level a position holds at `time`, matching the layer
    /// animation in `run(on:)`: linear between `loopValues` a fifth of a
    /// cycle apart, each position starting `delay(forPhase:)` after the head.
    static func opacity(forPhase phase: Int, at time: TimeInterval) -> Float {
        var local = (time - delay(forPhase: phase)).truncatingRemainder(dividingBy: cycle)
        if local < 0 { local += cycle }
        let progress = local / cycle
        let values = loopValues
        let index = min(values.count - 2, Int(progress / keyTimes[1]))
        let span = keyTimes[index + 1] - keyTimes[index]
        let fraction = Float((progress - keyTimes[index]) / span)
        return values[index] + (values[index + 1] - values[index]) * fraction
    }

    static func run(on layers: [CAShapeLayer]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (phase, layer) in layers.enumerated() {
            guard !RelayLayerMotion.reduceMotion else {
                layer.removeAnimation(forKey: SkeletonLoaderView.shimmerKey)
                layer.opacity = restingOpacity(forPhase: phase)
                continue
            }
            layer.opacity = levels[phases - 1]
            guard layer.animation(forKey: SkeletonLoaderView.shimmerKey) == nil else { continue }
            let snake = CAKeyframeAnimation(keyPath: "opacity")
            snake.values = loopValues
            snake.keyTimes = keyTimes.map { NSNumber(value: $0) }
            snake.calculationMode = .linear
            snake.duration = cycle
            snake.repeatCount = .infinity
            // Shift the loop so this position lights its delay behind the
            // head's start.
            snake.timeOffset = (cycle - delay(forPhase: phase)).truncatingRemainder(dividingBy: cycle)
            layer.add(snake, forKey: SkeletonLoaderView.shimmerKey)
        }
    }
}

/// How a dot field arrives and leaves: it disintegrates. The dots are dealt
/// into cohorts in a fixed, scattered order across the grid. As presence
/// rises from 0 to 1 each cohort fades in a little after the last, so dots
/// appear here and there across the field until it is full; falling back
/// to 0 runs the same way in reverse, the last dots to arrive leaving first.
enum DotPresence {
    /// Enough cohorts, each fading briefly, that dots visibly arrive one
    /// by one rather than the field fading as a block.
    static let cohorts = 24
    /// The share of the presence sweep each cohort spends fading.
    static let fade: Double = 0.12
    /// The sweep runs longer than an ordinary fade so the scatter reads.
    static let enterDuration: TimeInterval = 0.45
    static let exitDuration: TimeInterval = 0.35
    /// How long content replacing a dot field waits: its exit plus a beat.
    static let replacementDelay: TimeInterval = exitDuration + RelayMotion.replacementGap
    /// The sweep moves at an even pace so cohorts arrive evenly spaced.
    static var enter: Animation { .linear(duration: enterDuration) }
    static var exit: Animation { .linear(duration: exitDuration) }

    /// Deals a dot to a cohort by its grid position: fixed, so a relayout
    /// never reshuffles a field mid-transition, and scattered, so the
    /// cohorts do not form stripes.
    static func cohort(column: Int, row: Int) -> Int {
        // MurmurHash3's finaliser over the two coordinates, so neighbouring
        // dots land in unrelated cohorts.
        var hash = UInt32(truncatingIfNeeded: column) &* 0x9E37_79B1
        hash = hash &+ UInt32(truncatingIfNeeded: row) &* 0x85EB_CA77
        hash ^= hash >> 16
        hash &*= 0x85EB_CA6B
        hash ^= hash >> 13
        hash &*= 0xC2B2_AE35
        hash ^= hash >> 16
        return Int(hash % UInt32(cohorts))
    }

    /// The slice of the sweep, from 0 to 1, over which a cohort fades.
    static func window(ofCohort cohort: Int) -> (start: Double, end: Double) {
        let start = Double(cohort) / Double(cohorts) * (1 - fade)
        return (start, start + fade)
    }

    /// A cohort's opacity at a presence between 0 (gone) and 1 (all there).
    static func opacity(ofCohort cohort: Int, presence: Double) -> Float {
        let window = window(ofCohort: cohort)
        return Float(min(1, max(0, (presence - window.start) / fade)))
    }
}

/// The skeleton loader for SwiftUI screens.
struct SkeletonLoader: NSViewRepresentable {
    let layout: SkeletonLoaderLayout
    let label: String
    @Environment(\.dotPresence) private var presence

    func makeNSView(context: Context) -> SkeletonLoaderView {
        let view = SkeletonLoaderView(layout: layout, label: label)
        view.setPresence(presence)
        return view
    }

    func updateNSView(_ view: SkeletonLoaderView, context: Context) {
        view.setLabel(label)
        view.setPresence(presence)
    }
}
