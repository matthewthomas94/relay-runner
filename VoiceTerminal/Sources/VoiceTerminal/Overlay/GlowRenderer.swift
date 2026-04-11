import AppKit
import QuartzCore

/// Renders glow gradients on 4 screen edges using CAGradientLayer.
/// Driven by OverlayState — each state has distinct color, opacity, and animation.
final class GlowRenderer {

    private let topLayer = CAGradientLayer()
    private let bottomLayer = CAGradientLayer()
    private let leftLayer = CAGradientLayer()
    private let rightLayer = CAGradientLayer()

    private var allLayers: [CAGradientLayer] { [topLayer, bottomLayer, leftLayer, rightLayer] }

    private let glowDepth: CGFloat = 60
    private var intensityMultiplier: Double = 0.6

    private var currentState: OverlayState = .idle

    init() {
        for layer in allLayers {
            layer.opacity = 0
            layer.actions = ["opacity": NSNull(), "colors": NSNull()]  // disable implicit animations
        }

        // Gradient directions: edge → inward (color → clear)
        topLayer.startPoint = CGPoint(x: 0.5, y: 0)
        topLayer.endPoint = CGPoint(x: 0.5, y: 1)

        bottomLayer.startPoint = CGPoint(x: 0.5, y: 1)
        bottomLayer.endPoint = CGPoint(x: 0.5, y: 0)

        leftLayer.startPoint = CGPoint(x: 0, y: 0.5)
        leftLayer.endPoint = CGPoint(x: 1, y: 0.5)

        rightLayer.startPoint = CGPoint(x: 1, y: 0.5)
        rightLayer.endPoint = CGPoint(x: 0, y: 0.5)
    }

    /// Attach glow layers to a host layer (the overlay panel's content view layer).
    func attach(to hostLayer: CALayer) {
        for layer in allLayers {
            hostLayer.addSublayer(layer)
        }
        layoutLayers(in: hostLayer.bounds)
    }

    /// Update layer frames when the panel resizes.
    func layoutLayers(in bounds: CGRect) {
        let w = bounds.width
        let h = bounds.height
        let d = glowDepth

        topLayer.frame = CGRect(x: 0, y: h - d, width: w, height: d)
        bottomLayer.frame = CGRect(x: 0, y: 0, width: w, height: d)
        leftLayer.frame = CGRect(x: 0, y: 0, width: d, height: h)
        rightLayer.frame = CGRect(x: w - d, y: 0, width: d, height: h)
    }

    /// Update glow intensity multiplier from settings (0.0 - 1.0).
    func setIntensity(_ value: Double) {
        intensityMultiplier = max(0, min(1, value))
        // Re-apply current state with new intensity
        transition(to: currentState)
    }

    /// Transition glow to a new state with smooth animation.
    func transition(to state: OverlayState) {
        currentState = state

        let targetOpacity = Float(state.glowOpacity * intensityMultiplier)
        let color = glowColor(for: state)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

        for layer in allLayers {
            layer.colors = [color.cgColor, NSColor.clear.cgColor]
            layer.opacity = targetOpacity
        }

        CATransaction.commit()

        // Breathing animation for applicable states
        if state.shouldBreath && targetOpacity > 0 {
            addBreathAnimation(baseOpacity: targetOpacity)
        } else {
            removeBreathAnimation()
        }
    }

    // MARK: - Private

    private func glowColor(for state: OverlayState) -> NSColor {
        NSColor(
            hue: state.glowHue,
            saturation: state.glowSaturation,
            brightness: 0.95,
            alpha: 0.8
        )
    }

    private func addBreathAnimation(baseOpacity: Float) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = baseOpacity * 0.5
        anim.toValue = baseOpacity
        anim.duration = 2.0
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        for layer in allLayers {
            layer.add(anim, forKey: "breath")
        }
    }

    private func removeBreathAnimation() {
        for layer in allLayers {
            layer.removeAnimation(forKey: "breath")
        }
    }
}
