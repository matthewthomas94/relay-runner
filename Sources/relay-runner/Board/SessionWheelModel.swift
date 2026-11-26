import AppKit
import Observation

struct SessionWheelSession: Identifiable, Equatable {
    let id: String
    let name: String
    var isFocused = false
}

/// RR-521: what a click in the session submenu asks for. Each title is
/// also the notch hover descriptor and the VoiceOver action's name.
enum SessionWheelAgentAction: Equatable {
    case start(SessionAgent)
    case switchTo(SessionAgent)
    case stop(SessionAgent)

    var agent: SessionAgent {
        switch self {
        case .start(let agent), .switchTo(let agent), .stop(let agent): return agent
        }
    }

    var title: String {
        switch self {
        case .start(let agent): return "Start \(agent.name)"
        case .switchTo(let agent): return "Switch to \(agent.name)"
        case .stop(let agent): return "Stop \(agent.name)"
        }
    }

    /// The hub's notice when the app refuses the action.
    var failureNotice: String {
        switch self {
        case .start(let agent): return "Couldn't start \(agent.name)"
        case .switchTo: return "Couldn't switch agents"
        case .stop(let agent): return "Couldn't stop \(agent.name)"
        }
    }
}

/// RR-521: one of the four agents' segments in the session slot's submenu,
/// there whether or not it runs. It shows the agent's full name and a
/// glyph: a plus while the agent is stopped, an X while it runs.
struct SessionWheelAgent: Identifiable, Equatable {
    let agent: SessionAgent
    var isRunning = false
    /// The running agent voice turns, replies and TTS go to.
    var isActive = false
    /// It finished a turn or asked for attention while another agent was active.
    var needsAttention = false

    var id: String { agent.slug }
    var name: String { agent.name }
    var label: String { agent.name }

    /// The label starts a stopped agent and switches to a running one.
    var labelAction: SessionWheelAgentAction { isRunning ? .switchTo(agent) : .start(agent) }
    /// The plus starts a stopped agent; the X stops a running one.
    var glyphAction: SessionWheelAgentAction { isRunning ? .stop(agent) : .start(agent) }
    var glyph: LucideIcon { isRunning ? .x : .plus }
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

/// RR-521: the one session slot always reads Terminal and opens Workspace on
/// the Terminal tab; agents start and stop from its submenu.
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
    static func contains(_ point: CGPoint, submenuSlot: Int? = nil) -> Bool {
        let radius = hypot(point.x - center.x, point.y - center.y)
        if radius <= wheelRadius { return true }
        guard radius <= actionOuterRadius + segmentGap, let submenuSlot else { return false }
        if submenuSlot == sessionSlots.first { return isInSessionSubmenuArc(point) }
        return submenuSlot == slot(at: point)
    }

    /// The open submenu a point outside the wheel belongs to: the session
    /// submenu over its whole arc, which reaches past its own cell, else the
    /// cell's own submenu.
    static func submenuSlot(at point: CGPoint, isOpen: (Int) -> Bool) -> Int? {
        if let session = sessionSlots.first, isOpen(session), isInSessionSubmenuArc(point) { return session }
        let slot = slot(at: point)
        return isOpen(slot) ? slot : nil
    }

    static func isInSessionSubmenuArc(_ point: CGPoint) -> Bool {
        abs(sessionArcOffset(at: point)) <= sessionSubmenuArc / 2
    }

    /// RR-521: the session submenu holds one segment per agent, all four
    /// always, each labelled with the agent's full name.
    static let sessionItemCount = SessionAgent.allCases.count

    /// The session submenu's whole arc. Every segment is as wide as the
    /// longest name needs, so the arc reaches past the session's own cell
    /// over History and Workspace; it is never narrower than the cell.
    static let sessionSubmenuArc: CGFloat = {
        let longest = SessionAgent.allCases.map { trackedLetters($0.name).width }.max() ?? 0
        let segment = longest + agentGlyphDiameter + 3 * agentContentPadding + segmentGap
        return max(sliceAngle, CGFloat(sessionItemCount) * segment / actionRadius)
    }()

    /// An agent segment spaces its label and glyph like `space-between`: the
    /// label starts `agentContentPadding` inside the segment's leading edge
    /// and the glyph's circle ends that far inside its trailing edge, in
    /// reading order. A segment too narrow for both shrinks the padding.
    static let agentContentPadding: CGFloat = 10
    /// The plus or X's hover circle, which is also where the glyph is hit.
    static let agentGlyphDiameter: CGFloat = 20
    static var agentGlyphHitRadius: CGFloat { agentGlyphDiameter / 2 }

    /// Extra space between an agent label's letters.
    static let agentLabelTracking: CGFloat = 1
    /// How far an agent label turns clockwise about its middle. The label starts
    /// near the segment's leading end, where the arc is steeper, so without
    /// this it reads as leaning anticlockwise of the cell.
    static let agentLabelTilt: CGFloat = 1 * .pi / 180

    /// One letter of an agent label set on the arc: its outline, already in
    /// place, and the point on the arc its middle sits on.
    struct Glyph: Equatable {
        let outline: CGPath
        let point: CGPoint
        let rotation: CGFloat
    }

    /// A label's letters on a straight, tracked baseline in the wheel's
    /// semibold caption-size font: each one's outline (y up, from its
    /// origin), advance and origin along the baseline, the label's width,
    /// and the cap height.
    static func trackedLetters(_ text: String)
        -> (letters: [(outline: CGPath, x: CGFloat, advance: CGFloat)], width: CGFloat, capHeight: CGFloat) {
        let font = AppTypography.appKitFont(.status) as CTFont
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .kern: agentLabelTracking, .ligature: 0,
        ]))
        var letters: [(outline: CGPath, x: CGFloat, advance: CGFloat)] = []
        var width: CGFloat = 0
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName].map { $0 as! CTFont } ?? font
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTFontGetAdvancesForGlyphs(runFont, .horizontal, glyphs, &advances, count)
            for index in 0..<count {
                let outline = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) ?? CGMutablePath()
                letters.append((outline, positions[index].x, advances[index].width))
                // The width ends at the last letter, without its trailing tracking.
                width = max(width, positions[index].x + advances[index].width)
            }
        }
        return (letters, width, CTFontGetCapHeight(font))
    }

    /// Where agent segment `index` draws its label and glyph. Each sits on
    /// the arc at its own angle and turns with the segment, so the two read
    /// the same way. The label curves with the cell: `glyphs` sets each
    /// letter's outline on the arc, and `label` is the label's middle.
    static func sessionAgentLayout(_ index: Int, label: String)
        -> (label: (point: CGPoint, rotation: CGFloat), glyphs: [Glyph], glyph: (point: CGPoint, rotation: CGFloat)) {
        let slot = sessionSlots.first ?? 0
        let arc = sessionItemArc(index)
        let centre = arc.start + arc.width / 2
        let rotation = labelRotation(slot: slot, offset: centre)
        // Reading order runs clockwise, or anticlockwise where labelRotation turns labels over.
        let direction: CGFloat = cos(rotation - (CGFloat(slot) * sliceAngle + centre)) >= 0 ? 1 : -1
        let half = arc.width / 2 * actionRadius - segmentGap / 2
        let text = trackedLetters(label)
        let padding = min(agentContentPadding, max(0, (2 * half - text.width - agentGlyphDiameter) / 2))
        func place(_ distance: CGFloat) -> (point: CGPoint, rotation: CGFloat) {
            let offset = centre + direction * distance / actionRadius
            return (position(slot: slot, radius: actionRadius, offset: offset), rotation + offset - centre)
        }
        let start = -(half - padding)
        let middle = place(start + text.width / 2)
        let tilt = CGAffineTransform(translationX: middle.point.x, y: middle.point.y)
            .rotated(by: agentLabelTilt)
            .translatedBy(x: -middle.point.x, y: -middle.point.y)
        let glyphs = text.letters.map { letter in
            let placement = place(start + letter.x + letter.advance / 2)
            // Centre the letter on its point, flip the font's y-up outline,
            // drop it so the cap height straddles the arc, then tilt the label.
            var transform = CGAffineTransform(translationX: placement.point.x, y: placement.point.y)
                .rotated(by: placement.rotation)
                .translatedBy(x: -letter.advance / 2, y: text.capHeight / 2)
                .scaledBy(x: 1, y: -1)
                .concatenating(tilt)
            return Glyph(outline: letter.outline.copy(using: &transform) ?? letter.outline,
                         point: placement.point.applying(tilt), rotation: placement.rotation + agentLabelTilt)
        }
        return (middle, glyphs, place(half - padding - agentGlyphDiameter / 2))
    }

    /// Where the plus or X inside agent segment `index` is drawn and hit.
    static func sessionGlyphPoint(_ index: Int, label: String) -> CGPoint {
        sessionAgentLayout(index, label: label).glyph.point
    }

    /// One segment's start and width, relative to the session cell's centre.
    static func sessionItemArc(_ index: Int) -> (start: CGFloat, width: CGFloat) {
        let width = sessionSubmenuArc / CGFloat(sessionItemCount)
        return (-sessionSubmenuArc / 2 + CGFloat(index) * width, width)
    }

    /// The signed angle from the session cell's centre, so the arc never wraps.
    static func sessionArcOffset(at point: CGPoint) -> CGFloat {
        let slot = CGFloat(sessionSlots.first ?? 0)
        let delta = angle(at: point) - (slot * sliceAngle + sliceAngle / 2)
        return atan2(sin(delta), cos(delta))
    }

    /// The session submenu segment under `point`, if any.
    static func sessionItem(at point: CGPoint) -> Int? {
        let offset = sessionArcOffset(at: point) + sessionSubmenuArc / 2
        guard offset >= 0, offset <= sessionSubmenuArc else { return nil }
        return min(sessionItemCount - 1, Int(offset / (sessionSubmenuArc / CGFloat(sessionItemCount))))
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
    /// Why no agent can start now, such as one already starting; nil when one can.
    var startUnavailableReason: String?
    var canStartSession: Bool { startUnavailableReason == nil }
    /// RR-521: the agents with a live session, and the active one.
    var runningAgents: Set<SessionAgent> = []
    var activeAgent: SessionAgent?
    /// The running agents whose Workspace tab is shimmering for attention.
    var attentionAgents: Set<SessionAgent> = []
    var notice: String?
    private(set) var hoveredSlot: Int?
    private var hoveredControl: Int?
    private var hoveringGlyph = false

    /// The session submenu's segments: all four agents in table order,
    /// whether or not any session runs.
    var sessionItems: [SessionWheelAgent] {
        SessionAgent.allCases.map { agent in
            let running = runningAgents.contains(agent)
            return SessionWheelAgent(agent: agent, isRunning: running, isActive: running && agent == activeAgent,
                                     needsAttention: running && attentionAgents.contains(agent))
        }
    }

    var hoveredSessionItem: SessionWheelAgent? {
        guard isHoveringSession, let hoveredControl, sessionItems.indices.contains(hoveredControl) else { return nil }
        return sessionItems[hoveredControl]
    }

    /// The agent whose plus or X is under the pointer.
    var hoveredGlyph: SessionWheelAgent? { hoveringGlyph ? hoveredSessionItem : nil }

    /// The action a click on the pointer's session submenu target takes.
    var hoveredAgentAction: SessionWheelAgentAction? {
        guard let item = hoveredSessionItem else { return nil }
        return hoveringGlyph ? item.glyphAction : item.labelAction
    }

    /// Starts wait for a start in progress; switching and stopping are always available.
    func isEnabled(_ action: SessionWheelAgentAction) -> Bool {
        if case .start = action { return canStartSession }
        return true
    }

    /// The notch descriptor for an action: its title, why a start cannot
    /// happen now, or the active agent's name.
    func caption(for action: SessionWheelAgentAction) -> String {
        switch action {
        case .start: return startUnavailableReason ?? action.title
        case .switchTo(let agent) where agent == activeAgent: return "\(agent.name) active"
        case .switchTo, .stop: return action.title
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
    var isHoveringSession: Bool { hoveredSlot == SessionWheelGeometry.sessionSlots.first }
    var submenuSlot: Int? { isHoveringSession || isHoveringNoteTaker || isHoveringSettings ? hoveredSlot : nil }
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
        if let action = hoveredAgentAction { return caption(for: action) }
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
        return isHoveringSession ? "Open terminal tab" : nil
    }
    private var pointerOrigin: CGPoint = SessionWheelGeometry.center
    private var pointerActivated = false

    var hoveredSession: SessionWheelSession? {
        guard let hoveredSlot else { return nil }
        return slots[hoveredSlot]
    }

    /// RR-521: hover is kept, so the session submenu stays open while its
    /// agents start and stop, including the first start and the last stop.
    func refresh(sessions: [SessionWheelSession]) {
        // Preserve positions as sessions stop/start, including while a submenu is open.
        for index in self.sessions.indices {
            if let old = self.sessions[index] { self.sessions[index] = sessions.first { $0.id == old.id } }
        }
        for session in sessions where !self.sessions.contains(where: { $0?.id == session.id }) {
            if let empty = self.sessions.firstIndex(where: { $0 == nil }) { self.sessions[empty] = session }
        }
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
        hoveringGlyph = false
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
        hoveringGlyph = false
        if distance <= geometry.hubRadius || distance > geometry.actionOuterRadius + 8 {
            hoveredSlot = nil
        } else if distance <= geometry.wheelRadius {
            hoveredSlot = geometry.slot(at: pointer)
        } else if isHoveringSession,
                  distance >= geometry.actionInnerRadius, distance <= geometry.actionOuterRadius {
            hoveredControl = geometry.sessionItem(at: pointer)
            if let index = hoveredControl, sessionItems.indices.contains(index) {
                let glyph = geometry.sessionGlyphPoint(index, label: sessionItems[index].label)
                hoveringGlyph = hypot(pointer.x - glyph.x, pointer.y - glyph.y) <= geometry.agentGlyphHitRadius
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
