import AppKit
import SwiftUI

final class SessionWheelController {
    let model = SessionWheelModel()
    var refresh: ((SessionWheelModel, Bool) -> Void)?
    var focusSession: ((String) -> Void)?
    var startProject: ((String) -> Bool)?
    var sessionAction: ((String, SessionWheelAction) -> Bool)?
    var toggleWorkspace: (() -> Void)?

    private var panel: SessionWheelPanel?
    private var monitors: [Any] = []
    private var refreshTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var sleepObservers: [NSObjectProtocol] = []
    private(set) var isVisible = false

    func toggle() {
        if isVisible { dismiss(); return }
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else { return }
        let panel = makePanel()
        self.panel = panel
        panel.setFrame(SessionWheelGeometry.frame(at: cursor, visibleFrame: screen.visibleFrame), display: false)
        let size = panel.frame.width
        let view = SessionWheelView(
            model: model,
            selectSlot: { [weak self] index, fromPointer in self?.selectSlot(index, fromPointer: fromPointer) },
            performAction: { [weak self] id, action in self?.performAction(id, action) },
            selectCenter: { [weak self] in self?.selectCenter() },
            back: { [weak self] in self?.back() },
            dismiss: { [weak self] in self?.dismiss() }
        ).scaleEffect(size / SessionWheelGeometry.diameter).frame(width: size, height: size)
        panel.contentView = SessionWheelHostingView(rootView: view)
        refresh?(model, true)
        model.reset(at: pointerLocation)
        isVisible = true
        installMonitors()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh?(self.model, false)
        }
        RelayWindowMotion.present(panel, style: .element)
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
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
            RelayWindowMotion.dismiss(panel, style: .element)
        }
        panel = nil
    }

    private var pointerLocation: CGPoint {
        guard let panel else { return SessionWheelGeometry.center }
        let cursor = NSEvent.mouseLocation
        let scale = SessionWheelGeometry.diameter / panel.frame.width
        return CGPoint(x: (cursor.x - panel.frame.minX) * scale, y: (panel.frame.maxY - cursor.y) * scale)
    }

    private func back() {
        if !model.back(at: pointerLocation) { dismiss() }
    }

    func selectCenter() {
        guard isVisible else { return }
        if model.pickingProject {
            back()
        } else {
            dismiss()
            toggleWorkspace?()
        }
    }

    func selectSlot(_ index: Int, fromPointer: Bool) {
        guard isVisible, model.slots.indices.contains(index) else { return }
        if model.pickingProject {
            // Moving after entering a submenu prevents a double-click from
            // launching the project that inherited the parent's position.
            let isMouseEvent = NSApp.currentEvent.map { [.leftMouseDown, .leftMouseUp].contains($0.type) } ?? false
            guard !fromPointer || !isMouseEvent || model.hoveredSlot == index else { return }
            if model.isMoreProjectsSlot(index) {
                model.turnPage(1, at: pointerLocation)
                return
            }
            guard model.visibleProjects.indices.contains(index),
                  model.canStartSession else { return }
            let project = model.visibleProjects[index]
            guard project.isAvailable else { return }
            if startProject?(project.path) == true {
                model.reset(at: pointerLocation)
                refresh?(model, true)
            }
            else { model.notice = "Couldn't start session" }
        } else if let session = model.slots[index] {
            dismiss()
            focusSession?(session.id)
        } else {
            refresh?(model, true)
            model.showProjects(at: pointerLocation)
        }
    }

    func performAction(_ id: String, _ action: SessionWheelAction) {
        guard isVisible, let session = model.slots.compactMap({ $0 }).first(where: { $0.id == id }),
              action.isEnabled(for: session) else { return }
        guard sessionAction?(id, action) == true else {
            model.notice = "Action unavailable"
            return
        }
        model.notice = nil
        refresh?(model, true)
    }

    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in self?.dismiss() }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.back()
                return nil
            }
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
        panel.level = .screenSaver
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
