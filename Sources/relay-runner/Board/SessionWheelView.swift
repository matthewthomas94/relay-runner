import SwiftUI

struct SessionWheelView: View {
    @Bindable var model: SessionWheelModel
    let selectSlot: (Int, Bool) -> Void
    let performAction: (String, SessionWheelAction) -> Void
    let back: () -> Void
    let dismiss: () -> Void
    let turnPage: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hubHovered = false
    @State private var hoveredPageDirection: Int?

    private let geometry = SessionWheelGeometry.self
    private var border: Color { contrast == .increased ? .white.opacity(0.55) : BoardDarkSurfaceStyle.border }
    private var pageID: Int { model.pickingProject ? model.projectPage : -1 }

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture(perform: dismiss)
            Circle()
                .fill(.black)
                .frame(width: geometry.wheelRadius * 2, height: geometry.wheelRadius * 2)
                .overlay(Circle().stroke(border, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
            ZStack {
                ForEach(0..<geometry.slotCount, id: \.self) { index in
                    slot(index)
                }
            }
            .id(pageID)
            .transition(.relayReplacing(.element))
            if let session = model.hoveredSession, let index = model.hoveredSlot {
                ZStack {
                    ForEach(SessionWheelAction.allCases, id: \.rawValue) { action in
                        actionButton(action, session: session, slot: index)
                    }
                }
                .id(session.id)
                .transition(.relayReplacing(.element))
            }
            hub
            if model.pickingProject && model.pageCount > 1 {
                HStack(spacing: 10) {
                    pageButton(-1)
                    RelaySwap("\(model.projectPage + 1) / \(model.pageCount)", style: .text) { page in
                        Text(page).font(AppTypography.font(.label))
                    }
                    pageButton(1)
                }
                .padding(4)
                .background(BoardDarkCapsuleBackground())
                .position(x: geometry.center.x, y: geometry.center.y + geometry.wheelRadius + 30)
                .transition(.relayElement)
            }
        }
        .frame(width: geometry.diameter, height: geometry.diameter)
        .foregroundStyle(ProgramBoardStyle.primaryText)
        .preferredColorScheme(.dark)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): model.hover(at: point)
            case .ended: model.clearHover()
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: pageID)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.hoveredSession?.id)
        .onExitCommand(perform: back)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.pickingProject ? "Start a project session" : "Session wheel")
    }

    private func slot(_ index: Int) -> some View {
        let pickingProject = model.pickingProject
        let page = pageID
        let session = model.slots[index]
        let project = model.visibleProjects.indices.contains(index) ? model.visibleProjects[index] : nil
        let empty = pickingProject ? project == nil : session == nil
        let title = pickingProject ? (project?.name ?? "") : (session?.name ?? "Start session")
        let enabled = pickingProject
            ? project?.isAvailable == true && model.canStartSession
            : true
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .projectCard, isEnabled: enabled,
            isSelected: !pickingProject && session?.isFocused == true,
            isHovered: model.hoveredSlot == index, reduceMotion: reduceMotion
        )
        let shape = SessionWheelSector(slot: index, innerRadius: geometry.hubRadius + 5,
                                       outerRadius: geometry.wheelRadius - 4)
        return Button {
            guard pageID == page else { return }
            selectSlot(index, true)
        } label: {
            ZStack {
                controlBackground(shape, presentation: presentation)
                VStack(spacing: 7) {
                    ZStack(alignment: .topTrailing) {
                        controlBackground(Circle(), presentation: presentation, card: true)
                            .frame(width: 42, height: 42)
                            .overlay {
                                if empty {
                                    Image(systemName: "plus").font(AppTypography.symbolFont(size: 17, weight: .medium))
                                } else {
                                    Text(initials(title)).font(AppTypography.font(.projectTitle, size: 15))
                                }
                            }
                        if !pickingProject, let session {
                            Circle().fill(session.isRecording ? ProgramBoardStyle.red : (session.isFocused ? .blue : ProgramBoardStyle.green))
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(.black, lineWidth: 2))
                            if session.unreadCount > 0 {
                                Text("\(session.unreadCount)")
                                    .font(AppTypography.font(.smallCaption))
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(.blue, in: Capsule())
                                    .offset(x: 7, y: 31)
                                    .transition(.relayElement)
                            }
                        }
                    }
                    Text(title)
                        .font(AppTypography.font(.controlHeading))
                        .lineLimit(2).multilineTextAlignment(.center)
                        .frame(width: 90, height: 30, alignment: .top)
                }
                .position(geometry.position(slot: index, radius: 119))
                .opacity(pickingProject && empty ? 0 : presentation.foregroundOpacity)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title.isEmpty ? "Empty slot" : title)
        .accessibilityHint(model.pickingProject ? "Start session" : (session == nil ? "Choose a project" : "Focus session. Move outward for session controls."))
        .accessibilityAction {
            guard pageID == page else { return }
            selectSlot(index, false)
        }
        .accessibilityActions {
            if !model.pickingProject, let session {
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
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isEnabled: enabled,
            isSelected: action == .recording && session.isRecording,
            isHovered: model.hoveredAction == action && model.hoveredSession?.id == session.id,
            reduceMotion: reduceMotion
        )
        let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                       outerRadius: geometry.actionOuterRadius, subdivision: action.rawValue)
        return Button {
            guard model.hoveredSession?.id == session.id else { return }
            performAction(session.id, action)
        } label: {
            ZStack {
                controlBackground(shape, presentation: presentation)
                VStack(spacing: 2) {
                    Image(systemName: action.symbol(for: session))
                        .font(AppTypography.symbolFont(size: 9, weight: .medium))
                    Text(action.title(for: session))
                        .font(AppTypography.font(.smallCaption, size: 7.5))
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                .frame(width: geometry.actionLabelSize.width, height: geometry.actionLabelSize.height)
                .foregroundStyle(action == .stop || (action == .recording && session.isRecording)
                                 ? ProgramBoardStyle.red : ProgramBoardStyle.primaryText)
                .opacity(presentation.foregroundOpacity)
                .rotationEffect(.radians(geometry.actionLabelRotation(slot: slot, action: action)))
                .position(geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(action)))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("\(action.title(for: session)) for \(session.name)")
        .help(enabled ? action.title(for: session) : (action == .message ? "No message yet" : "Recording unavailable"))
    }

    private var hub: some View {
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isHovered: hubHovered, reduceMotion: reduceMotion
        )
        let title = model.pickingProject ? "Projects" : (model.hoveredSession?.name ?? "Sessions")
        let detail = model.pickingProject
            ? model.notice ?? model.startUnavailableReason ?? (model.projects.isEmpty ? "No projects to start" : "Start session")
            : hubDetail
        return Button(action: back) {
            VStack(spacing: 5) {
                if model.pickingProject {
                    Image(systemName: "chevron.left").font(AppTypography.symbolFont(size: 14, weight: .semibold))
                        .transition(.relayElement)
                }
                RelaySwap(title, style: .text) { title in
                    Text(title)
                        .font(AppTypography.font(.projectTitle)).lineLimit(2)
                }
                RelaySwap(detail, style: .text) { detail in
                    Text(detail)
                        .font(AppTypography.font(.caption)).lineLimit(3)
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                }
            }
            .multilineTextAlignment(.center)
            .frame(width: geometry.hubRadius * 2 - 12, height: geometry.hubRadius * 2 - 12)
            .padding(6)
            .background(controlBackground(Circle(), presentation: presentation, card: true))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hubHovered = $0 }
        .accessibilityLabel(model.pickingProject ? "Back to sessions" : "Close session wheel")
    }

    private func pageButton(_ direction: Int) -> some View {
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isHovered: hoveredPageDirection == direction, reduceMotion: reduceMotion
        )
        return Button { turnPage(direction) } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(AppTypography.symbolFont(size: 11, weight: .medium))
                .frame(width: 28, height: 28)
                .background(controlBackground(Circle(), presentation: presentation))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredPageDirection = $0 ? direction : nil }
        .accessibilityLabel(direction < 0 ? "Previous projects" : "Next projects")
    }

    private func controlBackground<S: Shape>(
        _ shape: S, presentation: ProgramBoardInteractionPresentation, card: Bool = false
    ) -> some View {
        let fill = card
            ? (presentation.usesHoverFill ? BoardDarkSurfaceStyle.cardActiveFill : BoardDarkSurfaceStyle.cardFill)
            : (presentation.usesHoverFill ? BoardDarkSurfaceStyle.hoverFill : BoardDarkSurfaceStyle.contentFill)
        let stroke = contrast == .increased || presentation.strokeOpacity == 0
            ? border : Color.white.opacity(presentation.strokeOpacity)
        return shape.fill(fill)
            .overlay(shape.fill(.white.opacity(presentation.fillOverlayOpacity)))
            .overlay(shape.stroke(stroke, lineWidth: 1))
            .animation(presentation.animation, value: presentation)
    }

    private var hubDetail: String {
        if let notice = model.notice { return notice }
        if let session = model.hoveredSession {
            return model.hoveredAction?.title(for: session) ?? (session.isRecording ? "Recording" : "Move outward")
        }
        if let reason = model.startUnavailableReason { return reason }
        if model.hoveredSlot != nil { return "Choose a project" }
        return "Hover to control"
    }

    private func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct SessionWheelSector: Shape {
    let slot: Int
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    var subdivision: Int?

    func path(in rect: CGRect) -> Path {
        let step = 2 * CGFloat.pi / CGFloat(SessionWheelGeometry.slotCount)
        let width = subdivision == nil ? step : step / 3
        let gap = CGFloat.pi / 300
        let start = CGFloat(slot) * step - .pi / 2 - step / 2 + CGFloat(subdivision ?? 0) * width + gap
        let end = start + width - 2 * gap
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let corner = min(subdivision == nil ? BoardDarkSurfaceStyle.nestedCardCornerRadius
                                            : SharedActionButtonMetrics.cornerRadius,
                         (outerRadius - innerRadius) / 2)
        // Corner circles meet both the radial edges and concentric arcs tangentially.
        let outerInset = asin(corner / (outerRadius - corner))
        let innerInset = asin(corner / (innerRadius + corner))
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        var path = Path()
        path.addArc(center: center, radius: outerRadius,
                    startAngle: .radians(start + outerInset), endAngle: .radians(end - outerInset), clockwise: false)
        path.addArc(center: point(outerRadius - corner, end - outerInset), radius: corner,
                    startAngle: .radians(end - outerInset), endAngle: .radians(end + .pi / 2), clockwise: false)
        path.addLine(to: point(sqrt(innerRadius * innerRadius + 2 * innerRadius * corner), end))
        path.addArc(center: point(innerRadius + corner, end - innerInset), radius: corner,
                    startAngle: .radians(end + .pi / 2), endAngle: .radians(end - innerInset + .pi), clockwise: false)
        path.addArc(center: center, radius: innerRadius,
                    startAngle: .radians(end - innerInset), endAngle: .radians(start + innerInset), clockwise: true)
        path.addArc(center: point(innerRadius + corner, start + innerInset), radius: corner,
                    startAngle: .radians(start + innerInset + .pi), endAngle: .radians(start + 3 * .pi / 2), clockwise: false)
        path.addLine(to: point(sqrt(outerRadius * outerRadius - 2 * outerRadius * corner), start))
        path.addArc(center: point(outerRadius - corner, start + outerInset), radius: corner,
                    startAngle: .radians(start - .pi / 2), endAngle: .radians(start + outerInset), clockwise: false)
        path.closeSubpath()
        return path
    }
}
