import Observation
import SwiftUI

/// One reversible timeline: tile convergence, then disc collapse and hub exit.
struct SessionWheelPresentation: Equatable {
    static let segmentDuration: TimeInterval = 0.1
    static let discDuration: TimeInterval = 0.1
    static let duration = segmentDuration + discDuration
    static let blurDuration: TimeInterval = min(0.3, duration)
    static let reducedDuration: TimeInterval = 0.12

    /// How far each tile travels toward the hub, keeping its size. The average
    /// of the original six-tile tuning; the direction comes from each tile's
    /// own angle, so the wheel converges evenly at any segment count.
    static let convergenceDistance: CGFloat = 19

    var discScale: CGFloat = 1
    var hubVisibility: Double = 1
    var blurProgress: CGFloat = 0
    var segmentConvergence: CGFloat = 0
    var segmentVisibility: Double = 1
    var opacity: Double = 1
    let progress: Double

    init(progress: Double = 1, reduceMotion: Bool = false) {
        let progress = min(max(progress, 0), 1)
        self.progress = progress
        if reduceMotion {
            opacity = progress
            return
        }
        if progress == 0 {
            discScale = 0
            hubVisibility = 0
            blurProgress = 1
            segmentConvergence = 1
            segmentVisibility = 0
            return
        }
        let elapsed = (1 - progress) * Self.duration
        segmentConvergence = RelayMotion.exitCurve.progress(elapsed / Self.segmentDuration)
        let collapse = RelayMotion.exitCurve.progress(
            (elapsed - Self.segmentDuration) / Self.discDuration)
        discScale = 1 - collapse
        segmentVisibility = Double(discScale)
        hubVisibility = Double(1 - collapse)
        blurProgress = RelayMotion.exitCurve.progress(
            (elapsed - (Self.duration - Self.blurDuration)) / Self.blurDuration)
    }

    var hubBlur: CGFloat { 24 * blurProgress }
    var segmentBlur: CGFloat { 48 * blurProgress }

    static func animation(reduceMotion: Bool) -> Animation {
        .linear(duration: reduceMotion ? reducedDuration : duration)
    }

    /// Straight toward the hub from the tile's centre: slot 0 sits at the top
    /// and the slots run clockwise.
    func segmentOffset(_ index: Int) -> CGSize {
        let angle = CGFloat(index) * SessionWheelGeometry.sliceAngle - .pi / 2
        let distance = Self.convergenceDistance * segmentConvergence
        return CGSize(width: -cos(angle) * distance, height: -sin(angle) * distance)
    }
}

@Observable
final class SessionWheelMotion {
    private var from: Double = 0
    private var target: Double = 0
    private var startedAt: TimeInterval = 0
    private var duration: TimeInterval = 0
    private(set) var isAnimating = false
    private(set) var reduceMotion = false
    var isPresented: Bool { target == 1 }

    init(visible: Bool = false) {
        from = visible ? 1 : 0
        target = from
    }

    func progress(at time: TimeInterval) -> Double {
        guard isAnimating, duration > 0 else { return target }
        let fraction = min(max((time - startedAt) / duration, 0), 1)
        return from + (target - from) * fraction
    }

    /// Retarget from the displayed position, keeping the speed through rapid toggles.
    @discardableResult
    func setVisible(_ visible: Bool, reduceMotion: Bool, at time: TimeInterval) -> TimeInterval {
        from = progress(at: time)
        target = visible ? 1 : 0
        startedAt = time
        self.reduceMotion = reduceMotion
        duration = abs(target - from) * (reduceMotion
            ? SessionWheelPresentation.reducedDuration : SessionWheelPresentation.duration)
        isAnimating = duration > 0
        return duration
    }

    func finish() {
        from = target
        isAnimating = false
    }
}

/// The slots the wheel draws, captured so live session changes update in place.
struct SessionWheelMenu: Equatable {
    let sessions: [SessionWheelSession?]
    let canStartSession: Bool

    init(_ model: SessionWheelModel) {
        sessions = model.slots
        canStartSession = model.canStartSession
    }

    var identity: [String?] { sessions.map { $0?.id } }

    func shortcut(at index: Int) -> SessionWheelShortcut? {
        SessionWheelShortcut(rawValue: index)
    }
}

@Observable
final class SessionWheelMenuMotion {
    private(set) var displayed: SessionWheelMenu?
    let motion = SessionWheelMotion(visible: true)

    /// SwiftUI cancels the previous task when the requested menu changes.
    /// Live session changes update their slots in place; a reversal continues
    /// from the current frame.
    @MainActor
    func update(to menu: SessionWheelMenu, reduceMotion: Bool) async {
        if displayed == nil {
            displayed = menu
            return
        }
        do {
            displayed = menu
            let duration = motion.setVisible(true, reduceMotion: reduceMotion,
                                             at: ProcessInfo.processInfo.systemUptime)
            try await Task.sleep(for: .seconds(duration))
            try Task.checkCancellation()
            motion.finish()
        } catch {
            // The next request owns the same displayed menu and presentation progress.
        }
    }
}

struct SessionWheelAnimatedView<Content: View>: View {
    let motion: SessionWheelMotion
    @ViewBuilder var content: (SessionWheelPresentation) -> Content

    var body: some View {
        TimelineView(.animation(paused: !motion.isAnimating)) { _ in
            content(SessionWheelPresentation(progress: motion.progress(at: ProcessInfo.processInfo.systemUptime),
                                             reduceMotion: motion.reduceMotion))
                .allowsHitTesting(motion.isPresented)
                .accessibilityHidden(!motion.isPresented)
        }
    }
}
