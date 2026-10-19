import AppKit
import Observation

struct SessionWheelSession: Identifiable, Equatable {
    let id: String
    let name: String
    var unreadCount = 0
    var isFocused = false
    var isRecording = false
    var canRecord = true
    var canPlay = true
    var playback: SessionVoicePlayback = .replay
}

struct SessionWheelProject: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    var isAvailable = true
}

enum SessionWheelAction: Int, CaseIterable {
    case message, recording, stop

    func title(for session: SessionWheelSession) -> String {
        switch self {
        case .message:
            switch session.playback {
            case .play: return "Play message"
            case .stop: return "Stop playback"
            case .replay: return "Replay message"
            }
        case .recording: return session.isRecording ? "Stop recording and send message" : "Record"
        case .stop: return "Stop session"
        }
    }

    func symbol(for session: SessionWheelSession) -> String {
        switch self {
        case .message:
            switch session.playback {
            case .play: return "play.fill"
            case .stop: return "stop.fill"
            case .replay: return "play.fill"
            }
        case .recording: return session.isRecording ? "waveform" : "mic.fill"
        case .stop: return "power"
        }
    }

    func isEnabled(for session: SessionWheelSession) -> Bool {
        switch self {
        case .message: return session.canPlay
        case .recording: return session.canRecord
        case .stop: return true
        }
    }
}

enum SessionWheelGeometry {
    static let slotCount = 6
    static let diameter: CGFloat = 528
    static let hubRadius: CGFloat = 52
    static let wheelRadius: CGFloat = 180
    static let segmentGap: CGFloat = 8
    static let segmentInnerRadius = hubRadius + segmentGap
    static let segmentOuterRadius = wheelRadius - segmentGap
    // Leave a gap outside the wheel, then padding inside the detached backing.
    static let actionInnerRadius = wheelRadius + segmentGap * 2
    static let actionOuterRadius = actionInnerRadius + 34
    static let actionRadius = (actionInnerRadius + actionOuterRadius) / 2
    static let actionLabelSize = CGSize(width: 52, height: 21)
    static let center = CGPoint(x: diameter / 2, y: diameter / 2)
    static let sliceAngle = 2 * CGFloat.pi / CGFloat(slotCount)

    static func angle(at point: CGPoint) -> CGFloat {
        let radians = atan2(point.x - center.x, center.y - point.y) + sliceAngle / 2
        return (radians + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
    }

    static func slot(at point: CGPoint) -> Int {
        min(slotCount - 1, Int(angle(at: point) / sliceAngle))
    }

    static func position(slot: Int, radius: CGFloat, offset: CGFloat = 0) -> CGPoint {
        let angle = CGFloat(slot) * sliceAngle + offset
        return CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius)
    }

    static func actionOffset(_ action: SessionWheelAction) -> CGFloat {
        CGFloat(action.rawValue - 1) * sliceAngle / 3
    }

    /// Follow the tangent, reversing the lower half so labels stay upright.
    static func actionLabelRotation(slot: Int, action: SessionWheelAction) -> CGFloat {
        let angle = CGFloat(slot) * sliceAngle + actionOffset(action)
        return atan2(sin(2 * angle), cos(2 * angle)) / 2
    }

    /// Reserve the outer controls too; near an edge the entire menu stays reachable.
    static func frame(at cursor: CGPoint, visibleFrame: CGRect) -> CGRect {
        let size = min(diameter, visibleFrame.width, visibleFrame.height)
        return CGRect(x: min(max(cursor.x - size / 2, visibleFrame.minX), visibleFrame.maxX - size),
                      y: min(max(cursor.y - size / 2, visibleFrame.minY), visibleFrame.maxY - size),
                      width: size, height: size)
    }
}

@Observable
final class SessionWheelModel {
    private(set) var slots: [SessionWheelSession?] = Array(repeating: nil, count: SessionWheelGeometry.slotCount)
    var projects: [SessionWheelProject] = []
    var isWorkspaceVisible = false
    var workspaceActionTitle: String { isWorkspaceVisible ? "Close workspace" : "Open workspace" }
    var startUnavailableReason: String?
    var canStartSession: Bool { startUnavailableReason == nil }
    var notice: String?
    private(set) var pickingProject = false
    private(set) var projectPage = 0
    private(set) var hoveredSlot: Int?
    private(set) var hoveredAction: SessionWheelAction?
    private var pointerOrigin: CGPoint = SessionWheelGeometry.center
    private var pointerActivated = false

    private var projectsPerPage: Int { SessionWheelGeometry.slotCount - 1 }
    var pageCount: Int { max(1, (projects.count + projectsPerPage - 2) / projectsPerPage) }
    var hasMoreProjects: Bool { projectPage < pageCount - 1 }
    func isMoreProjectsSlot(_ index: Int) -> Bool {
        pickingProject && hasMoreProjects && index == SessionWheelGeometry.slotCount - 1
    }
    var visibleProjects: [SessionWheelProject] {
        Array(projects.dropFirst(projectPage * projectsPerPage)
            .prefix(hasMoreProjects ? projectsPerPage : SessionWheelGeometry.slotCount))
    }
    var hoveredSession: SessionWheelSession? {
        guard !pickingProject, let hoveredSlot else { return nil }
        return slots[hoveredSlot]
    }

    func refresh(sessions: [SessionWheelSession]) {
        let hoveredID = hoveredSession?.id
        // Preserve positions as sessions stop/start, including while a submenu is open.
        for index in slots.indices {
            if let old = slots[index] { slots[index] = sessions.first { $0.id == old.id } }
        }
        for session in sessions where !slots.contains(where: { $0?.id == session.id }) {
            if let empty = slots.firstIndex(where: { $0 == nil }) { slots[empty] = session }
        }
        if hoveredID != hoveredSession?.id { clearHover() }
        if hoveredSession == nil { hoveredAction = nil }
        projectPage = min(projectPage, pageCount - 1)
    }

    func reset(at pointer: CGPoint) {
        pickingProject = false
        projectPage = 0
        notice = nil
        rearmPointer(at: pointer)
    }

    func showProjects(at pointer: CGPoint) {
        pickingProject = true
        projectPage = 0
        notice = nil
        rearmPointer(at: pointer)
    }

    /// Returns true when Back consumed a project submenu; otherwise dismiss.
    func back(at pointer: CGPoint) -> Bool {
        guard pickingProject else { return false }
        if projectPage > 0 { turnPage(-1, at: pointer) }
        else { reset(at: pointer) }
        return true
    }

    func turnPage(_ direction: Int, at pointer: CGPoint) {
        projectPage = min(max(0, projectPage + direction), pageCount - 1)
        notice = nil
        rearmPointer(at: pointer)
    }

    private func rearmPointer(at pointer: CGPoint) {
        pointerOrigin = pointer
        pointerActivated = false
        clearHover()
    }

    func clearHover() {
        hoveredSlot = nil
        hoveredAction = nil
    }

    func hover(at pointer: CGPoint) {
        if !pointerActivated {
            guard hypot(pointer.x - pointerOrigin.x, pointer.y - pointerOrigin.y) >= 8 else { return }
            pointerActivated = true
        }
        let geometry = SessionWheelGeometry.self
        let distance = hypot(pointer.x - geometry.center.x, pointer.y - geometry.center.y)
        hoveredAction = nil
        if distance <= geometry.hubRadius || distance > geometry.actionOuterRadius + 8 {
            hoveredSlot = nil
        } else if distance <= geometry.wheelRadius {
            hoveredSlot = geometry.slot(at: pointer)
        } else if !pickingProject, hoveredSession != nil,
                  geometry.slot(at: pointer) == hoveredSlot,
                  distance >= geometry.actionInnerRadius, distance <= geometry.actionOuterRadius {
            let localAngle = geometry.angle(at: pointer).truncatingRemainder(dividingBy: geometry.sliceAngle)
            hoveredAction = SessionWheelAction(rawValue: min(2, Int(localAngle / (geometry.sliceAngle / 3))))
        }
        // The radial gap retains its parent, so travelling into the submenu is continuous.
    }
}

/// Recording is shared, but its target is pinned at capture start. Never stop
/// another session's recording or change its destination from a wheel action.
enum SessionWheelRecording {
    static func canToggle(targetKey: String?, recording: Bool, recordingKey: String?, ready: Bool) -> Bool {
        guard let targetKey, ready else { return false }
        return !recording || targetKey == recordingKey
    }
}
