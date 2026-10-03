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
/// with a slow shimmer passing over them, and a shimmering label at the
/// centre.
///
/// Both shimmers are Core Animation gradients, so they run on the render
/// server without per-frame work on the main thread. Reduce Motion holds
/// everything still.
final class SkeletonLoaderView: NSView {
    static let boneBaseColor = NSColor(srgbRed: 22 / 255, green: 27 / 255, blue: 36 / 255, alpha: 1)
    static let boneHighlightColor = NSColor(srgbRed: 36 / 255, green: 43 / 255, blue: 55 / 255, alpha: 1)
    static let outlineWidth: CGFloat = 1.5
    static let boneOpacity: Float = 0.5
    static let shimmerKey = "skeletonShimmer"

    let skeleton: SkeletonLoaderLayout
    let labelView: ShimmerLabelView

    private let panelsLayer = CAShapeLayer()
    private let bonesGradient = CAGradientLayer()
    private let bonesMask = CALayer()
    private let fillMask = CAShapeLayer()
    private let outlineMask = CAShapeLayer()
    private var pendingLabel: String?

    private(set) var bones: [SkeletonBone] = []

    override var isFlipped: Bool { true }

    init(layout: SkeletonLoaderLayout, label: String) {
        self.skeleton = layout
        labelView = ShimmerLabelView(text: label)
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

        addSubview(labelView)

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
        let labelSize = labelView.fittingSize
        labelView.frame = CGRect(
            x: ((bounds.width - labelSize.width) / 2).rounded(),
            y: ((bounds.height - labelSize.height) / 2).rounded(),
            width: labelSize.width,
            height: labelSize.height
        )
        bones = Self.bones(for: skeleton, in: bounds, clearing: labelClearing)

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

    /// Changes the label, letting the old one leave before the new one
    /// arrives. Rapid changes settle on the newest label.
    func setLabel(_ label: String, animated: Bool) {
        setAccessibilityLabel(label)
        let current = pendingLabel ?? labelView.text
        guard label != current else { return }
        guard animated, window != nil, !labelView.isHidden else {
            pendingLabel = nil
            labelView.text = label
            needsLayout = true
            return
        }
        let swapping = pendingLabel != nil
        pendingLabel = label
        guard !swapping else { return }
        RelayLayerMotion.animateOut(labelView, style: .text, hidesWhenDone: false) { [weak self] in
            guard let self, let next = self.pendingLabel else { return }
            self.pendingLabel = nil
            self.labelView.text = next
            self.layout()
            RelayLayerMotion.animateIn(self.labelView, style: .text, delay: RelayMotion.replacementGap)
        }
    }

    /// The space around the label that no bone crosses.
    var labelClearing: CGRect {
        labelView.frame.insetBy(dx: -24, dy: -14)
    }

    // MARK: Geometry

    /// The board's column panels, behind the bones.
    static func panels(for layout: SkeletonLoaderLayout, in bounds: CGRect) -> [CGRect] {
        guard case .board(let top) = layout else { return [] }
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

    static func bones(
        for layout: SkeletonLoaderLayout,
        in bounds: CGRect,
        clearing: CGRect
    ) -> [SkeletonBone] {
        switch layout {
        case .board:
            return boardBones(panels: panels(for: layout, in: bounds), clearing: clearing)
        case .terminal:
            return terminalBones(in: bounds, clearing: clearing)
        }
    }

    /// Card heights for each lane, so the lanes read as different lists.
    private static let laneCardHeights: [[CGFloat]] = [
        [88, 72, 96, 72, 88],
        [72, 88],
        [96, 72, 88],
        [72, 72, 88, 72, 96, 72],
    ]

    private static func boardBones(panels: [CGRect], clearing: CGRect) -> [SkeletonBone] {
        var bones: [SkeletonBone] = []
        for (index, panel) in panels.enumerated() {
            // The column header: a title and an action.
            let headerMidY = panel.minY + ProgramBoardLayout.panelVerticalPadding
                + ProgramBoardLayout.workHeaderHeight / 2
            let titleWidth = min(96, panel.width * 0.3)
            for bone in [
                SkeletonBone(
                    rect: CGRect(x: panel.minX + 24, y: headerMidY - 6, width: titleWidth, height: 12),
                    radius: 6,
                    style: .fill
                ),
                SkeletonBone(
                    rect: CGRect(x: panel.maxX - 24 - 24, y: headerMidY - 12, width: 24, height: 24),
                    radius: 8,
                    style: .fill
                ),
            ] where !bone.rect.intersects(clearing) {
                bones.append(bone)
            }

            // The cards, stacked until the column or the label stops them.
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
                guard card.maxY <= panel.maxY - 16, !card.intersects(clearing) else { break }
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

    private static func terminalBones(in bounds: CGRect, clearing: CGRect) -> [SkeletonBone] {
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
            guard line.maxY <= prompt.minY - 24, !line.intersects(clearing) else { break }
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
}

/// A single line of text with a soft band of light easing across it.
final class ShimmerLabelView: NSView {
    static let baseColor = NSColor.white.withAlphaComponent(0.5)
    static let bandColor = NSColor.white.withAlphaComponent(0.98)
    static let restingColor = NSColor.white.withAlphaComponent(0.88)
    // Room around the text so the transition blur is not clipped.
    private static let blurMargin: CGFloat = 8

    private let gradient = CAGradientLayer()
    private let textMask = CATextLayer()

    var text: String {
        didSet {
            guard text != oldValue else { return }
            updateText()
        }
    }

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = ShimmerAnimation.restingLocations
        textMask.alignmentMode = .center
        textMask.truncationMode = .end
        gradient.mask = textMask
        layer?.addSublayer(gradient)
        updateText()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var fittingSize: NSSize {
        let size = attributedText.size()
        return NSSize(
            width: ceil(size.width) + Self.blurMargin * 2,
            height: ceil(size.height) + Self.blurMargin * 2
        )
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        textMask.frame = bounds.insetBy(dx: Self.blurMargin, dy: Self.blurMargin)
        CATransaction.commit()
        ShimmerAnimation.run(on: gradient, duration: 1.8, pause: 0.7)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        textMask.contentsScale = window?.backingScaleFactor ?? 2
    }

    private var attributedText: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: AppTypography.appKitFont(.sectionHeading),
            .foregroundColor: NSColor.white,
        ])
    }

    private func updateText() {
        let still = RelayLayerMotion.reduceMotion
        gradient.colors = still
            ? [Self.restingColor.cgColor, Self.restingColor.cgColor, Self.restingColor.cgColor]
            : [Self.baseColor.cgColor, Self.bandColor.cgColor, Self.baseColor.cgColor]
        textMask.string = attributedText
        textMask.contentsScale = window?.backingScaleFactor ?? 2
        needsLayout = true
    }
}

/// The repeating sweep both shimmers share: an eased pass of the gradient's
/// bright stop from left to right, then a rest.
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
        view.setLabel(label, animated: true)
    }
}
