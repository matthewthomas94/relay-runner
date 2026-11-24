import SwiftUI

struct SessionWheelView: View {
    @Bindable var model: SessionWheelModel
    let selectSlot: (Int, Bool) -> Void
    let performAgentAction: (SessionWheelAgentAction) -> Void
    let selectCenter: () -> Void
    let dismiss: () -> Void
    var performNoteAction: (SessionWheelNoteAction) -> Void = { _ in }
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
    @State private var hintOwner = UUID()
    @State var menuMotion = SessionWheelMenuMotion()

    private let geometry = SessionWheelGeometry.self
    static let coordinateSpace = "session-wheel"
    /// The submenu arc's Lucide icons, sized to read inside its narrow sectors.
    static let submenuIconSize: CGFloat = 12
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
            // Pure black, like the notch and the recording pill; the glass is on the tiles.
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
                        .compositingGroup()
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
                        .compositingGroup()
                        .scaleEffect(frame.scale)
                        .opacity(frame.controlsOpacity)
                        .allowsHitTesting(model.isHoveringSettings && (reduceMotion || frame.progress >= 0.95))
                        .accessibilityHidden(!model.isHoveringSettings)
                        .transition(.identity)
                        .transaction { $0.animation = nil }
                    } else if index == geometry.sessionSlots[0], frame.progress > 0 {
                        let items = model.sessionItems
                        ZStack {
                            ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                                agentItemButton(item, index: position, slot: index)
                            }
                            // Above the segments, so a click on the glyph takes its own action.
                            ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                                agentGlyphButton(item, index: position)
                            }
                        }
                        .compositingGroup()
                        .scaleEffect(frame.scale)
                        .opacity(frame.controlsOpacity)
                        .allowsHitTesting(model.isHoveringSession && (reduceMotion || frame.progress >= 0.95))
                        .accessibilityHidden(!model.isHoveringSession)
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
                updateHint(at: point)
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
                NotchHoverDescriptor.hide(owner: hintOwner)
                hoverFeedback(nil, nil)
            }
        }
        .onDisappear { NotchHoverDescriptor.hide(owner: hintOwner) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session wheel")
    }

    /// Names the hovered segment or outer control in the notch.
    private func updateHint(at point: CGPoint) {
        if let hint = model.hoverDescriptor(at: point) {
            NotchHoverDescriptor.show(hint, owner: hintOwner)
        } else {
            NotchHoverDescriptor.hide(owner: hintOwner)
        }
    }

    private func slot(_ index: Int, menu: SessionWheelMenu) -> some View {
        let session = menu.sessions[index]
        let shortcut = menu.shortcut(at: index)
        // Tiles show only their icon; the title names the tile to VoiceOver and
        // the notch names the action a click takes. RR-521: the session tile
        // always reads Terminal and never starts a session.
        let title = shortcut?.title ?? SessionWheelSessionSlot.title
        let sessionHint = "Open Workspace on the Terminal tab. Move outward to start, switch to or stop an agent."
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .projectCard,
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
                controlBackground(shape, presentation: presentation)
                LucideImage(shortcut?.symbol ?? SessionWheelSessionSlot.symbol, size: 20)
                    .position(geometry.position(slot: index, radius: 119))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .animation(presentation.animation, value: presentation)
        .accessibilityLabel(session.map { "\(title), \($0.name)" } ?? title)
        .accessibilityHint(shortcut == .noteTaker
            ? "Open Notetaker. Move outward for recording controls."
            : shortcut == .settings ? "Open Settings. Move outward for particle intensity, Keep Awake and voice auto-play."
            : shortcut != nil ? "Open \(title)" : sessionHint)
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
            if shortcut == nil {
                // RR-521: each agent's label and glyph, named as the notch names
                // them. A stopped agent's label and plus both start it, so it
                // has one action; the active agent has nothing to switch to.
                ForEach(model.sessionItems) { item in
                    if !item.isActive, model.isEnabled(item.labelAction) {
                        Button(item.labelAction.title) { performAgentAction(item.labelAction) }
                    }
                    if item.glyphAction != item.labelAction {
                        Button(item.glyphAction.title) { performAgentAction(item.glyphAction) }
                    }
                }
            }
        }
    }

    /// The active agent's label is orange, another running agent's is the
    /// primary text colour and a stopped agent's is grey. The plus and the X
    /// are always the primary text colour.
    static func agentLabelColor(_ item: SessionWheelAgent) -> Color {
        if item.isActive { return ProgramBoardStyle.activeTrayOrange }
        return item.isRunning ? ProgramBoardStyle.primaryText : ProgramBoardStyle.mutedText
    }

    /// RR-521: an agent segment shows its two-letter label then its plus or X.
    private func agentItemButton(_ item: SessionWheelAgent, index: Int, slot: Int) -> some View {
        let action = item.labelAction
        return submenuButton(index: index, slot: slot, title: action.title, help: model.caption(for: action),
                             symbol: nil, enabled: true,
                             hovered: model.hoveredSessionItem == item && model.hoveredGlyph == nil,
                             destructive: false,
                             labelGlyphs: geometry.sessionAgentLayout(index, label: item.label).glyphs,
                             selected: item.isActive, labelColor: Self.agentLabelColor(item),
                             attention: item.needsAttention,
                             arc: geometry.sessionItemArc(index)) {
            guard model.isHoveringSession else { return }
            performAgentAction(action)
        }
        .accessibilityValue(item.needsAttention ? "Needs attention" : "")
        .accessibilityAddTraits(item.isActive ? .isSelected : [])
    }

    /// The plus that starts a stopped agent, or the X that stops a running
    /// one, both in the primary text colour; the glyph swaps in place, and
    /// hovering fills a circle behind it.
    private func agentGlyphButton(_ item: SessionWheelAgent, index: Int) -> some View {
        let placement = geometry.sessionAgentLayout(index, label: item.label).glyph
        let hovered = model.hoveredGlyph == item
        let size = geometry.agentGlyphDiameter
        let action = item.glyphAction
        return Button {
            guard model.isHoveringSession else { return }
            performAgentAction(action)
        } label: {
            LucideImage(item.glyph, size: Self.submenuIconSize)
                .contentTransition(.opacity)
                .foregroundStyle(ProgramBoardStyle.primaryText)
                .animation(RelayMotion.change(reduceMotion: reduceMotion), value: item.isRunning)
                .frame(width: size, height: size)
                .background(Circle().fill(GraphicalTheme.neutral5).opacity(hovered ? 1 : 0))
                .animation(RelayMotion.change(reduceMotion: reduceMotion), value: hovered)
                .contentShape(Circle())
                .rotationEffect(.radians(placement.rotation))
        }
        .buttonStyle(SessionWheelActionButtonStyle())
        .position(placement.point)
        .accessibilityLabel(action.title)
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
        // The value fill is a glass cell of its own inside the track, rounded
        // at both ends and stopping short of the thumb. At full it takes the
        // whole track; too short to round, its corners tighten.
        let isFull = value >= SessionWheelIntensity.range.upperBound
        let fillFrom = isFull ? highEnd : thumb + 2 / geometry.actionRadius
        let fillLength = (lowEnd - fillFrom) * geometry.actionRadius - geometry.segmentGap
        let fillShape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                           outerRadius: geometry.actionOuterRadius,
                                           cornerRadius: min(SessionWheelGeometry.actionCornerRadius, max(0, fillLength / 2 - 0.5)),
                                           arcStart: fillFrom - highEnd - geometry.sliceAngle / 2,
                                           arcWidth: lowEnd - fillFrom)
        return ZStack {
            controlBackground(shape, presentation: presentation)
            // Hovering or dragging shimmers the fill with the Settings sidebar's dots.
            if fillLength > 2 {
                fillShape.fill(SettingsSlider.fillColor(contrast: contrast, isEnabled: enabled))
                    .background(FluxDotsBackground(
                        cornerRadius: 0,
                        style: .standard,
                        isVisible: enabled && (model.hoveredSettingsControl == .intensity || model.isAdjustingIntensity)
                    ).clipShape(fillShape))
                    .overlay(SessionWheelGlassRim(shape: fillShape, stops: BoardDarkSurfaceStyle.glassRimOnLightStops))
            }
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
            .onChanged {
                adjustIntensity($0.location)
                updateHint(at: $0.location)
            }
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
    }

    private var keepAwakeButton: some View {
        let state = model.keepAwake
        return submenuButton(index: SessionWheelSettingsControl.keepAwake.rawValue, slot: SessionWheelIntensity.slot,
                             title: state.isPending ? state.status : state.actionTitle,
                             help: state.hoverAction,
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
                      help: model.autoPlay ? "Turn off autoplay" : "Turn on autoplay",
                      symbol: .fastForward, enabled: true,
                      hovered: model.hoveredSettingsControl == .autoPlay,
                      destructive: false, isOn: model.autoPlay,
                      subdivisions: SessionWheelSettingsControl.subdivisionCount) {
            guard model.isHoveringSettings else { return }
            performAutoPlay()
        }
        .accessibilityValue(model.autoPlay ? "On" : "Off")
    }

    /// An agent segment passes `labelGlyphs` (its label set along the arc
    /// beside its glyph) and no symbol.
    private func submenuButton(index: Int, slot: Int, title: String, help: String, symbol: LucideIcon?,
                               enabled: Bool, hovered: Bool, destructive: Bool,
                               keepAwake: KeepAwakeState? = nil,
                               isOn: Bool? = nil, subdivisions: Int = 3,
                               labelGlyphs: [SessionWheelGeometry.Glyph]? = nil,
                               selected: Bool = false, labelColor: Color? = nil,
                               attention: Bool? = nil,
                               arc: (start: CGFloat, width: CGFloat)? = nil,
                               perform: @escaping () -> Void) -> some View {
        let presentation = ProgramBoardInteractionPresentation.resolve(
            surface: .control, isEnabled: enabled,
            isSelected: selected,
            isHovered: hovered,
            reduceMotion: reduceMotion
        )
        let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                       outerRadius: geometry.actionOuterRadius, subdivision: index, subdivisions: subdivisions,
                                       arcStart: arc?.start, arcWidth: arc?.width)
        let offset = arc.map { $0.start + $0.width / 2 } ?? geometry.actionOffset(index, subdivisions: subdivisions)
        let foreground: Color = !enabled
            ? (contrast == .increased ? GraphicalTheme.neutral7 : GraphicalTheme.neutral6) // Kit disabled label
            : destructive ? ProgramBoardStyle.red
            : selected ? ProgramBoardStyle.activeTrayOrange
            : isOn.map { $0 ? ProgramBoardStyle.activeTrayOrange : .white } ?? ProgramBoardStyle.primaryText
        return Button(action: perform) {
            ZStack {
                controlBackground(shape, presentation: presentation)
                if let attention {
                    // An agent that wants attention shimmers, as its Workspace
                    // tab does, until it is switched to.
                    FluxDotsBackground(cornerRadius: 0, style: .standard, isVisible: attention)
                        .clipShape(shape)
                }
                if let labelGlyphs {
                    // The label curves with its cell: one shape of its letters'
                    // outlines, so no letter snaps to the pixel grid off the arc.
                    Path { path in labelGlyphs.forEach { path.addPath(Path($0.outline)) } }
                        .fill(labelColor ?? foreground)
                } else {
                    Group {
                        if let keepAwake {
                            SessionWheelKeepAwakeGlyph(state: keepAwake, size: Self.submenuIconSize)
                        } else if let symbol {
                            LucideImage(symbol, size: Self.submenuIconSize)
                        }
                    }
                    .contentTransition(.opacity)
                    .animation(RelayMotion.change(reduceMotion: reduceMotion), value: symbol)
                    .frame(width: geometry.actionLabelSize.width, height: geometry.actionLabelSize.height)
                    .foregroundStyle(foreground)
                    .animation(RelayMotion.change(reduceMotion: reduceMotion), value: isOn)
                    .rotationEffect(.radians(geometry.labelRotation(slot: slot, offset: offset)))
                    .position(geometry.position(slot: slot, radius: geometry.actionRadius, offset: offset))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(SessionWheelActionButtonStyle())
        .disabled(!enabled)
        .animation(presentation.animation, value: presentation)
        .accessibilityLabel(title)
        .accessibilityHint(help)
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
        .onHover { hubHovered = $0 }
    }

    private func controlBackground<S: Shape>(
        _ shape: S, presentation: ProgramBoardInteractionPresentation
    ) -> some View {
        // Glass tiles: the tile fill, lighter on hover or when selected, with
        // the rim drawn inside the tile's edge.
        shape
            .fill(presentation.usesHoverFill
                ? BoardDarkSurfaceStyle.wheelTileActiveFill : BoardDarkSurfaceStyle.wheelTileFill)
            .overlay(SessionWheelGlassRim(shape: shape, stops: BoardDarkSurfaceStyle.glassRimStops))
        .overlay {
            if contrast == .increased { shape.stroke(.white.opacity(0.55), lineWidth: 1) }
        }
        .animation(presentation.animation, value: presentation)
    }
}

/// A tile's glass edge. Wheel shapes are drawn in the whole wheel's frame, so
/// the highlight runs across the shape's own bounds, not the wheel's: every
/// tile catches the light at its top left wherever it sits.
private struct SessionWheelGlassRim<S: Shape>: View {
    let shape: S
    let stops: [Gradient.Stop]

    var body: some View {
        GeometryReader { proxy in
            let box = shape.path(in: CGRect(origin: .zero, size: proxy.size)).boundingRect
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            shape
                .stroke(
                    LinearGradient(
                        stops: stops,
                        startPoint: UnitPoint(x: box.minX / width, y: box.minY / height),
                        endPoint: UnitPoint(x: box.maxX / width, y: box.maxY / height)
                    ),
                    lineWidth: 2
                )
                .clipShape(shape)
        }
        .allowsHitTesting(false)
    }
}

private struct SessionWheelActionButtonStyle: ButtonStyle {
    // The wheel dims only the disabled icon, keeping the segment's fill intact.
    func makeBody(configuration: Configuration) -> some View { configuration.label }
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
    /// RR-469: an explicit arc relative to the slot's centre, for the session
    /// submenu's agent segments. Overrides the subdivision.
    var arcStart: CGFloat? = nil
    var arcWidth: CGFloat? = nil

    func path(in rect: CGRect) -> Path {
        let innerRadius = self.innerRadius - padding
        let outerRadius = self.outerRadius + padding
        let step = 2 * CGFloat.pi / CGFloat(SessionWheelGeometry.slotCount)
        let subdivisionWidth = step / CGFloat(subdivisions)
        let halfGap = SessionWheelGeometry.segmentGap / 2 - padding
        let width: CGFloat
        let start: CGFloat
        if let arcStart, let arcWidth {
            width = arcWidth
            start = CGFloat(slot) * step - .pi / 2 + arcStart
        } else {
            width = subdivision == nil ? step : subdivisionWidth * CGFloat(span)
            start = CGFloat(slot) * step - .pi / 2 - step / 2 + CGFloat(subdivision ?? 0) * subdivisionWidth
        }
        let end = start + width
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let corner = min((cornerRadius ?? (subdivision == nil && arcStart == nil ? SessionWheelGeometry.segmentCornerRadius
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


