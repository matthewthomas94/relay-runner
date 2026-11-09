import AppKit
import Observation

struct SessionWheelSession: Identifiable, Equatable {
    let id: String
    let name: String
    var unreadCount = 0
    var isFocused = false
}

/// RR-469: one PM tab in the session slot's submenu. An off tab keeps its
/// conversation; clicking it turns it back on and makes it active.
struct SessionWheelTab: Identifiable, Equatable {
    let id: String
    let name: String
    var isActive = false
    var isLive = true
    var unreadCount = 0

    var title: String {
        isActive ? "\(name), active tab" : isLive ? "Make \(name) the active tab" : "Turn \(name) on"
    }

    var caption: String { isActive ? "\(name) active" : isLive ? name : "\(name) off" }

    /// The x inside the tab's segment.
    var closeTitle: String { "Close \(name)" }

    /// The segment's short label: S1, S2 and so on by position.
    static func shortLabel(position: Int) -> String { "S\(position + 1)" }
}

/// RR-469: the tab controls after the tab segments. Each tab closes from the
/// x inside its own segment.
enum SessionWheelTabControl: Int, CaseIterable {
    case add

    var title: String { "Add a PM tab" }

    /// One or two short words: the notch hover descriptor.
    var caption: String { "Add tab" }

    var symbol: LucideIcon { .plus }
}

/// The session submenu's actions. The segments, in arc order, are the tabs
/// then the controls; `close` is the x inside a tab's segment.
enum SessionWheelSessionItem: Equatable {
    case tab(SessionWheelTab)
    case close(SessionWheelTab)
    case control(SessionWheelTabControl)

    var tab: SessionWheelTab? { if case .tab(let tab) = self { return tab } else { return nil } }
    var control: SessionWheelTabControl? { if case .control(let control) = self { return control } else { return nil } }
    var title: String {
        switch self {
        case .tab(let tab): return tab.title
        case .close(let tab): return tab.closeTitle
        case .control(let control): return control.title
        }
    }
}

/// Clockwise from the top session slot: History, Settings, Notetaker, Workspace.
enum SessionWheelShortcut: Int, CaseIterable {
    case workspace = 4, noteTaker = 3, settings = 2, history = 1

    var title: String {
        switch self {
        case .workspace: return "Workspace"
        case .noteTaker: return "Notetaker"
        case .settings: return "Settings"
        case .history: return "History"
        }
    }

    /// The notch hover descriptor: the tab a click opens.
    var hoverAction: String {
        switch self {
        case .workspace: return "Open workspace tab"
        case .noteTaker: return "Open notetaker tab"
        case .settings: return "Open settings tab"
        case .history: return "Open history tab"
        }
    }

    var symbol: LucideIcon {
        switch self {
        case .workspace: return .columns3
        case .noteTaker: return .notebookText
        case .settings: return .settings
        case .history: return .rotateCcwClock
        }
    }
}

/// The one session slot reads Terminal while a session runs.
enum SessionWheelSessionSlot {
    static let title = "Terminal"
    static let symbol: LucideIcon = .squareTerminal
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

    /// The notch hover descriptor: what a click does, three words at most.
    func caption(for phase: MeetingNoteCoordinatorPhase) -> String {
        switch self {
        case .recording: return phase.ownsForeground ? "Save note" : "Start new note"
        case .pause: return phase == .paused ? "Resume note" : "Pause note"
        case .cancel: return "Discard note"
        }
    }

    func symbol(for phase: MeetingNoteCoordinatorPhase) -> LucideIcon {
        switch self {
        case .recording: return phase.ownsForeground ? .check : .mic
        case .pause: return phase == .paused ? .play : .pause
        case .cancel: return .x
        }
    }

    func isEnabled(for phase: MeetingNoteCoordinatorPhase) -> Bool {
        switch self {
        case .recording: return !phase.ownsForeground || phase == .recording || phase == .paused
        case .pause: return phase == .recording || phase == .paused
        case .cancel: return phase == .recording || phase == .paused || phase == .cancelling
        }
    }
}

/// Settings' outer arc: two thirds intensity, then Keep Awake and voice auto-play.
enum SessionWheelSettingsControl: Int, CaseIterable {
    case intensity = 0, keepAwake = 4, autoPlay = 5

    static let subdivisionCount = 6
    init(subdivision: Int) { self = Self(rawValue: subdivision) ?? .intensity }
    var span: Int { self == .intensity ? 4 : 1 }

    /// One or two short words that fit under Settings.
    var caption: String {
        switch self {
        case .intensity: return "Particles"
        case .keepAwake: return "Keep awake"
        case .autoPlay: return "Autoplay"
        }
    }
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
    /// Five segments: the session at the top, then the four shortcuts.
    static let slotCount = 5
    static let sessionSlots = [0]
    static let diameter: CGFloat = 528
    static let hubRadius: CGFloat = 52
    static let wheelRadius: CGFloat = 180
    static let segmentGap: CGFloat = 8
    /// Sector corners are sized to the thin arcs, independent of the button radius.
    static let segmentCornerRadius: CGFloat = 14
    static let actionCornerRadius: CGFloat = 6
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
    /// The session submenu can reach past its own cell (`sessionItems`).
    static func contains(_ point: CGPoint, submenuSlot: Int? = nil, sessionItems: Int = 0) -> Bool {
        let radius = hypot(point.x - center.x, point.y - center.y)
        if radius <= wheelRadius { return true }
        guard radius <= actionOuterRadius + segmentGap, let submenuSlot else { return false }
        if submenuSlot == sessionSlots.first, sessionItems > 0 {
            return abs(sessionArcOffset(at: point)) <= sessionSubmenuSpan(items: sessionItems) * sliceAngle / 2
        }
        return submenuSlot == slot(at: point)
    }

    /// RR-469: the session submenu holds six segments over its own cell, the
    /// standard size for five tabs and Add. More segments
    /// grow it along the arc, evenly on both sides, up to the far ends of
    /// the History and Workspace cells: three cells for nine tabs.
    static let sessionStandardItems = 6
    static let sessionMaxItems = 9 + SessionWheelTabControl.allCases.count

    /// The submenu's width in cells.
    static func sessionSubmenuSpan(items: Int) -> CGFloat {
        guard items > sessionStandardItems else { return 1 }
        let extra = CGFloat(min(items, sessionMaxItems) - sessionStandardItems)
        return min(3, 1 + 2 * extra / CGFloat(sessionMaxItems - sessionStandardItems))
    }

    /// A tab segment's label sits before its centre along the label's axis
    /// and the close x after it, so both stay upright and in reading order.
    static let tabLabelShift: CGFloat = -6
    static let tabCloseShift: CGFloat = 9
    static let tabCloseHitRadius: CGFloat = 8

    /// Where the close x inside tab segment `index` is drawn and hit.
    static func sessionTabClosePoint(_ index: Int, items: Int) -> CGPoint {
        let slot = sessionSlots.first ?? 0
        let arc = sessionItemArc(index, items: items)
        let offset = arc.start + arc.width / 2
        let center = position(slot: slot, radius: actionRadius, offset: offset)
        let rotation = labelRotation(slot: slot, offset: offset)
        return CGPoint(x: center.x + tabCloseShift * cos(rotation), y: center.y + tabCloseShift * sin(rotation))
    }

    /// One segment's start and width, relative to the session cell's centre.
    static func sessionItemArc(_ index: Int, items: Int) -> (start: CGFloat, width: CGFloat) {
        let span = sessionSubmenuSpan(items: items) * sliceAngle
        let width = span / CGFloat(max(items, 1))
        return (-span / 2 + CGFloat(index) * width, width)
    }

    /// The signed angle from the session cell's centre, so the arc never wraps.
    static func sessionArcOffset(at point: CGPoint) -> CGFloat {
        let slot = CGFloat(sessionSlots.first ?? 0)
        let delta = angle(at: point) - (slot * sliceAngle + sliceAngle / 2)
        return atan2(sin(delta), cos(delta))
    }

    /// The session submenu segment under `point`, if any.
    static func sessionItem(at point: CGPoint, items: Int) -> Int? {
        guard items > 0 else { return nil }
        let span = sessionSubmenuSpan(items: items) * sliceAngle
        let offset = sessionArcOffset(at: point) + span / 2
        guard offset >= 0, offset <= span else { return nil }
        return min(items - 1, Int(offset / (span / CGFloat(items))))
    }

    static func position(slot: Int, radius: CGFloat, offset: CGFloat = 0) -> CGPoint {
        let angle = CGFloat(slot) * sliceAngle + offset
        return CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius)
    }

    static func actionOffset(_ index: Int, subdivisions: Int = 3) -> CGFloat {
        ((CGFloat(index) + 0.5) / CGFloat(subdivisions) - 0.5) * sliceAngle
    }

    /// Follow the tangent, reversing the lower half so labels stay upright.
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
    /// RR-445: one entry per `SessionWheelGeometry.sessionSlots` position.
    private var sessions: [SessionWheelSession?] = Array(repeating: nil, count: SessionWheelGeometry.sessionSlots.count)
    var slots: [SessionWheelSession?] {
        var slots = Array<SessionWheelSession?>(repeating: nil, count: SessionWheelGeometry.slotCount)
        for (index, slot) in SessionWheelGeometry.sessionSlots.enumerated() { slots[slot] = sessions[index] }
        return slots
    }
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
    /// RR-469: the PM tabs in the session submenu, in tab-strip order.
    var tabs: [SessionWheelTab] = []
    /// Why Add is unavailable, such as the nine-tab limit; nil when it is.
    var addTabUnavailableReason: String?
    var notice: String?
    private(set) var hoveredSlot: Int?
    private var hoveredControl: Int?
    private var hoveringTabClose = false

    /// The session submenu's segments: one per tab, then the tab controls.
    var sessionItems: [SessionWheelSessionItem] {
        tabs.map { .tab($0) } + SessionWheelTabControl.allCases.map { .control($0) }
    }

    var hoveredSessionItem: SessionWheelSessionItem? {
        guard hoveredSession != nil, let hoveredControl, sessionItems.indices.contains(hoveredControl) else { return nil }
        return sessionItems[hoveredControl]
    }

    /// The tab whose close x is under the pointer.
    var hoveredTabClose: SessionWheelTab? { hoveringTabClose ? hoveredSessionItem?.tab : nil }

    func isEnabled(_ control: SessionWheelTabControl) -> Bool {
        addTabUnavailableReason == nil
    }

    /// Any tab can close; closing the last live tab ends the session.
    func isEnabled(_ item: SessionWheelSessionItem) -> Bool {
        switch item {
        case .tab, .close: return true
        case .control(let control): return isEnabled(control)
        }
    }
    var hoveredNoteAction: SessionWheelNoteAction? {
        isHoveringNoteTaker ? hoveredControl.flatMap(SessionWheelNoteAction.init(rawValue:)) : nil
    }
    var isHoveringNoteTaker: Bool { hoveredSlot == SessionWheelShortcut.noteTaker.rawValue }
    var isHoveringSettings: Bool { hoveredSlot == SessionWheelShortcut.settings.rawValue }
    var hoveredSettingsControl: SessionWheelSettingsControl? {
        isHoveringSettings ? hoveredControl.map(SessionWheelSettingsControl.init(subdivision:)) : nil
    }
    var submenuSlot: Int? { hoveredSession != nil || isHoveringNoteTaker || isHoveringSettings ? hoveredSlot : nil }
    /// Hovering or dragging the enabled slider previews the particle field.
    var isPreviewingIntensity: Bool {
        particleFieldEnabled && (isAdjustingIntensity || hoveredSettingsControl == .intensity)
    }

    func shortcut(at index: Int) -> SessionWheelShortcut? {
        SessionWheelShortcut(rawValue: index)
    }

    /// The notch hover descriptor for the pointer's target, from the same
    /// hover state that drives the submenus. Every control view spans the whole
    /// wheel, so per-view hover would name whichever view is on top instead.
    func hoverDescriptor(at point: CGPoint) -> String? {
        let geometry = SessionWheelGeometry.self
        if hypot(point.x - geometry.center.x, point.y - geometry.center.y) <= geometry.hubRadius {
            return notice ?? "Close session wheel"
        }
        if let tab = hoveredTabClose { return tab.closeTitle }
        if let item = hoveredSessionItem {
            switch item {
            case .tab(let tab), .close(let tab): return tab.caption
            case .control(let control): return addTabUnavailableReason ?? control.caption
            }
        }
        if let action = hoveredNoteAction { return action.caption(for: notePhase) }
        if let control = hoveredSettingsControl {
            switch control {
            case .intensity:
                return particleFieldEnabled ? "Adjust particle intensity" : "Particles turned off"
            case .keepAwake: return keepAwake.hoverAction
            case .autoPlay: return autoPlay ? "Turn off autoplay" : "Turn on autoplay"
            }
        }
        guard let hoveredSlot else { return nil }
        if let shortcut = shortcut(at: hoveredSlot) { return shortcut.hoverAction }
        if slots[hoveredSlot] != nil { return "Open terminal tab" }
        if isStartSlot(hoveredSlot) { return startUnavailableReason ?? "Start new session" }
        return nil
    }

    /// RR-445: with no session running, the first session slot starts the
    /// general session. Other empty session slots stay blank.
    func isStartSlot(_ index: Int) -> Bool {
        index == SessionWheelGeometry.sessionSlots.first && sessions.allSatisfy { $0 == nil }
    }
    private var pointerOrigin: CGPoint = SessionWheelGeometry.center
    private var pointerActivated = false

    var hoveredSession: SessionWheelSession? {
        guard let hoveredSlot else { return nil }
        return slots[hoveredSlot]
    }

    func refresh(sessions: [SessionWheelSession]) {
        let hoveredID = hoveredSession?.id
        // Preserve positions as sessions stop/start, including while a submenu is open.
        for index in self.sessions.indices {
            if let old = self.sessions[index] { self.sessions[index] = sessions.first { $0.id == old.id } }
        }
        for session in sessions where !self.sessions.contains(where: { $0?.id == session.id }) {
            if let empty = self.sessions.firstIndex(where: { $0 == nil }) { self.sessions[empty] = session }
        }
        if hoveredID != hoveredSession?.id { clearHover() }
        if submenuSlot == nil { hoveredControl = nil; hoveringTabClose = false }
    }

    func reset(at pointer: CGPoint) {
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
        hoveringTabClose = false
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
        hoveringTabClose = false
        if distance <= geometry.hubRadius || distance > geometry.actionOuterRadius + 8 {
            hoveredSlot = nil
        } else if distance <= geometry.wheelRadius {
            hoveredSlot = geometry.slot(at: pointer)
        } else if hoveredSession != nil,
                  distance >= geometry.actionInnerRadius, distance <= geometry.actionOuterRadius {
            // RR-469: the session submenu may reach over History and Workspace.
            hoveredControl = geometry.sessionItem(at: pointer, items: sessionItems.count)
            if let index = hoveredControl, sessionItems.indices.contains(index), sessionItems[index].tab != nil {
                let close = geometry.sessionTabClosePoint(index, items: sessionItems.count)
                hoveringTabClose = hypot(pointer.x - close.x, pointer.y - close.y) <= geometry.tabCloseHitRadius
            }
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
