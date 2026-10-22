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
    let showingAllSessions: Bool
    let page: Int
    let sessions: [SessionWheelSession?]
    let projects: [SessionWheelProject]
    let hasMoreProjects: Bool
    let hasMoreSessions: Bool
    let canStartSession: Bool

    init(_ model: SessionWheelModel) {
        pickingProject = model.pickingProject
        showingAllSessions = model.showingAllSessions
        page = model.pageID
        sessions = model.slots
        projects = model.visibleProjects
        hasMoreProjects = model.hasMoreProjects
        hasMoreSessions = model.hasMoreSessions
        canStartSession = model.canStartSession
    }

    var identity: [String?] {
        [String(page)] + (pickingProject ? projects.map(\.id) : sessions.map { $0?.id })
            + [pickingProject && hasMoreProjects ? "more" : nil,
               !pickingProject && !showingAllSessions && hasMoreSessions ? "more-sessions" : nil]
    }

    func shortcut(at index: Int) -> SessionWheelShortcut? {
        pickingProject || showingAllSessions ? nil : SessionWheelShortcut(rawValue: index)
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
            // Only navigation replaces the wheel. Live session changes update their slots in place.
            if displayed?.page != menu.page {
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
