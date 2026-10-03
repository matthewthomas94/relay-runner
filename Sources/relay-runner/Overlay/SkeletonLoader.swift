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

/// A loading state that sketches the screen it stands in for: bare shapes
/// with a slow shimmer passing over them. It shows no text; its label is
/// for VoiceOver only.
///
/// The shimmer is a Core Animation gradient, so it runs on the render
/// server without per-frame work on the main thread. Reduce Motion holds
/// it still.
final class SkeletonLoaderView: NSView {
    static let boneBaseColor = NSColor(srgbRed: 22 / 255, green: 27 / 255, blue: 36 / 255, alpha: 1)
    static let boneHighlightColor = NSColor(srgbRed: 36 / 255, green: 43 / 255, blue: 55 / 255, alpha: 1)
    static let outlineWidth: CGFloat = 1.5
    static let boneOpacity: Float = 0.33
    static let shimmerKey = "skeletonShimmer"

    let skeleton: SkeletonLoaderLayout

    private let panelsLayer = CAShapeLayer()
    private let bonesGradient = CAGradientLayer()
    private let bonesMask = CALayer()
    private let fillMask = CAShapeLayer()
    private let outlineMask = CAShapeLayer()

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

        bonesGradient.colors = [
            Self.boneBaseColor.cgColor,
            Self.boneHighlightColor.cgColor,
            Self.boneBaseColor.cgColor,
        ]
        bonesGradient.startPoint = CGPoint(x: 0, y: 0.4)
        bonesGradient.endPoint = CGPoint(x: 1, y: 0.6)
        bonesGradient.locations = ShimmerAnimation.restingLocations
        fillMask.fillColor = NSColor.black.cgColor
        outlineMask.fillColor = nil
        outlineMask.strokeColor = NSColor.black.cgColor
        outlineMask.lineWidth = Self.outlineWidth
        bonesMask.addSublayer(fillMask)
        bonesMask.addSublayer(outlineMask)
        bonesGradient.mask = bonesMask
        bonesGradient.opacity = Self.boneOpacity
        layer?.addSublayer(bonesGradient)

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
        bonesGradient.frame = bounds
        bonesMask.frame = bounds
        fillMask.frame = bounds
        outlineMask.frame = bounds
        let fills = CGMutablePath()
        let outlines = CGMutablePath()
        for bone in bones {
            switch bone.style {
            case .fill:
                fills.addRoundedRect(in: bone.rect, cornerWidth: bone.radius, cornerHeight: bone.radius)
            case .outline:
                let inset = Self.outlineWidth / 2
                outlines.addRoundedRect(
                    in: bone.rect.insetBy(dx: inset, dy: inset),
                    cornerWidth: bone.radius,
                    cornerHeight: bone.radius
                )
            }
        }
        fillMask.path = fills
        outlineMask.path = outlines
        CATransaction.commit()

        ShimmerAnimation.run(on: bonesGradient, duration: 2.2, pause: 0.9)
    }

    /// Changes what VoiceOver announces.
    func setLabel(_ label: String) {
        setAccessibilityLabel(label)
    }

    // MARK: Geometry

    /// The surfaces behind the bones: the board's columns, the Notes
    /// library, or the Settings pane and its agent card.
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

/// The repeating shimmer: an eased pass of the gradient's bright stop from
/// left to right, then a rest.
enum ShimmerAnimation {
    /// The band sits off the left edge between passes.
    static let restingLocations: [NSNumber] = [-0.5, -0.25, 0]
    static let finalLocations: [NSNumber] = [1, 1.25, 1.5]

    static func run(on layer: CAGradientLayer, duration: TimeInterval, pause: TimeInterval) {
        guard !RelayLayerMotion.reduceMotion else {
            layer.removeAnimation(forKey: SkeletonLoaderView.shimmerKey)
            return
        }
        guard layer.animation(forKey: SkeletonLoaderView.shimmerKey) == nil else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = restingLocations
        sweep.toValue = finalLocations
        sweep.duration = duration
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
        let group = CAAnimationGroup()
        group.animations = [sweep]
        group.duration = duration + pause
        group.repeatCount = .infinity
        layer.add(group, forKey: SkeletonLoaderView.shimmerKey)
    }
}

/// The skeleton loader for SwiftUI screens.
struct SkeletonLoader: NSViewRepresentable {
    let layout: SkeletonLoaderLayout
    let label: String

    func makeNSView(context: Context) -> SkeletonLoaderView {
        SkeletonLoaderView(layout: layout, label: label)
    }

    func updateNSView(_ view: SkeletonLoaderView, context: Context) {
        view.setLabel(label)
    }
}
