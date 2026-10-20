import Observation
import SwiftUI

/// One reversible timeline: tile convergence, then disc collapse and hub exit.
struct SessionWheelPresentation: Equatable {
    static let segmentDuration: TimeInterval = 0.1
    static let discDuration: TimeInterval = 0.1
    static let duration = segmentDuration + discDuration
    static let blurDuration: TimeInterval = min(0.3, duration)
    static let reducedDuration: TimeInterval = 0.12

    // Tile translations toward the centre, retaining each tile's size.
    private static let convergedOffsets: [CGSize] = [
        .init(width: 0, height: 20.1), .init(width: -13.4, height: 13.4),
        .init(width: -14.74, height: -9.38), .init(width: 0, height: -19.43),
        .init(width: 13.4, height: -13.4), .init(width: 13.4, height: 13.4),
    ]

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

    func segmentOffset(_ index: Int) -> CGSize {
        let offset = Self.convergedOffsets[index]
        return CGSize(width: offset.width * segmentConvergence,
                      height: offset.height * segmentConvergence)
    }
}

/// Use the wheel's complete tile transform, including its final collapse to the centre.
struct SessionWheelContentEffect: AnimatableModifier {
    var progress: Double
    let slot: Int
    let reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let frame = SessionWheelPresentation(progress: progress, reduceMotion: reduceMotion)
        content
            .compositingGroup()
            .blur(radius: frame.segmentBlur)
            .offset(frame.segmentOffset(slot))
            .scaleEffect(frame.discScale)
            .opacity(frame.opacity * frame.segmentVisibility)
            .allowsHitTesting(progress >= 1)
            .accessibilityHidden(progress < 1)
    }
}

extension AnyTransition {
    static func sessionWheel(slot: Int, reduceMotion: Bool, replacing: Bool = false) -> AnyTransition {
        let effect = AnyTransition.modifier(
            active: SessionWheelContentEffect(progress: 0, slot: slot, reduceMotion: reduceMotion),
            identity: SessionWheelContentEffect(progress: 1, slot: slot, reduceMotion: reduceMotion))
        let animation = SessionWheelPresentation.animation(reduceMotion: reduceMotion)
        // Exchange pages at the collapsed frame, never overlay two expanding/converging menus.
        return .asymmetric(
            insertion: effect.animation(animation.delay(
                replacing && !reduceMotion ? SessionWheelPresentation.duration : 0)),
            removal: effect.animation(animation))
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

/// Freeze the outgoing menu until it has contracted completely.
struct SessionWheelMenu: Equatable {
    let pickingProject: Bool
    let page: Int
    let sessions: [SessionWheelSession?]
    let projects: [SessionWheelProject]
    let hasMoreProjects: Bool
    let canStartSession: Bool

    init(_ model: SessionWheelModel) {
        pickingProject = model.pickingProject
        page = model.pickingProject ? model.projectPage : -1
        sessions = model.slots
        projects = model.visibleProjects
        hasMoreProjects = model.hasMoreProjects
        canStartSession = model.canStartSession
    }

    var identity: [String?] {
        [String(page)] + (pickingProject ? projects.map(\.id) : sessions.map { $0?.id })
            + [pickingProject && hasMoreProjects ? "more" : nil]
    }
}

@Observable
final class SessionWheelMenuMotion {
    private(set) var displayed: SessionWheelMenu?
    let motion = SessionWheelMotion(visible: true)

    /// SwiftUI cancels the previous task when the requested menu changes.
    /// A reversal continues from the current frame, without leaving old pages behind.
    @MainActor
    func update(to menu: SessionWheelMenu, reduceMotion: Bool) async {
        if displayed == nil {
            displayed = menu
            return
        }
        do {
            if displayed?.identity != menu.identity {
                let duration = motion.setVisible(false, reduceMotion: reduceMotion,
                                                 at: ProcessInfo.processInfo.systemUptime)
                try await Task.sleep(for: .seconds(duration))
                try Task.checkCancellation()
            }
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
