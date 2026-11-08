import SwiftUI

struct SessionWheelView: View {
    @Bindable var model: SessionWheelModel
    let selectSlot: (Int, Bool) -> Void
    let performAction: (String, SessionWheelAction) -> Void
    let selectCenter: () -> Void
    let dismiss: () -> Void
    var performNoteAction: (SessionWheelNoteAction) -> Void = { _ in }
    var recordingLevel: (String) -> Float = { _ in 0 }
    var hoverFeedback: (CGPoint?, SessionWheelHaptics.Target?) -> Void = { _, _ in }
    var adjustIntensity: (CGPoint) -> Void = { _ in }
    var finishIntensity: (CGPoint) -> Void = { _ in }
    var stepIntensity: (Int) -> Void = { _ in }
    var performKeepAwake: () -> Void = {}
    var performAutoPlay: () -> Void = {}
    var presentation = SessionWheelPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hubHovered = false
    @State var menuMotion = SessionWheelMenuMotion()

    private let geometry = SessionWheelGeometry.self
    static let coordinateSpace = "session-wheel"
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
                    } else if index == SessionWheelIntensity.slot,
                              menu.shortcut(at: index) == .settings, frame.progress > 0 {
                        ZStack {
                            intensitySlider
                            keepAwakeButton
                            autoPlayButton
                        }
                        .scaleEffect(frame.scale)
                        .opacity(frame.controlsOpacity)
                        .allowsHitTesting(model.isHoveringSettings && (reduceMotion || frame.progress >= 0.95))
                        .accessibilityHidden(!model.isHoveringSettings)
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
        .coordinateSpace(name: Self.coordinateSpace)
        .opacity(presentation.opacity)
        .foregroundStyle(ProgramBoardStyle.primaryText)
        .preferredColorScheme(.dark)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                // A slider drag owns the pointer: no hover changes or ticks until it ends.
                guard !model.isAdjustingIntensity else { return }
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
                guard !model.isAdjustingIntensity else { return }
                model.clearHover()
                hoverFeedback(nil, nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session wheel")
    }

    private func slot(_ index: Int, menu: SessionWheelMenu) -> some View {
        let session = menu.sessions[index]
        let shortcut = menu.shortcut(at: index)
        let startSlot = model.isStartSlot(index)
        let empty = session == nil && shortcut == nil
        // The session slot reads Terminal while a session runs and Start session otherwise.
        let title = shortcut?.title ?? (session != nil ? SessionWheelSessionSlot.title : startSlot ? "Start session" : "")
        let sessionHint = session?.isFocused == true
            ? "Open this session's terminal in Workspace."
            : "Switch session. Move outward for session controls."
        let enabled = !empty || (startSlot && menu.canStartSession)
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .projectCard, isEnabled: enabled,
            isSelected: (session?.isFocused == true
                || (shortcut == .noteTaker && model.notePhase.ownsForeground)),
            isHovered: !menuMotion.motion.isAnimating && model.hoveredSlot == index, reduceMotion: reduceMotion
        )
        let shape = SessionWheelSector(slot: index, innerRadius: geometry.segmentInnerRadius,
                                       outerRadius: geometry.segmentOuterRadius)
        return Button {
            selectSlot(index, true)
        } label: {
            ZStack {
                controlBackground(shape, presentation: presentation, disabled: !enabled)
                VStack(spacing: 7) {
                    ZStack(alignment: .topTrailing) {
                        controlBackground(Circle(), presentation: presentation)
                            .frame(width: 42, height: 42)
                            .overlay {
                                if let shortcut {
                                    Image(systemName: shortcut.symbol).font(AppTypography.symbolFont(size: 17, weight: .regular))
                                } else if empty {
                                    Image(systemName: "plus").font(AppTypography.symbolFont(size: 17, weight: .medium))
                                } else {
                                    Image(systemName: SessionWheelSessionSlot.symbol)
                                        .font(AppTypography.symbolFont(size: 17, weight: .regular))
                                }
                            }
                        if let session {
                            if session.unreadCount > 0 {
                                Text("\(session.unreadCount)")
                                    .font(AppTypography.font(.smallCaption))
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(.blue, in: Capsule())
                                    .offset(x: 7, y: 31)
                            }
                        }
                    }
                    // Hovered submenu controls name themselves in the notch, not under the title.
                    Text(title)
                        .font(AppTypography.font(.action, size: 11))
                        .lineLimit(2).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 90, height: 30, alignment: .top)
                }
                .position(geometry.position(slot: index, radius: 119))
                .opacity(empty && !startSlot ? 0 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .animation(presentation.animation, value: presentation)
        .accessibilityLabel(session.map { "\(title), \($0.name)" } ?? (title.isEmpty ? "Empty slot" : title))
        .accessibilityHint(shortcut == .noteTaker
            ? "Open Notetaker. Move outward for recording controls."
            : shortcut == .settings ? "Open Settings. Move outward for particle intensity, Keep Awake and voice auto-play."
            : shortcut != nil ? "Open \(title)" : session == nil ? "Start the general session" : sessionHint)
        .accessibilityAction {
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
            if shortcut == .settings {
                if !model.keepAwake.isPending {
                    Button(model.keepAwake.actionTitle) { performKeepAwake() }
                }
                Button(model.autoPlayActionTitle) { performAutoPlay() }
            }
            if let session {
                ForEach(SessionWheelAction.allCases, id: \.rawValue) { action in
                    if action.isEnabled(for: session) {
                        Button(action.title(for: session)) { performAction(session.id, action) }
                    }
                }
            }
        }
        .notchHint(!enabled && startSlot ? model.startUnavailableReason ?? title : title)
    }

    private func actionButton(_ action: SessionWheelAction, session: SessionWheelSession, slot: Int) -> some View {
        let enabled = action.isEnabled(for: session)
        return submenuButton(index: action.rawValue, slot: slot,
                             title: "\(action.title(for: session)) for \(session.name)",
                             help: enabled ? action.caption(for: session) : (action == .message ? "No message" : "Recording unavailable"),
                             symbol: action.symbol(for: session), enabled: enabled,
                             hovered: model.hoveredAction == action && model.hoveredSession?.id == session.id,
                             destructive: action == .stop, level: { recordingLevel(session.id) }) {
            guard model.hoveredSession?.id == session.id else { return }
            performAction(session.id, action)
        }
    }

    private func noteActionButton(_ action: SessionWheelNoteAction) -> some View {
        submenuButton(index: action.rawValue, slot: SessionWheelShortcut.noteTaker.rawValue,
                      title: action.title(for: model.notePhase), help: action.caption(for: model.notePhase),
                      symbol: action.symbol(for: model.notePhase), enabled: action.isEnabled(for: model.notePhase),
                      hovered: model.hoveredNoteAction == action, destructive: action == .cancel) {
            guard model.isHoveringNoteTaker else { return }
            performNoteAction(action)
        }
    }

    private var intensitySlider: some View {
        let slot = SessionWheelIntensity.slot
        let enabled = model.particleFieldEnabled
        let value = model.particleIntensity
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isEnabled: enabled,
            isHovered: model.hoveredSettingsControl == .intensity || model.isAdjustingIntensity,
            reduceMotion: reduceMotion
        )
        let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                       outerRadius: geometry.actionOuterRadius,
                                       subdivision: SessionWheelSettingsControl.intensity.rawValue,
                                       span: SessionWheelSettingsControl.intensity.span,
                                       subdivisions: SessionWheelSettingsControl.subdivisionCount)
        let thumb = SessionWheelIntensity.angle(for: value)
        let highEnd = CGFloat(slot) * geometry.sliceAngle
        let lowEnd = highEnd + geometry.sliceAngle * 2 / 3
        // The value sits in the larger side of the thumb, so the two never overlap.
        let edge = geometry.segmentGap / geometry.actionRadius
        let labelAngle = value >= 0.55 ? (thumb + lowEnd - edge) / 2 : (thumb + highEnd + edge) / 2
        let labelOffset = labelAngle - highEnd - geometry.sliceAngle / 2
        let percent = SessionWheelIntensity.percent(value)
        let foreground = enabled ? ProgramBoardStyle.primaryText
            : (contrast == .increased ? ProgramBoardStyle.disabledText : ProgramBoardStyle.mutedText.opacity(0.5))
        return ZStack {
            controlBackground(shape, presentation: presentation)
            // The Settings slider's value fill: hovering or dragging shimmers
            // the filled part with the Settings sidebar's dots.
            shape.fill(SettingsSlider.fillColor(contrast: contrast, isEnabled: enabled))
                .background(FluxDotsBackground(
                    cornerRadius: 0,
                    style: .standard,
                    isVisible: enabled && (model.hoveredSettingsControl == .intensity || model.isAdjustingIntensity)
                ).clipShape(shape))
                .mask(SessionWheelWedge(from: value >= SessionWheelIntensity.range.upperBound ? highEnd : thumb,
                                       to: lowEnd))
            SessionWheelThumb(angle: thumb)
                .stroke(foreground, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            // The value sits on the fill from 55%, where it turns dark like the Settings slider's.
            Text(percent)
                .font(AppTypography.font(.caption))
                .monospacedDigit()
                .foregroundStyle(value >= 0.55 ? SettingsSlider.onFillColor(isEnabled: enabled)
                                 : (enabled ? ProgramBoardStyle.mutedText : foreground))
                .frame(width: 40, height: geometry.actionLabelSize.height)
                .rotationEffect(.radians(geometry.labelRotation(slot: slot, offset: labelOffset)))
                .position(geometry.position(slot: slot, radius: geometry.actionRadius, offset: labelOffset))
        }
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpace))
            .onChanged { adjustIntensity($0.location) }
            .onEnded { finishIntensity($0.location) })
        .allowsHitTesting(enabled)
        .animation(presentation.animation, value: presentation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Particle intensity")
        .accessibilityValue(AwarenessSettingsTab.particleIntensityAccessibilityValue(value))
        .accessibilityHint(enabled ? "Drag along the arc to adjust" : "Turn on Particle field in Settings to adjust")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: stepIntensity(1)
            case .decrement: stepIntensity(-1)
            @unknown default: break
            }
        }
        .notchHint(enabled ? "Particles \(percent)" : "Particles off")
    }

    private var keepAwakeButton: some View {
        let state = model.keepAwake
        return submenuButton(index: SessionWheelSettingsControl.keepAwake.rawValue, slot: SessionWheelIntensity.slot,
                             title: state.isPending ? state.status : state.actionTitle,
                             help: state.shortStatus,
                             symbol: SessionWheelKeepAwakeGlyph.Look(state).symbol,
                             // Pending stays legible; the controller ignores clicks until it settles.
                             enabled: true, hovered: model.hoveredSettingsControl == .keepAwake && !state.isPending,
                             destructive: false, keepAwake: state,
                             subdivisions: SessionWheelSettingsControl.subdivisionCount) {
            guard model.isHoveringSettings else { return }
            performKeepAwake()
        }
    }

    private var autoPlayButton: some View {
        submenuButton(index: SessionWheelSettingsControl.autoPlay.rawValue, slot: SessionWheelIntensity.slot,
                      title: model.autoPlayActionTitle,
                      help: model.autoPlay ? "Autoplay on" : "Autoplay off",
                      symbol: "forward.fill", enabled: true,
                      hovered: model.hoveredSettingsControl == .autoPlay,
                      destructive: false, isOn: model.autoPlay,
                      subdivisions: SessionWheelSettingsControl.subdivisionCount) {
            guard model.isHoveringSettings else { return }
            performAutoPlay()
        }
        .accessibilityValue(model.autoPlay ? "On" : "Off")
    }

    private func submenuButton(index: Int, slot: Int, title: String, help: String, symbol: String,
                               enabled: Bool, hovered: Bool, destructive: Bool,
                               keepAwake: KeepAwakeState? = nil,
                               isOn: Bool? = nil, subdivisions: Int = 3,
                               level: @escaping () -> Float = { 0 }, perform: @escaping () -> Void) -> some View {
        let isNoteMark = symbol == "checkmark" || symbol == "xmark"
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isEnabled: enabled,
            isHovered: hovered,
            reduceMotion: reduceMotion
        )
        let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                       outerRadius: geometry.actionOuterRadius, subdivision: index, subdivisions: subdivisions)
        let offset = geometry.actionOffset(index, subdivisions: subdivisions)
        return Button(action: perform) {
            ZStack {
                controlBackground(shape, presentation: presentation)
                Group {
                    if let keepAwake {
                        SessionWheelKeepAwakeGlyph(state: keepAwake)
                            .font(AppTypography.symbolFont(size: 9, weight: .medium))
                    } else if symbol == "waveform" {
                        SessionWheelRecordingWaveform(level: level)
                    } else if symbol == "power" {
                        Image(systemName: symbol)
                            .resizable().scaledToFit()
                            .frame(width: 10, height: 10)
                    } else {
                        Image(systemName: symbol)
                            // Two filled triangles need a smaller size to balance the slender bolt.
                            .font(AppTypography.symbolFont(size: isNoteMark ? 11 : symbol == "forward.fill" ? 7 : 9,
                                                           weight: isNoteMark ? .bold : .medium))
                    }
                }
                .contentTransition(.opacity)
                .animation(RelayMotion.change(reduceMotion: reduceMotion), value: symbol)
                .frame(width: geometry.actionLabelSize.width, height: geometry.actionLabelSize.height)
                .foregroundStyle(!enabled
                                 ? (contrast == .increased ? GraphicalTheme.neutral7 : GraphicalTheme.neutral6) // Kit disabled label
                                 : destructive ? ProgramBoardStyle.red
                                 : isOn.map { $0 ? ProgramBoardStyle.activeTrayOrange : .white } ?? ProgramBoardStyle.primaryText)
                .animation(RelayMotion.change(reduceMotion: reduceMotion), value: isOn)
                .rotationEffect(.radians(geometry.labelRotation(slot: slot, offset: offset)))
                .position(geometry.position(slot: slot, radius: geometry.actionRadius, offset: offset))
            }
            .contentShape(shape)
        }
        .buttonStyle(SessionWheelActionButtonStyle())
        .disabled(!enabled)
        .animation(presentation.animation, value: presentation)
        .accessibilityLabel(title)
        .notchHint(help)
    }

    private var hub: some View {
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isHovered: hubHovered, reduceMotion: reduceMotion
        )
        let title = "Close"
        let detail = model.notice ?? model.startUnavailableReason ?? ""
        return Button(action: selectCenter) {
            SessionWheelCloseGlyph()
                .frame(width: geometry.hubRadius * 2, height: geometry.hubRadius * 2)
                .background(controlBackground(Circle(), presentation: presentation))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .notchHint(model.notice ?? title)
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
    /// Adjacent subdivisions joined into one control.
    var span = 1
    var subdivisions = 3

    func path(in rect: CGRect) -> Path {
        let innerRadius = self.innerRadius - padding
        let outerRadius = self.outerRadius + padding
        let step = 2 * CGFloat.pi / CGFloat(SessionWheelGeometry.slotCount)
        let subdivisionWidth = step / CGFloat(subdivisions)
        let width = subdivision == nil ? step : subdivisionWidth * CGFloat(span)
        let halfGap = SessionWheelGeometry.segmentGap / 2 - padding
        let start = CGFloat(slot) * step - .pi / 2 - step / 2 + CGFloat(subdivision ?? 0) * subdivisionWidth
        let end = start + width
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let corner = min((cornerRadius ?? (subdivision == nil ? SessionWheelGeometry.segmentCornerRadius
                                                             : SessionWheelGeometry.actionCornerRadius)) + padding,
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

/// A pie slice between two `SessionWheelGeometry.angle(at:)` angles, used to mask the slider fill.
struct SessionWheelWedge: Shape {
    let from: CGFloat
    let to: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let offset = -CGFloat.pi / 2 - SessionWheelGeometry.sliceAngle / 2
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: max(rect.width, rect.height), startAngle: .radians(min(from, to) + offset),
                    endAngle: .radians(max(from, to) + offset), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// The slider's radial thumb, inset from both edges of the outer arc.
struct SessionWheelThumb: Shape {
    let angle: CGFloat

    func path(in rect: CGRect) -> Path {
        let geometry = SessionWheelGeometry.self
        let screen = angle - .pi / 2 - geometry.sliceAngle / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * cos(screen), y: center.y + radius * sin(screen))
        }
        var path = Path()
        path.move(to: point(geometry.actionInnerRadius + 7))
        path.addLine(to: point(geometry.actionOuterRadius - 7))
        return path
    }
}


