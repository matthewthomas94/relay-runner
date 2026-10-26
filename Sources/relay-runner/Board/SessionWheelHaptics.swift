import AppKit
import SwiftUI

/// Feedback follows pointer events and accepted actions, never a model refresh.
final class SessionWheelHaptics {
    enum Target: Equatable {
        case center
        case slot(Int)
        case action(slot: Int, index: Int)
    }

    var isEnabled: () -> Bool = { true }
    private let now: () -> TimeInterval
    private let perform: (NSHapticFeedbackManager.FeedbackPattern) -> Void
    private var pointerOrigin: CGPoint?
    private var lastPoint: CGPoint?
    private var lastTarget: Target?
    private var lastFeedbackTime: TimeInterval?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         perform: @escaping (NSHapticFeedbackManager.FeedbackPattern) -> Void = {
             // Resolve the current device each time; macOS respects its haptic preferences.
             NSHapticFeedbackManager.defaultPerformer.perform($0, performanceTime: .now)
         }) {
        self.now = now
        self.perform = perform
    }

    func reset(at point: CGPoint) {
        pointerOrigin = point
        lastPoint = point
        lastTarget = nil
        lastFeedbackTime = nil
    }

    func hover(_ target: Target?, at point: CGPoint?) {
        guard let point else {
            lastPoint = nil
            lastTarget = nil
            return
        }
        guard point != lastPoint else { return }
        lastPoint = point
        if let origin = pointerOrigin {
            // Opening under the pointer is not navigation.
            guard hypot(point.x - origin.x, point.y - origin.y) >= 8 else { return }
            pointerOrigin = nil
        }
        guard target != lastTarget else { return }
        lastTarget = target
        guard target != nil, isEnabled() else { return }
        let time = now()
        guard lastFeedbackTime.map({ time - $0 >= 0.08 }) ?? true else { return }
        lastFeedbackTime = time
        perform(.generic)
    }

    func activate() {
        guard isEnabled() else { return }
        lastFeedbackTime = now()
        perform(.generic)
    }

    static func target(at point: CGPoint, model: SessionWheelModel) -> Target? {
        let geometry = SessionWheelGeometry.self
        if hypot(point.x - geometry.center.x, point.y - geometry.center.y) <= geometry.hubRadius {
            return .center
        }
        guard let slot = model.hoveredSlot else { return nil }
        let bounds = CGRect(origin: .zero, size: CGSize(width: geometry.diameter, height: geometry.diameter))
        if let control = model.hoveredSettingsControl {
            // The whole slider is one target, so crossing its subdivisions stays silent.
            let enabled = control == .intensity ? model.particleFieldEnabled : !model.keepAwake.isPending
            let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                           outerRadius: geometry.actionOuterRadius,
                                           subdivision: control.rawValue, span: control.span)
            return enabled && shape.path(in: bounds).contains(point) ? .action(slot: slot, index: control.rawValue) : nil
        }
        if let index = model.hoveredAction?.rawValue ?? model.hoveredNoteAction?.rawValue {
            let enabled = model.hoveredAction.flatMap { action in
                model.hoveredSession.map { action.isEnabled(for: $0) }
            }
                ?? (model.hoveredNoteAction?.isEnabled(for: model.notePhase) == true)
            let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                           outerRadius: geometry.actionOuterRadius, subdivision: index)
            return enabled && shape.path(in: bounds).contains(point) ? .action(slot: slot, index: index) : nil
        }
        let enabled: Bool
        if model.pickingProject {
            enabled = model.isMoreProjectsSlot(slot) || (model.canStartSession
                && model.visibleProjects.indices.contains(slot) && model.visibleProjects[slot].isAvailable)
        } else {
            enabled = !model.showingAllSessions || model.slots[slot] != nil
        }
        let shape = SessionWheelSector(slot: slot, innerRadius: geometry.segmentInnerRadius,
                                       outerRadius: geometry.segmentOuterRadius)
        return enabled && shape.path(in: bounds).contains(point) ? .slot(slot) : nil
    }
}
