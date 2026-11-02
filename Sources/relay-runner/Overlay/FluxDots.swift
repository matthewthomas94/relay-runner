import AppKit
import QuartzCore
import SwiftUI

/// Round dots that shimmer by the skeleton loader's rules: its dot size,
/// spacing and colours, and the Flux Columns shimmer. The loader draws its
/// filled bones with them, and hovered navigation items their backgrounds.
///
/// Each snake phase has its own shape layer so its dots change together.
final class FluxDotLayers {
    /// Holds the phase layers. It sits back at the bones' opacity.
    let container = CALayer()
    let phaseLayers = (0..<FluxColumnsAnimation.steps).map { _ in CAShapeLayer() }

    init() {
        for layer in phaseLayers {
            layer.fillColor = SkeletonLoaderView.boneBaseColor.cgColor
            container.addSublayer(layer)
        }
        container.opacity = SkeletonLoaderView.boneOpacity
    }

    /// Fills each rounded shape with dots and starts the shimmer.
    func fill(_ shapes: [(rect: CGRect, cornerRadius: CGFloat)], in bounds: CGRect) {
        let diameter = SkeletonLoaderView.dotDiameter
        let paths = phaseLayers.map { _ in CGMutablePath() }
        for shape in shapes {
            for dot in SkeletonLoaderView.dots(in: shape.rect, cornerRadius: shape.cornerRadius) {
                paths[dot.fluxPhase].addEllipse(in: CGRect(
                    x: dot.centre.x - diameter / 2,
                    y: dot.centre.y - diameter / 2,
                    width: diameter,
                    height: diameter
                ))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        for (layer, path) in zip(phaseLayers, paths) {
            layer.frame = bounds
            layer.path = path
        }
        CATransaction.commit()
        FluxColumnsAnimation.run(on: phaseLayers)
    }
}

/// A rounded shape filled with shimmering dots. It takes no clicks.
final class FluxDotsView: NSView {
    var cornerRadius: CGFloat {
        didSet { needsLayout = true }
    }

    let dots = FluxDotLayers()

    override var isFlipped: Bool { true }

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
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
        dots.fill([(bounds, cornerRadius)], in: bounds)
    }
}

/// The hover background for navigation items: shimmering dots in place of
/// a solid fill.
struct FluxDotsBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> FluxDotsView {
        FluxDotsView(cornerRadius: cornerRadius)
    }

    func updateNSView(_ view: FluxDotsView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}
