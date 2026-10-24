import SwiftUI

struct SessionWheelView: View {
    @Bindable var model: SessionWheelModel
    let selectSlot: (Int, Bool) -> Void
    let performAction: (String, SessionWheelAction) -> Void
    let selectCenter: () -> Void
    let back: () -> Void
    let dismiss: () -> Void
    var performNoteAction: (SessionWheelNoteAction) -> Void = { _ in }
    var recordingLevel: (String) -> Float = { _ in 0 }
    var hoverFeedback: (CGPoint?, SessionWheelHaptics.Target?) -> Void = { _, _ in }
    var presentation = SessionWheelPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hubHovered = false
    @State var menuMotion = SessionWheelMenuMotion()

    private let geometry = SessionWheelGeometry.self
    private var pageID: Int { model.pageID }
    private var submenuSlot: Int? { model.submenuSlot }

    var body: some View {
        let requestedMenu = SessionWheelMenu(model)
        TimelineView(.animation(paused: !menuMotion.motion.isAnimating)) { _ in
            let menuProgress = menuMotion.motion.progress(at: ProcessInfo.processInfo.systemUptime)
            let progress = reduceMotion ? menuProgress : min(presentation.progress, menuProgress)
            SessionWheelSubmenuAnimation(progress: .init(slot: submenuSlot)) { submenus in
                wheel(menu: menuMotion.displayed ?? requestedMenu,
                      tiles: SessionWheelPresentation(progress: progress, reduceMotion: reduceMotion),
                      submenus: submenus)
            }
            .animation(SessionWheelSubmenuPresentation.animation(reduceMotion: reduceMotion), value: submenuSlot)
        }
        .task(id: requestedMenu) {
            await menuMotion.update(to: requestedMenu, reduceMotion: reduceMotion)
        }
    }

    func wheel(menu: SessionWheelMenu, tiles: SessionWheelPresentation,
               submenus: SessionWheelSubmenuProgress? = nil) -> some View {
        let submenus = submenus ?? .init(slot: submenuSlot)
        return ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture { point in
                let slot = geometry.slot(at: point)
                if !geometry.contains(point, submenuSlot: submenus[slot] > 0 ? slot : nil) { dismiss() }
            }
            SessionWheelLiquidBackdrop(progress: submenus, reduceMotion: reduceMotion)
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
                .scaleEffect(presentation.discScale)
                .opacity(presentation.discScale == 0 ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            ZStack {
                ForEach(0..<geometry.slotCount, id: \.self) { index in
                    slot(index, menu: menu)
                        .compositingGroup()
                        .blur(radius: tiles.segmentBlur)
                        .offset(tiles.segmentOffset(index))
                }
            }
            .mask {
                Circle().frame(width: geometry.wheelRadius * 2, height: geometry.wheelRadius * 2)
            }
            .scaleEffect(tiles.discScale)
            .opacity(tiles.segmentVisibility * tiles.opacity)
            .allowsHitTesting(!menuMotion.motion.isAnimating && menu.identity == SessionWheelMenu(model).identity)
            .accessibilityHidden(menuMotion.motion.isAnimating)
            .transaction { $0.animation = nil }
            ZStack {
                ForEach(0..<geometry.slotCount, id: \.self) { index in
                    let frame = SessionWheelSubmenuPresentation(progress: submenus[index], reduceMotion: reduceMotion)
                    if index == SessionWheelShortcut.noteTaker.rawValue,
                       menu.shortcut(at: index) == .noteTaker, frame.progress > 0 {
                        ZStack {
                            ForEach(SessionWheelNoteAction.allCases, id: \.rawValue) { action in
                                noteActionButton(action)
                            }
                        }
                        .scaleEffect(frame.scale)
                        .opacity(frame.controlsOpacity)
                        .allowsHitTesting(model.isHoveringNoteTaker && (reduceMotion || frame.progress >= 0.95))
                        .accessibilityHidden(!model.isHoveringNoteTaker)
                        .transition(.identity)
                        .transaction { $0.animation = nil }
                    } else if let session = model.slots[index] ?? menu.sessions[index], frame.progress > 0 {
                        ZStack {
                            ForEach(SessionWheelAction.allCases, id: \.rawValue) { action in
                                actionButton(action, session: session, slot: index)
                            }
                        }
                        .scaleEffect(frame.scale)
                        .opacity(frame.controlsOpacity)
                        .allowsHitTesting(model.hoveredSession?.id == session.id && (reduceMotion || frame.progress >= 0.95))
                        .accessibilityHidden(model.hoveredSession?.id != session.id)
                        .transition(.identity)
                        .transaction { $0.animation = nil }
                    }
                }
            }
            .mask { SessionWheelSubmenuExterior().fill(style: FillStyle(eoFill: true)) }
            .scaleEffect(presentation.discScale)
            .opacity(presentation.segmentVisibility)
            hub
                .compositingGroup()
                .blur(radius: presentation.hubBlur)
                .opacity(presentation.hubVisibility)
                .mask {
                    Circle().frame(width: geometry.wheelRadius * 2, height: geometry.wheelRadius * 2)
                        .scaleEffect(presentation.discScale)
                }
        }
        .frame(width: geometry.diameter, height: geometry.diameter)
        .opacity(presentation.opacity)
        .foregroundStyle(ProgramBoardStyle.primaryText)
        .preferredColorScheme(.dark)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                model.hover(at: point)
                var target = SessionWheelHaptics.target(at: point, model: model)
                if menuMotion.motion.isAnimating || menu.identity != SessionWheelMenu(model).identity
                    || tiles.progress < 1 || presentation.progress < 1 {
                    target = nil
                }
                if case .action(let slot, _) = target, !reduceMotion, submenus[slot] < 0.95 {
                    target = nil
                }
                hoverFeedback(point, target)
            case .ended:
                model.clearHover()
                hoverFeedback(nil, nil)
            }
        }
        .onExitCommand(perform: back)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.pickingProject ? "Start a project session" : "Session wheel")
    }

    private func slot(_ index: Int, menu: SessionWheelMenu) -> some View {
        let pickingProject = menu.pickingProject
        let page = menu.page
        let session = menu.sessions[index]
        let shortcut = menu.shortcut(at: index)
        let project = menu.projects.indices.contains(index) ? menu.projects[index] : nil
        let moreProjects = pickingProject && menu.hasMoreProjects && index == geometry.slotCount - 1
        let moreSessions = !pickingProject && !menu.showingAllSessions && menu.hasMoreSessions
            && index == geometry.sessionSlots.last
        let more = moreProjects || moreSessions
        let empty = pickingProject ? project == nil && !more : session == nil && shortcut == nil && !more
        let title = moreProjects ? "More projects" : moreSessions ? "More sessions"
            : pickingProject ? (project?.name ?? "") : shortcut?.title ?? session?.name ?? "Start session"
        let sessionHint = session?.isFocused == true
            ? "Open this session's terminal in Workspace."
            : "Switch session. Move outward for session controls."
        let enabled = pickingProject
            ? more || (project?.isAvailable == true && menu.canStartSession)
            : !menu.showingAllSessions || session != nil
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .projectCard, isEnabled: enabled,
            isSelected: !pickingProject && (session?.isFocused == true
                || (shortcut == .noteTaker && model.notePhase.ownsForeground)),
            isHovered: !menuMotion.motion.isAnimating && model.hoveredSlot == index, reduceMotion: reduceMotion
        )
        let shape = SessionWheelSector(slot: index, innerRadius: geometry.segmentInnerRadius,
                                       outerRadius: geometry.segmentOuterRadius)
        return Button {
            guard pageID == page else { return }
            selectSlot(index, true)
        } label: {
            ZStack {
                controlBackground(shape, presentation: presentation, disabled: !enabled)
                VStack(spacing: 7) {
                    ZStack(alignment: .topTrailing) {
                        controlBackground(Circle(), presentation: presentation)
                            .frame(width: 42, height: 42)
                            .overlay {
                                if more {
                                    Image(systemName: "ellipsis").font(AppTypography.symbolFont(size: 17, weight: .medium))
                                } else if let shortcut {
                                    Image(systemName: shortcut.symbol).font(AppTypography.symbolFont(size: 17, weight: .regular))
                                } else if empty {
                                    Image(systemName: "plus").font(AppTypography.symbolFont(size: 17, weight: .medium))
                                } else {
                                    Text(initials(title)).font(AppTypography.font(.projectTitle, size: 15))
                                }
                            }
                        if !pickingProject, let session {
                            Circle().fill(Color(.sRGB, red: 43 / 255, green: 17 / 255, blue: 232 / 255, opacity: 1))
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(.black, lineWidth: 2))
                            if session.unreadCount > 0 {
                                Text("\(session.unreadCount)")
                                    .font(AppTypography.font(.smallCaption))
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(.blue, in: Capsule())
                                    .offset(x: 7, y: 31)
                            }
                        }
                    }
                    Text(title)
                        .font(AppTypography.font(.action, size: 11))
                        .lineLimit(2).multilineTextAlignment(.center)
                        .frame(width: 90, height: 30, alignment: .top)
                }
                .position(geometry.position(slot: index, radius: 119))
                .opacity((pickingProject || menu.showingAllSessions) && empty ? 0 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .animation(presentation.animation, value: presentation)
        .accessibilityLabel(title.isEmpty ? "Empty slot" : title)
        .accessibilityHint(moreProjects ? "Next project wheel" : moreSessions ? "Show all active sessions"
            : pickingProject ? "Start session" : shortcut == .noteTaker
            ? "Open Notetaker. Move outward for recording controls."
            : shortcut != nil ? "Open \(title)" : session == nil ? "Choose a project" : sessionHint)
        .accessibilityAction {
            guard pageID == page else { return }
            selectSlot(index, false)
        }
        .accessibilityActions {
            if shortcut == .noteTaker {
                ForEach(SessionWheelNoteAction.allCases, id: \.rawValue) { action in
                    if action.isEnabled(for: model.notePhase) {
                        Button(action.title(for: model.notePhase)) { performNoteAction(action) }
                    }
                }
            }
            if !pickingProject, let session {
                ForEach(SessionWheelAction.allCases, id: \.rawValue) { action in
                    if action.isEnabled(for: session) {
                        Button(action.title(for: session)) { performAction(session.id, action) }
                    }
                }
            }
        }
        .help(!enabled && !empty ? "Project unavailable or session limit reached" : title)
    }

    private func actionButton(_ action: SessionWheelAction, session: SessionWheelSession, slot: Int) -> some View {
        let enabled = action.isEnabled(for: session)
        return submenuButton(index: action.rawValue, slot: slot,
                             title: "\(action.title(for: session)) for \(session.name)",
                             help: enabled ? action.title(for: session) : (action == .message ? "No message yet" : "Recording unavailable"),
                             symbol: action.symbol(for: session), enabled: enabled,
                             hovered: model.hoveredAction == action && model.hoveredSession?.id == session.id,
                             destructive: action == .stop, level: { recordingLevel(session.id) }) {
            guard model.hoveredSession?.id == session.id else { return }
            performAction(session.id, action)
        }
    }

    private func noteActionButton(_ action: SessionWheelNoteAction) -> some View {
        submenuButton(index: action.rawValue, slot: SessionWheelShortcut.noteTaker.rawValue,
                      title: action.title(for: model.notePhase), help: action.help(for: model.notePhase),
                      symbol: action.symbol(for: model.notePhase), enabled: action.isEnabled(for: model.notePhase),
                      hovered: model.hoveredNoteAction == action, destructive: action == .cancel) {
            guard model.isHoveringNoteTaker else { return }
            performNoteAction(action)
        }
    }

    private func submenuButton(index: Int, slot: Int, title: String, help: String, symbol: String,
                               enabled: Bool, hovered: Bool, destructive: Bool,
                               level: @escaping () -> Float = { 0 }, perform: @escaping () -> Void) -> some View {
        let isNoteMark = symbol == "checkmark" || symbol == "xmark"
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isEnabled: enabled,
            isHovered: hovered,
            reduceMotion: reduceMotion
        )
        let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                       outerRadius: geometry.actionOuterRadius, subdivision: index)
        return Button(action: perform) {
            ZStack {
                controlBackground(shape, presentation: presentation)
                Group {
                    if symbol == "waveform" {
                        SessionWheelRecordingWaveform(level: level)
                    } else if symbol == "power" {
                        Image(systemName: symbol)
                            .resizable().scaledToFit()
                            .frame(width: 10, height: 10)
                    } else {
                        Image(systemName: symbol)
                            .font(AppTypography.symbolFont(size: isNoteMark ? 11 : 9,
                                                           weight: isNoteMark ? .bold : .medium))
                    }
                }
                .contentTransition(.opacity)
                .animation(RelayMotion.change(reduceMotion: reduceMotion), value: symbol)
                .frame(width: geometry.actionLabelSize.width, height: geometry.actionLabelSize.height)
                .foregroundStyle(!enabled
                                 ? (contrast == .increased ? ProgramBoardStyle.disabledText : Color(.sRGB, red: 24 / 255, green: 27 / 255, blue: 33 / 255, opacity: 1))
                                 : destructive ? ProgramBoardStyle.red : ProgramBoardStyle.primaryText)
                .rotationEffect(.radians(geometry.actionLabelRotation(slot: slot, index: index)))
                .position(geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(index)))
            }
            .contentShape(shape)
        }
        .buttonStyle(SessionWheelActionButtonStyle())
        .disabled(!enabled)
        .animation(presentation.animation, value: presentation)
        .accessibilityLabel(title)
        .help(help)
    }

    private var hub: some View {
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isHovered: hubHovered, reduceMotion: reduceMotion
        )
        let title = model.isNested
            ? (model.projectPage > 0 ? "Previous projects" : "Back to sessions")
            : model.workspaceActionTitle
        let detail = model.notice ?? model.startUnavailableReason
            ?? (model.pickingProject && model.projects.isEmpty ? "No projects to start" : "")
        return Button(action: selectCenter) {
            SessionWheelWorkspaceGlyph(isWorkspaceVisible: model.isWorkspaceVisible,
                                       isPickingProject: model.isNested,
                                       status: model.notchStatus)
                .frame(width: geometry.hubRadius * 2, height: geometry.hubRadius * 2)
                .background(controlBackground(Circle(), presentation: presentation))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .help(detail.isEmpty ? title : "\(title). \(detail)")
        .onHover { hubHovered = $0 }
    }

    private func controlBackground<S: Shape>(
        _ shape: S, presentation: ProgramBoardInteractionPresentation, disabled: Bool = false
    ) -> some View {
        ProgramBoardInteractiveBackground(
            shape: .custom(AnyShape(shape)),
            presentation: presentation,
            disabled: disabled,
            usesCardStyle: true
        )
        .overlay {
            if contrast == .increased { shape.stroke(.white.opacity(0.55), lineWidth: 1) }
        }
        .animation(presentation.animation, value: presentation)
    }

    private func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

private struct SessionWheelActionButtonStyle: ButtonStyle {
    // The wheel dims only the disabled icon, keeping the segment's fill intact.
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct SessionWheelRecordingWaveform: View {
    let level: () -> Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { _ in
            let amplitude = reduceMotion ? 1 : CGFloat(level())
            SessionWheelWaveformShape(amplitude: amplitude)
                .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .animation(reduceMotion ? nil : RelayMotion.changeCurve.animation(duration: RelayMotion.hoverDuration), value: amplitude)
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

private struct SessionWheelWaveformShape: Shape {
    var amplitude: CGFloat
    var animatableData: CGFloat {
        get { amplitude }
        set { amplitude = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let bars: [(CGFloat, CGFloat)] = [(4.6667, 6.6667), (2, 9.3333), (0, 12), (3.3333, 8), (1.3333, 10), (4.6667, 6.6667)]
        let scale = 0.25 + 0.75 * min(max(amplitude, 0), 1)
        return Path { path in
            for (index, bar) in bars.enumerated() {
                let x = rect.minX + CGFloat(index) * rect.width / 5
                path.move(to: CGPoint(x: x, y: rect.midY + (bar.0 - 6) * scale * rect.height / 12))
                path.addLine(to: CGPoint(x: x, y: rect.midY + (bar.1 - 6) * scale * rect.height / 12))
            }
        }
    }
}

struct SessionWheelSector: Shape {
    let slot: Int
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    var subdivision: Int?
    var cornerRadius: CGFloat?
    var padding: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let innerRadius = self.innerRadius - padding
        let outerRadius = self.outerRadius + padding
        let step = 2 * CGFloat.pi / CGFloat(SessionWheelGeometry.slotCount)
        let width = subdivision == nil ? step : step / 3
        let halfGap = SessionWheelGeometry.segmentGap / 2 - padding
        let start = CGFloat(slot) * step - .pi / 2 - step / 2 + CGFloat(subdivision ?? 0) * width
        let end = start + width
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let corner = min((cornerRadius ?? (subdivision == nil ? BoardDarkSurfaceStyle.nestedCardCornerRadius
                                                             : SharedActionButtonMetrics.cornerRadius)) + padding,
                         (outerRadius - innerRadius) / 2)
        // Offset each straight edge by half the gap so spacing stays constant at every radius.
        // Corner circles still meet those parallel edges and concentric arcs tangentially.
        // Backdrop padding expands all edges and corners by the same amount.
        let outerInset = asin((corner + halfGap) / (outerRadius - corner))
        let innerInset = asin((corner + halfGap) / (innerRadius + corner))
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        let innerEndCorner = point(innerRadius + corner, end - innerInset)
        let outerStartCorner = point(outerRadius - corner, start + outerInset)
        var path = Path()
        path.addArc(center: center, radius: outerRadius,
                    startAngle: .radians(start + outerInset), endAngle: .radians(end - outerInset), clockwise: false)
        path.addArc(center: point(outerRadius - corner, end - outerInset), radius: corner,
                    startAngle: .radians(end - outerInset), endAngle: .radians(end + .pi / 2), clockwise: false)
        path.addLine(to: CGPoint(x: innerEndCorner.x - corner * sin(end),
                                y: innerEndCorner.y + corner * cos(end)))
        path.addArc(center: innerEndCorner, radius: corner,
                    startAngle: .radians(end + .pi / 2), endAngle: .radians(end - innerInset + .pi), clockwise: false)
        path.addArc(center: center, radius: innerRadius,
                    startAngle: .radians(end - innerInset), endAngle: .radians(start + innerInset), clockwise: true)
        path.addArc(center: point(innerRadius + corner, start + innerInset), radius: corner,
                    startAngle: .radians(start + innerInset + .pi), endAngle: .radians(start + 3 * .pi / 2), clockwise: false)
        path.addLine(to: CGPoint(x: outerStartCorner.x + corner * sin(start),
                                y: outerStartCorner.y - corner * cos(start)))
        path.addArc(center: outerStartCorner, radius: corner,
                    startAngle: .radians(start - .pi / 2), endAngle: .radians(start + outerInset), clockwise: false)
        path.closeSubpath()
        return path
    }
}
