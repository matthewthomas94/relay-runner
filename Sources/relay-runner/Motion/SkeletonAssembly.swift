import AppKit
import SwiftUI

/// The ready surface replaces its dotted sketch along one shared scan edge.
/// This starts as soon as data is ready; it never waits for the sketch to finish.
enum SkeletonAssembly {
    static let duration: TimeInterval = 0.6 * RelayMotion.durationScale
    static let blurRadius: CGFloat = 3
    static let maskName = "skeletonAssemblyMask"

    static func duration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0.18 * RelayMotion.durationScale : duration
    }

    static func animation(reduceMotion: Bool) -> Animation {
        RelayMotion.enterCurve.animation(duration: duration(reduceMotion: reduceMotion))
    }

    /// Complementary rectangles keep the sketch below the edge and real UI
    /// above it. AppKit's Workspace content and loader have different origins.
    static func clipRect(
        in bounds: CGRect, progress: CGFloat, sketch: Bool,
        flipped: Bool = true, scanBounds: CGRect? = nil
    ) -> CGRect {
        let scan = scanBounds ?? bounds
        let progress = min(1, max(0, progress))
        let edge = flipped ? scan.minY + scan.height * progress : scan.maxY - scan.height * progress
        let lower = (flipped == sketch) ? edge : bounds.minY
        let upper = (flipped == sketch) ? bounds.maxY : edge
        return CGRect(x: bounds.minX, y: lower, width: bounds.width, height: max(0, upper - lower))
    }

    static var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: SkeletonAssemblyEffect(progress: 0),
                identity: SkeletonAssemblyEffect(progress: 1)
            ),
            removal: .relaySurface
        )
    }

    static var loaderTransition: AnyTransition {
        .asymmetric(
            insertion: .relaySurface,
            removal: .modifier(
                active: SkeletonAssemblyEffect(progress: 1, sketch: true),
                identity: SkeletonAssemblyEffect(progress: 0, sketch: true)
            )
        )
    }

    /// Masks the actual hosted UI, not a screenshot. The live controls and
    /// terminal retain their identity throughout the handoff.
    static func animateMask(
        on view: NSView, sketch: Bool, scanBounds: CGRect? = nil,
        reduceMotion: Bool = RelayLayerMotion.reduceMotion,
        completion: (() -> Void)? = nil
    ) {
        cancel(on: view)
        guard !reduceMotion, let layer = view.layer else {
            completion?()
            return
        }
        let mask = CAShapeLayer()
        mask.name = maskName
        mask.frame = view.bounds
        mask.fillColor = NSColor.black.cgColor
        let start = clipRect(in: view.bounds, progress: 0, sketch: sketch,
                             flipped: view.isFlipped, scanBounds: scanBounds)
        let end = clipRect(in: view.bounds, progress: 1, sketch: sketch,
                           flipped: view.isFlipped, scanBounds: scanBounds)
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = CGPath(rect: start, transform: nil)
        animation.toValue = CGPath(rect: end, transform: nil)
        animation.duration = duration
        animation.timingFunction = RelayMotion.enterCurve.mediaTimingFunction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak layer, weak mask] in
            guard let layer, let mask, layer.mask === mask else { return }
            layer.mask = nil
            completion?()
        }
        mask.path = CGPath(rect: end, transform: nil)
        layer.mask = mask
        mask.add(animation, forKey: maskName)
        CATransaction.commit()
    }

    static func cancel(on view: NSView) {
        guard let layer = view.layer, layer.mask?.name == maskName else { return }
        layer.mask = nil
    }

    /// Handles and readouts stay whole past the scan edge, then fade in the
    /// last part of the handoff, the way a design tool's chrome lets go once
    /// the layout resolves.
    static let chromeOpacityStops: [(progress: Double, opacity: Float)] = [(0, 1), (0.6, 1), (1, 0)]

    static func chromeOpacity(progress: CGFloat) -> Float {
        let progress = min(1, max(0, progress))
        return Float(1 - max(0, (progress - 0.6) / 0.4))
    }
}

/// Progress of a SwiftUI-driven sketch handoff, read by the hosted loader.
/// `nil` means the loader is not handing off.
struct SkeletonHandoffProgressKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var skeletonHandoffProgress: CGFloat? {
        get { self[SkeletonHandoffProgressKey.self] }
        set { self[SkeletonHandoffProgressKey.self] = newValue }
    }
}

struct SkeletonAssemblyEffect: AnimatableModifier {
    var progress: CGFloat
    var sketch = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let progress = min(1, max(0, progress))
        if sketch {
            // The loader scans itself so its chrome can outlive the edge.
            content
                .opacity(reduceMotion ? 1 - progress : 1)
                .environment(\.skeletonHandoffProgress, reduceMotion ? nil : progress)
        } else {
            content
                .opacity(progress)
                .blur(radius: reduceMotion ? 0 : SkeletonAssembly.blurRadius * (1 - progress))
                .mask {
                    if reduceMotion {
                        Rectangle()
                    } else {
                        GeometryReader { geometry in
                            Path(SkeletonAssembly.clipRect(
                                in: CGRect(origin: .zero, size: geometry.size),
                                progress: progress, sketch: false
                            )).fill(.white)
                        }
                    }
                }
        }
    }
}
