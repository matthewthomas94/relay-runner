import AppKit
import SwiftUI

struct ProgramActiveTicketGlowPresentation: Equatable {
    let isVisible: Bool
    let animatesMask: Bool

    static func resolve(item: ProgramStatusItem, reduceMotion: Bool) -> ProgramActiveTicketGlowPresentation {
        ProgramActiveTicketGlowPresentation(
            isVisible: item.hasActiveWorker,
            animatesMask: item.hasActiveWorker && !reduceMotion
        )
    }
}

struct ProgramActiveTicketGlowBackground: View {
    let presentation: ProgramActiveTicketGlowPresentation

    var body: some View {
        GeometryReader { proxy in
            let size = ActiveTicketGlowMaskGeometry.effectSize(forCardSize: proxy.size)
            ProgramActiveTicketGlowHost(
                isVisible: presentation.isVisible,
                animatesMask: presentation.animatesMask
            )
            .frame(width: size.width, height: size.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ProgramActiveTicketGlowHost: NSViewRepresentable {
    let isVisible: Bool
    let animatesMask: Bool

    func makeNSView(context: Context) -> ActiveTicketParticleGlowView {
        ActiveTicketParticleGlowView()
    }

    func updateNSView(_ view: ActiveTicketParticleGlowView, context: Context) {
        view.setVisible(isVisible, animatesMask: animatesMask)
    }

    static func dismantleNSView(_ view: ActiveTicketParticleGlowView, coordinator: ()) {
        view.setVisible(false, animatesMask: false)
    }
}

final class ActiveTicketParticleGlowView: NSView {
    private let renderer: ParticleFieldRenderer
    private let maskLayer = CAShapeLayer()
    private let animationClock: ParticleFieldAnimationClock

    private var maskToken: UUID?
    private var visible = false
    private var animatesMask = false
    private var maskStartTime: CFTimeInterval = 0

    init(animationClock: ParticleFieldAnimationClock = .shared) {
        self.animationClock = animationClock
        self.renderer = ParticleFieldRenderer(animationClock: animationClock)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false
        layer?.mask = maskLayer
        layer?.actions = ["opacity": NSNull()]
        maskLayer.fillColor = NSColor.black.cgColor
        maskLayer.actions = ["path": NSNull()]

        renderer.attach(to: self)
        renderer.setIntensity(0.96)
        updateMask(elapsed: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopMaskUpdates()
        renderer.transition(to: nil)
    }

    override func layout() {
        super.layout()
        if visible {
            renderer.layoutInBounds(bounds, backingScale: window?.backingScaleFactor)
        }
        updateMask(elapsed: currentMaskElapsed)
    }

    func setVisible(_ visible: Bool, animatesMask: Bool) {
        let didChangeVisibility = self.visible != visible
        let didChangeAnimation = self.animatesMask != animatesMask
        self.visible = visible
        self.animatesMask = animatesMask

        guard didChangeVisibility || didChangeAnimation else { return }

        if visible {
            if didChangeVisibility {
                maskStartTime = CACurrentMediaTime()
            }
            renderer.layoutInBounds(bounds, backingScale: window?.backingScaleFactor)
            renderer.transition(to: .tts)
            if animatesMask {
                startMaskUpdates()
            } else {
                stopMaskUpdates()
                updateMask(elapsed: 0)
            }
        } else {
            stopMaskUpdates()
            renderer.transition(to: nil)
        }
    }

    private var currentMaskElapsed: CFTimeInterval {
        guard visible, animatesMask else { return 0 }
        return CACurrentMediaTime() - maskStartTime
    }

    private func startMaskUpdates() {
        guard maskToken == nil else { return }
        updateMask(elapsed: currentMaskElapsed)
        maskToken = animationClock.add { [weak self] in
            self?.updateMask(elapsed: self?.currentMaskElapsed ?? 0)
        }
    }

    private func stopMaskUpdates() {
        if let maskToken {
            animationClock.remove(maskToken)
            self.maskToken = nil
        }
    }

    private func updateMask(elapsed: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        maskLayer.path = ActiveTicketGlowMaskGeometry.path(in: bounds, elapsed: elapsed)
        CATransaction.commit()
    }
}

enum ActiveTicketGlowMaskGeometry {
    static let horizontalOutset: CGFloat = 82
    static let verticalOutset: CGFloat = 70

    static func effectSize(forCardSize cardSize: CGSize) -> CGSize {
        CGSize(
            width: max(1, cardSize.width + horizontalOutset * 2),
            height: max(1, cardSize.height + verticalOutset * 2)
        )
    }

    static func path(in bounds: CGRect, elapsed: CFTimeInterval) -> CGPath {
        guard bounds.width > 0, bounds.height > 0 else {
            return CGPath(rect: .zero, transform: nil)
        }

        let pointCount = 96
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let baseRX = bounds.width * 0.34
        let baseRY = bounds.height * 0.30
        let phase = CGFloat(elapsed)
        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)

        for index in 0..<pointCount {
            let angle = (CGFloat(index) / CGFloat(pointCount)) * 2 * .pi
            let lobeA = sin(angle * 2.0 + phase * 0.73)
            let lobeB = sin(angle * 3.0 - phase * 0.51 + 0.8)
            let lobeC = sin(angle * 5.0 + phase * 0.29 + 1.7)
            let pinch = sin(angle - phase * 0.37) * sin(angle * 4.0 + phase * 0.61)
            let radius = 1.0 + lobeA * 0.16 + lobeB * 0.11 + lobeC * 0.07 + pinch * 0.06

            points.append(CGPoint(
                x: center.x + cos(angle) * baseRX * radius,
                y: center.y + sin(angle) * baseRY * radius
            ))
        }

        let path = CGMutablePath()
        let firstMid = midpoint(points[0], points[pointCount - 1])
        path.move(to: firstMid)
        for index in 0..<pointCount {
            let current = points[index]
            let next = points[(index + 1) % pointCount]
            path.addQuadCurve(to: midpoint(current, next), control: current)
        }
        path.closeSubpath()
        return path
    }

    static func boundingBox(in bounds: CGRect, elapsed: CFTimeInterval) -> CGRect {
        path(in: bounds, elapsed: elapsed).boundingBoxOfPath
    }

    private static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }
}
