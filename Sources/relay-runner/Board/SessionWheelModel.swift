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

enum SessionWheelShortcut: Int, CaseIterable {
    case workspace = 4, noteTaker = 3, settings = 2

    var title: String {
        switch self {
        case .workspace: return "Workspace"
        case .noteTaker: return "Notetaker"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: return "rectangle.split.3x1"
        case .noteTaker: return "note.text"
        case .settings: return "gearshape"
        }
    }
}

enum SessionWheelNoteAction: Int, CaseIterable {
    // The bottom arc reads left to right, opposite the top session arc.
    case pause = 2, recording = 1, cancel = 0

    func title(for phase: MeetingNoteCoordinatorPhase) -> String {
        switch self {
        case .recording: return phase.ownsForeground ? "Save note" : "Start Notetaker"
        case .pause: return phase == .paused ? "Resume Notetaker" : "Pause Notetaker"
        case .cancel: return "Cancel Notetaker"
        }
    }

    func symbol(for phase: MeetingNoteCoordinatorPhase) -> String {
        switch self {
        case .recording: return phase.ownsForeground ? "checkmark" : "mic.fill"
        case .pause: return phase == .paused ? "play.fill" : "pause.fill"
        case .cancel: return "xmark"
        }
    }

    func isEnabled(for phase: MeetingNoteCoordinatorPhase) -> Bool {
        switch self {
        case .recording: return !phase.ownsForeground || phase == .recording || phase == .paused
        case .pause: return phase == .recording || phase == .paused
        case .cancel: return phase == .recording || phase == .paused || phase == .cancelling
        }
    }

    func help(for phase: MeetingNoteCoordinatorPhase) -> String {
        switch self {
        case .recording where phase.ownsForeground: return "Stop, save and transcribe this note"
        case .cancel: return "Discard this note and its recording without saving or transcribing"
        default: return title(for: phase)
        }
    }
}

/// Settings' outer arc: two thirds intensity, then Keep Awake and voice auto-play.
enum SessionWheelSettingsControl: Int, CaseIterable {
    case intensity = 0, keepAwake = 4, autoPlay = 5

    static let subdivisionCount = 6
    init(subdivision: Int) { self = Self(rawValue: subdivision) ?? .intensity }
    var span: Int { self == .intensity ? 4 : 1 }
}

/// Maps the curved slider to `awareness.glow_intensity`. Angles use `SessionWheelGeometry.angle(at:)`:
/// the slider's high end is nearest the sessions and its low end meets Keep Awake.
enum SessionWheelIntensity {
    static let range: ClosedRange<Double> = 0.1...1.0
    static let step = 0.05
    static let slot = SessionWheelShortcut.settings.rawValue
    /// Keep the thumb clear of the rounded ends.
    static let inset = (SessionWheelGeometry.segmentGap / 2 + 3) / SessionWheelGeometry.actionRadius
    static var maxAngle: CGFloat { CGFloat(slot) * SessionWheelGeometry.sliceAngle + inset }
    static var minAngle: CGFloat { CGFloat(slot) * SessionWheelGeometry.sliceAngle + SessionWheelGeometry.sliceAngle * 2 / 3 - inset }

    static func quantized(_ value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return ((clamped / step).rounded() * step * 100).rounded() / 100
    }

    static func clamped(angle: CGFloat) -> CGFloat {
        min(max(angle, maxAngle), minAngle)
    }

    static func value(forAngle angle: CGFloat) -> Double {
        let fraction = Double((minAngle - clamped(angle: angle)) / (minAngle - maxAngle))
        return quantized(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
    }

    static func angle(for value: Double) -> CGFloat {
        let fraction = CGFloat((quantized(value) - range.lowerBound) / (range.upperBound - range.lowerBound))
        return minAngle - (minAngle - maxAngle) * fraction
    }

    /// The signed difference from the slider's middle, so a point never wraps to the far end.
    static func unwrappedAngle(at point: CGPoint) -> CGFloat {
        let middle = (minAngle + maxAngle) / 2
        return middle + shortestTurn(from: middle, to: SessionWheelGeometry.angle(at: point))
    }

    static func shortestTurn(from start: CGFloat, to end: CGFloat) -> CGFloat {
        atan2(sin(end - start), cos(end - start))
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

enum SessionWheelGeometry {
    static let slotCount = 6
    static let sessionSlots = [0, 1, 5]
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

    /// Include the black gaps and submenu padding in the wheel's click area.
    static func contains(_ point: CGPoint, submenuSlot: Int? = nil) -> Bool {
        let radius = hypot(point.x - center.x, point.y - center.y)
        if radius <= wheelRadius { return true }
        return submenuSlot == slot(at: point) && radius <= actionOuterRadius + segmentGap
    }

    static func position(slot: Int, radius: CGFloat, offset: CGFloat = 0) -> CGPoint {
        let angle = CGFloat(slot) * sliceAngle + offset
        return CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius)
    }

    static func actionOffset(_ action: SessionWheelAction) -> CGFloat {
        actionOffset(action.rawValue)
    }

    static func actionOffset(_ index: Int, subdivisions: Int = 3) -> CGFloat {
        ((CGFloat(index) + 0.5) / CGFloat(subdivisions) - 0.5) * sliceAngle
    }

    /// Follow the tangent, reversing the lower half so labels stay upright.
    static func actionLabelRotation(slot: Int, action: SessionWheelAction) -> CGFloat {
        actionLabelRotation(slot: slot, index: action.rawValue)
    }

    static func actionLabelRotation(slot: Int, index: Int) -> CGFloat {
        labelRotation(slot: slot, offset: actionOffset(index))
    }

    static func labelRotation(slot: Int, offset: CGFloat) -> CGFloat {
        let angle = CGFloat(slot) * sliceAngle + offset
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
    private var sessions: [SessionWheelSession?] = Array(repeating: nil, count: SessionWheelGeometry.slotCount)
    private var projectSlot: Int?
    private var pendingSessionPlacement: (id: String, index: Int)?
    var slots: [SessionWheelSession?] {
        if showingAllSessions { return sessions }
        var slots = Array<SessionWheelSession?>(repeating: nil, count: SessionWheelGeometry.slotCount)
        for (index, slot) in SessionWheelGeometry.sessionSlots.enumerated() {
            if !isMoreSessionsSlot(slot) { slots[slot] = sessions[index] }
        }
        return slots
    }
    var projects: [SessionWheelProject] = []
    var notePhase: MeetingNoteCoordinatorPhase = .idle
    var particleIntensity = 0.6
    var particleFieldEnabled = true
    var keepAwake: KeepAwakeState = .off
    var autoPlay = false
    var autoPlayActionTitle: String { autoPlay ? "Turn off voice auto-play" : "Turn on voice auto-play" }
    /// A slider drag pins hover so the submenu stays open wherever the pointer travels.
    private(set) var isAdjustingIntensity = false
    private var intensityDragAngle: (raw: CGFloat, unwrapped: CGFloat) = (0, 0)
    var startUnavailableReason: String?
    var canStartSession: Bool { startUnavailableReason == nil }
    var notice: String?
    private(set) var pickingProject = false
    private(set) var showingAllSessions = false
    private(set) var projectPage = 0
    private(set) var hoveredSlot: Int?
    private var hoveredControl: Int?
    var hoveredAction: SessionWheelAction? {
        hoveredSession == nil ? nil : hoveredControl.flatMap(SessionWheelAction.init(rawValue:))
    }
    var hoveredNoteAction: SessionWheelNoteAction? {
        isHoveringNoteTaker ? hoveredControl.flatMap(SessionWheelNoteAction.init(rawValue:)) : nil
    }
    var isNested: Bool { pickingProject || showingAllSessions }
    var pageID: Int { pickingProject ? projectPage : showingAllSessions ? -2 : -1 }
    var hasMoreSessions: Bool { sessions.dropFirst(3).contains { $0 != nil } }
    var isHoveringNoteTaker: Bool { !isNested && hoveredSlot == SessionWheelShortcut.noteTaker.rawValue }
    var isHoveringSettings: Bool { !isNested && hoveredSlot == SessionWheelShortcut.settings.rawValue }
    var hoveredSettingsControl: SessionWheelSettingsControl? {
        isHoveringSettings ? hoveredControl.map(SessionWheelSettingsControl.init(subdivision:)) : nil
    }
    var submenuSlot: Int? { hoveredSession != nil || isHoveringNoteTaker || isHoveringSettings ? hoveredSlot : nil }
    /// Hovering or dragging the enabled slider previews the particle field.
    var isPreviewingIntensity: Bool {
        particleFieldEnabled && (isAdjustingIntensity || hoveredSettingsControl == .intensity)
    }

    func shortcut(at index: Int) -> SessionWheelShortcut? {
        isNested ? nil : SessionWheelShortcut(rawValue: index)
    }

    func isMoreSessionsSlot(_ index: Int) -> Bool {
        !isNested && hasMoreSessions && index == SessionWheelGeometry.sessionSlots.last
    }
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
        for index in self.sessions.indices {
            if let old = self.sessions[index] { self.sessions[index] = sessions.first { $0.id == old.id } }
        }
        // Startup is asynchronous: match the requested context before filling other empty slots.
        if let pending = pendingSessionPlacement, let session = sessions.first(where: { $0.id == pending.id }) {
            if self.sessions[pending.index] == nil,
               !self.sessions.contains(where: { $0?.id == session.id }) {
                self.sessions[pending.index] = session
            }
            pendingSessionPlacement = nil
        }
        // Bring overflow back into a free top slot when another session ends.
        for index in 3..<self.sessions.count where self.sessions[index] != nil {
            if let empty = self.sessions.prefix(3).firstIndex(where: { $0 == nil }) {
                self.sessions[empty] = self.sessions[index]
                self.sessions[index] = nil
            }
        }
        for session in sessions where !self.sessions.contains(where: { $0?.id == session.id }) {
            if let empty = self.sessions.firstIndex(where: { $0 == nil }) { self.sessions[empty] = session }
        }
        if hoveredID != hoveredSession?.id { clearHover() }
        if submenuSlot == nil { hoveredControl = nil }
        projectPage = min(projectPage, pageCount - 1)
    }

    func reset(at pointer: CGPoint) {
        pickingProject = false
        showingAllSessions = false
        projectSlot = nil
        projectPage = 0
        notice = nil
        rearmPointer(at: pointer)
    }

    func showProjects(from slot: Int? = nil, at pointer: CGPoint) {
        projectSlot = slot.flatMap { SessionWheelGeometry.sessionSlots.firstIndex(of: $0) }
        pickingProject = true
        showingAllSessions = false
        projectPage = 0
        notice = nil
        rearmPointer(at: pointer)
    }

    func didStartProject(_ project: SessionWheelProject) {
        guard let projectSlot, sessions[projectSlot] == nil else { return }
        let context = AssistantSessionContext(kind: .project, projectID: project.id, repositoryPath: project.path)
        pendingSessionPlacement = (context.id, projectSlot)
    }

    func showAllSessions(at pointer: CGPoint) {
        showingAllSessions = true
        pickingProject = false
        notice = nil
        rearmPointer(at: pointer)
    }

    /// Returns true when Back consumed a project submenu.
    func back(at pointer: CGPoint) -> Bool {
        if showingAllSessions {
            reset(at: pointer)
            return true
        }
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
        hoveredControl = nil
    }

    func hover(at pointer: CGPoint) {
        guard !isAdjustingIntensity else { return }
        if !pointerActivated {
            guard hypot(pointer.x - pointerOrigin.x, pointer.y - pointerOrigin.y) >= 8 else { return }
            pointerActivated = true
        }
        let geometry = SessionWheelGeometry.self
        let distance = hypot(pointer.x - geometry.center.x, pointer.y - geometry.center.y)
        hoveredControl = nil
        if distance <= geometry.hubRadius || distance > geometry.actionOuterRadius + 8 {
            hoveredSlot = nil
        } else if distance <= geometry.wheelRadius {
            hoveredSlot = geometry.slot(at: pointer)
        } else if submenuSlot != nil,
                  geometry.slot(at: pointer) == hoveredSlot,
                  distance >= geometry.actionInnerRadius, distance <= geometry.actionOuterRadius {
            let localAngle = geometry.angle(at: pointer).truncatingRemainder(dividingBy: geometry.sliceAngle)
            let subdivisions = isHoveringSettings ? SessionWheelSettingsControl.subdivisionCount : 3
            hoveredControl = min(subdivisions - 1, Int(localAngle / (geometry.sliceAngle / CGFloat(subdivisions))))
        }
        // The radial gap retains its parent, so travelling into the submenu is continuous.
    }

    /// Follows the pointer's angular travel from the previous drag point and clamps it,
    /// so passing an end or circling the wheel never wraps to the other end.
    @discardableResult
    func adjustIntensity(to pointer: CGPoint) -> Double {
        let raw = SessionWheelGeometry.angle(at: pointer)
        let unwrapped = isAdjustingIntensity
            ? intensityDragAngle.unwrapped + SessionWheelIntensity.shortestTurn(from: intensityDragAngle.raw, to: raw)
            : SessionWheelIntensity.unwrappedAngle(at: pointer)
        isAdjustingIntensity = true
        intensityDragAngle = (raw, SessionWheelIntensity.clamped(angle: unwrapped))
        particleIntensity = SessionWheelIntensity.value(forAngle: intensityDragAngle.unwrapped)
        return particleIntensity
    }

    func endAdjustingIntensity() {
        isAdjustingIntensity = false
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
