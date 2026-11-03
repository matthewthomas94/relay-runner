import AppKit
import QuartzCore
import SwiftUI

/// The colours and opacity of shimmering dots. Every style shares the
/// skeleton loader's dot size, spacing and shimmer.
struct FluxDotStyle: Equatable {
    /// The tail's dimmest colour, which the head's highlight fades down to.
    let base: NSColor
    let highlight: NSColor
    let opacity: Float

    /// The skeleton loaders and the hover on the Workspace tabs and the
    /// Settings sidebar: opaque, so the dots show on black.
    static let standard = FluxDotStyle(
        base: SkeletonLoaderView.boneBaseColor,
        highlight: SkeletonLoaderView.boneHighlightColor,
        opacity: 1
    )
}

/// Round dots that shimmer by the skeleton loader's rules: its dot size and
/// spacing, and the Flux Columns shimmer, in a style's colours. The loader
/// draws its filled bones with them, and hovered navigation items their
/// backgrounds.
///
/// Each snake phase has its own shape layer so its dots change together.
final class FluxDotLayers {
    /// Holds the phase layers, at the style's opacity.
    let container = CALayer()
    let phaseLayers = (0..<FluxColumnsAnimation.steps).map { _ in CAShapeLayer() }
    let style: FluxDotStyle

    init(style: FluxDotStyle = .standard) {
        self.style = style
        for layer in phaseLayers {
            layer.fillColor = style.base.cgColor
            container.addSublayer(layer)
        }
        container.opacity = style.opacity
    }

    /// Fills each rounded shape in the view with dots and starts the
    /// shimmer. Like the notch glyph's, each dot sits on whole screen pixels,
    /// so its edges stay crisp; half a pixel off, it blurs and looks smaller.
    func fill(_ shapes: [(rect: CGRect, cornerRadius: CGFloat)], in view: NSView) {
        let diameter = SkeletonLoaderView.dotDiameter
        let paths = phaseLayers.map { _ in CGMutablePath() }
        for shape in shapes {
            for dot in SkeletonLoaderView.dots(in: shape.rect, cornerRadius: shape.cornerRadius) {
                paths[dot.fluxPhase].addEllipse(in: view.backingAlignedRect(
                    CGRect(
                        x: dot.centre.x - diameter / 2,
                        y: dot.centre.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    ),
                    options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]
                ))
            }
        }
        let bounds = view.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        for (layer, path) in zip(phaseLayers, paths) {
            layer.frame = bounds
            layer.path = path
        }
        CATransaction.commit()
        FluxColumnsAnimation.run(on: phaseLayers, style: style)
    }
}

/// A rounded shape filled with shimmering dots. It takes no clicks.
final class FluxDotsView: NSView {
    var cornerRadius: CGFloat {
        didSet { needsLayout = true }
    }

    let dots: FluxDotLayers

    override var isFlipped: Bool { true }

    init(cornerRadius: CGFloat, style: FluxDotStyle) {
        self.cornerRadius = cornerRadius
        dots = FluxDotLayers(style: style)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(dots.container)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        dots.fill([(bounds, cornerRadius)], in: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

/// The hover background for navigation items: shimmering dots in place of
/// a solid fill.
struct FluxDotsBackground: NSViewRepresentable {
    let cornerRadius: CGFloat
    let style: FluxDotStyle

    func makeNSView(context: Context) -> FluxDotsView {
        FluxDotsView(cornerRadius: cornerRadius, style: style)
    }

    func updateNSView(_ view: FluxDotsView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}
