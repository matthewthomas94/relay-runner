import SwiftUI

struct SessionWheelView: View {
    @Bindable var model: SessionWheelModel
    let selectSlot: (Int, Bool) -> Void
    let performAction: (String, SessionWheelAction) -> Void
    let selectCenter: () -> Void
    let back: () -> Void
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hubHovered = false

    private let geometry = SessionWheelGeometry.self
    private var pageID: Int { model.pickingProject ? model.projectPage : -1 }

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture(perform: dismiss)
            Circle()
                .fill(.black)
                .frame(width: geometry.wheelRadius * 2, height: geometry.wheelRadius * 2)
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            ZStack {
                ForEach(0..<geometry.slotCount, id: \.self) { index in
                    slot(index)
                }
            }
            .id(pageID)
            .transition(.relayReplacing(.element))
            if let session = model.hoveredSession, let index = model.hoveredSlot {
                ZStack {
                    SessionWheelSector(slot: index, innerRadius: geometry.actionInnerRadius,
                                       outerRadius: geometry.actionOuterRadius,
                                       cornerRadius: SharedActionButtonMetrics.cornerRadius,
                                       padding: geometry.segmentGap)
                        .fill(.black)
                        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    ForEach(SessionWheelAction.allCases, id: \.rawValue) { action in
                        actionButton(action, session: session, slot: index)
                    }
                }
                .id(session.id)
                .transition(.relayReplacing(.element))
            }
            hub
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
        let more = model.isMoreProjectsSlot(index)
        let empty = pickingProject ? project == nil && !more : session == nil
        let title = more ? "More projects" : pickingProject ? (project?.name ?? "") : (session?.name ?? "Start session")
        let enabled = pickingProject
            ? more || (project?.isAvailable == true && model.canStartSession)
            : true
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .projectCard, isEnabled: enabled,
            isSelected: !pickingProject && session?.isFocused == true,
            isHovered: model.hoveredSlot == index, reduceMotion: reduceMotion
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
                                } else if empty {
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
                        .font(AppTypography.font(.action, size: 11))
                        .lineLimit(2).multilineTextAlignment(.center)
                        .frame(width: 90, height: 30, alignment: .top)
                }
                .position(geometry.position(slot: index, radius: 119))
                .opacity(pickingProject && empty ? 0 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .animation(presentation.animation, value: presentation)
        .accessibilityLabel(title.isEmpty ? "Empty slot" : title)
        .accessibilityHint(more ? "Next project wheel" : model.pickingProject ? "Start session" : (session == nil ? "Choose a project" : "Focus session. Move outward for session controls."))
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
            isSelected: (action == .recording && session.isRecording) || (action == .message && session.playback == .stop),
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
                controlBackground(shape, presentation: presentation, disabled: !enabled)
                VStack(spacing: 2) {
                    RelaySwap(action.symbol(for: session)) { symbol in
                        Image(systemName: symbol)
                            .font(AppTypography.symbolFont(size: 9, weight: .medium))
                    }
                    RelaySwap(action.title(for: session), style: .text) { title in
                        Text(title)
                            .font(AppTypography.font(.smallCaption, size: 7.5))
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
                .frame(width: geometry.actionLabelSize.width, height: geometry.actionLabelSize.height)
                .foregroundStyle(action == .stop || (action == .recording && session.isRecording)
                                 || (action == .message && session.playback == .stop)
                                 ? ProgramBoardStyle.red : ProgramBoardStyle.primaryText)
                .rotationEffect(.radians(geometry.actionLabelRotation(slot: slot, action: action)))
                .position(geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(action)))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .animation(presentation.animation, value: presentation)
        .accessibilityLabel("\(action.title(for: session)) for \(session.name)")
        .help(enabled ? action.title(for: session) : (action == .message ? "No message yet" : "Recording unavailable"))
    }

    private var hub: some View {
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isHovered: hubHovered, reduceMotion: reduceMotion
        )
        let title = model.workspaceActionTitle
        let detail = model.pickingProject
            ? model.notice ?? model.startUnavailableReason ?? (model.projects.isEmpty ? "No projects to start" : model.projectPage > 0 ? "Previous projects" : "Back to sessions")
            : model.notice ?? model.startUnavailableReason ?? ""
        return Button(action: selectCenter) {
            ZStack {
                if model.pickingProject {
                    HStack(alignment: .center, spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(AppTypography.symbolFont(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("Back")
                            .font(AppTypography.font(.action, size: 12))
                            .lineLimit(1)
                    }
                    .transition(.relayReplacing(.text))
                } else {
                    VStack(spacing: 5) {
                        RelaySwap(title, style: .text) { title in
                            Text(title.replacingOccurrences(of: " ", with: "\n"))
                                .font(AppTypography.font(.action, size: 12)).lineLimit(2)
                        }
                        if !detail.isEmpty {
                            RelaySwap(detail, style: .text) { detail in
                                Text(detail)
                                    .font(AppTypography.font(.caption)).lineLimit(3)
                                    .foregroundStyle(ProgramBoardStyle.mutedText)
                            }
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(6)
                    .transition(.relayReplacing(.text))
                }
            }
            .frame(width: geometry.hubRadius * 2, height: geometry.hubRadius * 2)
            .background(controlBackground(Circle(), presentation: presentation))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.pickingProject ? (model.projectPage > 0 ? "Previous projects" : "Back to sessions") : title)
        .help(model.pickingProject ? detail : title)
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
