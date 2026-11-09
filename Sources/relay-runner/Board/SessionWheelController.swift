import AppKit
import SwiftUI

final class SessionWheelController {
    let model = SessionWheelModel()
    let haptics: SessionWheelHaptics
    var refresh: ((SessionWheelModel) -> Void)?
    var focusSession: ((String) -> Void)?
    /// RR-445: starts the one general session.
    var startSession: (() -> Bool)?
    /// RR-469: a session submenu segment: a tab to make active, or a tab control.
    var tabAction: ((SessionWheelSessionItem) -> Bool)?
    var openShortcut: ((SessionWheelShortcut) -> Void)?
    var noteAction: ((SessionWheelNoteAction) -> Bool)?
    /// Live particle preview while dragging; `commitIntensity` persists the final value.
    var previewIntensity: ((Double) -> Void)?
    var commitIntensity: ((Double) -> Void)?
    /// True while the slider is hovered or dragged: shows the message-playback particles.
    var previewParticles: ((Bool) -> Void)?
    var keepAwakeAction: (() -> Bool)?
    var autoPlayAction: (() -> Bool)?

    private var panel: SessionWheelPanel?
    private let motion = SessionWheelMotion()
    private var motionCompletion: DispatchWorkItem?
    private var motionGeneration = 0
    private var monitors: [Any] = []
    private var refreshTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var sleepObservers: [NSObjectProtocol] = []
    private(set) var isVisible = false
    private(set) var isPreviewingParticles = false

    init(haptics: SessionWheelHaptics = SessionWheelHaptics()) {
        self.haptics = haptics
    }

    func toggle() {
        if isVisible { dismiss(); return }
        if let panel {
            // Reuse the closing panel so a rapid reopen reverses in place.
            present(panel)
            return
        }
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else { return }
        let panel = makePanel()
        self.panel = panel
        panel.setFrame(SessionWheelGeometry.frame(at: cursor, visibleFrame: screen.visibleFrame), display: false)
        let size = panel.frame.width
        let view = SessionWheelAnimatedView(motion: motion) { [model, weak self] presentation in
            SessionWheelView(
                model: model,
                selectSlot: { [weak self] index, fromPointer in self?.selectSlot(index, fromPointer: fromPointer) },
                performTabItem: { [weak self] in self?.performTabItem($0) },
                selectCenter: { [weak self] in self?.selectCenter() },
                dismiss: { [weak self] in self?.dismiss() },
                performNoteAction: { [weak self] in self?.performNoteAction($0) },
                hoverFeedback: { [weak self] point, target in self?.hoverFeedback(at: point, target: target) },
                adjustIntensity: { [weak self] in self?.adjustIntensity(to: $0) },
                finishIntensity: { [weak self] in self?.finishIntensity(at: $0) },
                stepIntensity: { [weak self] in self?.stepIntensity($0) },
                performKeepAwake: { [weak self] in self?.performKeepAwake() },
                performAutoPlay: { [weak self] in self?.performAutoPlay() },
                presentation: presentation
            )
        }.scaleEffect(size / SessionWheelGeometry.diameter).frame(width: size, height: size)
        panel.contentView = SessionWheelHostingView(rootView: view)
        refresh?(model)
        model.reset(at: pointerLocation)
        present(panel)
    }

    private func present(_ panel: SessionWheelPanel) {
        isVisible = true
        haptics.reset(at: pointerLocation)
        panel.ignoresMouseEvents = false
        installMonitors()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh?(self.model)
            self.syncParticlePreview()
        }
        animate(visible: true, panel: panel)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        guard isVisible else { return }
        finishIntensity(confirm: false)
        isVisible = false
        syncParticlePreview()
        refreshTimer?.invalidate()
        refreshTimer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObservers.removeAll()
        if let panel {
            panel.ignoresMouseEvents = true
            animate(visible: false, panel: panel)
        }
    }

    private func animate(visible: Bool, panel: SessionWheelPanel) {
        motionCompletion?.cancel()
        motionGeneration += 1
        let generation = motionGeneration
        let duration = motion.setVisible(visible,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            at: ProcessInfo.processInfo.systemUptime)
        let completion = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.motionGeneration == generation, self.panel === panel else { return }
            self.motion.finish()
            self.motionCompletion = nil
            if !self.isVisible {
                panel.orderOut(nil)
                self.panel = nil
            }
        }
        motionCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: completion)
    }

    deinit {
        motionCompletion?.cancel()
        refreshTimer?.invalidate()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        panel?.orderOut(nil)
    }

    private var pointerLocation: CGPoint {
        guard let panel else { return SessionWheelGeometry.center }
        let cursor = NSEvent.mouseLocation
        let scale = SessionWheelGeometry.diameter / panel.frame.width
        return CGPoint(x: (cursor.x - panel.frame.minX) * scale, y: (panel.frame.maxY - cursor.y) * scale)
    }

    func hoverFeedback(at point: CGPoint?, target: SessionWheelHaptics.Target?) {
        syncParticlePreview()
        guard isVisible else { return }
        haptics.hover(target, at: point)
    }

    /// The centre closes the wheel.
    func selectCenter() {
        guard isVisible else { return }
        haptics.activate()
        dismiss()
    }

    func selectSlot(_ index: Int, fromPointer: Bool) {
        guard isVisible, model.slots.indices.contains(index) else { return }
        if let shortcut = model.shortcut(at: index) {
            if let openShortcut {
                openShortcut(shortcut)
                haptics.activate()
            }
            refresh?(model)
            panel?.orderFrontRegardless()
            return
        }
        if let session = model.slots[index] {
            if let focusSession {
                focusSession(session.id)
                haptics.activate()
            }
            refresh?(model)
            panel?.orderFrontRegardless()
        } else if model.isStartSlot(index), model.canStartSession {
            if startSession?() == true {
                haptics.activate()
                model.reset(at: pointerLocation)
                refresh?(model)
            }
            else { model.notice = "Couldn't start session" }
        }
    }

    /// The wheel stays open, so several tabs can be added or switched in a row.
    func performTabItem(_ item: SessionWheelSessionItem) {
        guard isVisible, model.slots.contains(where: { $0 != nil }), model.isEnabled(item) else { return }
        guard tabAction?(item) == true else {
            model.notice = item == .control(.add) ? model.addTabUnavailableReason ?? "Couldn't add a tab" : "Tab action unavailable"
            return
        }
        model.notice = nil
        haptics.activate()
        refresh?(model)
        panel?.orderFrontRegardless()
    }

    func performNoteAction(_ action: SessionWheelNoteAction) {
        guard isVisible, action.isEnabled(for: model.notePhase) else { return }
        guard noteAction?(action) == true else {
            model.notice = "Notetaker action unavailable"
            return
        }
        model.notice = nil
        haptics.activate()
        refresh?(model)
        panel?.orderFrontRegardless()
    }

    func adjustIntensity(to point: CGPoint) {
        guard isVisible, model.particleFieldEnabled else { return }
        let previous = model.particleIntensity
        let value = model.adjustIntensity(to: point)
        if value != previous { previewIntensity?(value) }
        syncParticlePreview()
    }

    /// One confirmation per drag, never per step; dismissal mid-drag still saves silently.
    /// The release point resumes hover, so the preview ends when released off the slider.
    func finishIntensity(at point: CGPoint? = nil, confirm: Bool = true) {
        guard model.isAdjustingIntensity else { return }
        model.endAdjustingIntensity()
        if let point { model.hover(at: point) }
        commitIntensity?(model.particleIntensity)
        if confirm { haptics.activate() }
        syncParticlePreview()
    }

    /// Reports only changes, so repeated hover ticks never restart the entrance.
    private func syncParticlePreview() {
        let previewing = isVisible && model.isPreviewingIntensity
        guard previewing != isPreviewingParticles else { return }
        isPreviewingParticles = previewing
        previewParticles?(previewing)
    }

    func stepIntensity(_ direction: Int) {
        guard isVisible, model.particleFieldEnabled else { return }
        let value = SessionWheelIntensity.quantized(model.particleIntensity + Double(direction) * SessionWheelIntensity.step)
        guard value != model.particleIntensity else { return }
        model.particleIntensity = value
        previewIntensity?(value)
        commitIntensity?(value)
        haptics.activate()
    }

    func performKeepAwake() {
        guard isVisible, !model.keepAwake.isPending else { return }
        guard keepAwakeAction?() == true else {
            model.notice = "Keep Awake unavailable"
            return
        }
        model.notice = nil
        haptics.activate()
        refresh?(model)
        panel?.orderFrontRegardless()
    }

    func performAutoPlay() {
        guard isVisible else { return }
        guard autoPlayAction?() == true else {
            model.notice = "Voice auto-play unavailable"
            return
        }
        model.notice = nil
        haptics.activate()
        refresh?(model)
        panel?.orderFrontRegardless()
    }

    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in self?.dismiss() }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            guard let self, self.isVisible else { return event }
            // Escape is consumed; only the toggle or the centre closes the wheel.
            if event.type == .keyDown, event.keyCode == 53 { return nil }
            if event.type != .keyDown, event.window !== self.panel { self.dismiss() }
            return event
        }) { monitors.append(monitor) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.dismiss() }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.dismiss() })
        }
    }

    private func makePanel() -> SessionWheelPanel {
        let panel = SessionWheelPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
        // Workspace tabs can retake keyboard focus after a wheel shortcut returns.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        return panel
    }
}

private final class SessionWheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SessionWheelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
