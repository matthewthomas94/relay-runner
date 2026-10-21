import AppKit
import SwiftUI

/// A child panel keeps dropdowns above scrolling Settings content without native popover chrome.
struct SettingsDropdownPresenter<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> SettingsDropdownAnchorView { SettingsDropdownAnchorView() }

    func updateNSView(_ view: SettingsDropdownAnchorView, context: Context) {
        if isPresented {
            view.present(AnyView(content)) { isPresented = false }
        } else {
            view.hide()
        }
    }

    static func dismantleNSView(_ view: SettingsDropdownAnchorView, coordinator: ()) {
        view.hide(animated: false)
    }
}

final class SettingsDropdownAnchorView: NSView, NSWindowDelegate {
    private var panel: SettingsDropdownPanel?
    private var eventMonitor: Any?
    private var onDismiss: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hide(animated: false) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionPanel()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        positionPanel()
    }

    func present(_ content: AnyView, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        if let hosting = panel?.contentView as? NSHostingView<AnyView> {
            hosting.rootView = content
            positionPanel()
            return
        }
        guard let window else { return }
        let hosting = NSHostingView(rootView: content)
        let panel = SettingsDropdownPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.level = window.level
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
        positionPanel()
        window.addChildWindow(panel, ordered: .above)
        RelayWindowMotion.present(panel)
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            guard let self, let panel = self.panel, event.window !== panel else { return event }
            // A second click on the field closes it instead of closing and immediately reopening it.
            let clickedField = event.type != .scrollWheel && event.window === self.window
                && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            self.dismiss()
            return clickedField ? nil : event
        }
    }

    private func positionPanel() {
        guard let panel, let window else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let gap: CGFloat = 8
        var origin = NSPoint(x: anchor.maxX - panel.frame.width, y: anchor.minY - gap - panel.frame.height)
        if let visible = window.screen?.visibleFrame, visible.intersects(anchor) {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - panel.frame.width)
            if origin.y < visible.minY { origin.y = anchor.maxY + gap }
            origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
        }
        panel.setFrameOrigin(origin)
    }

    func windowDidResignKey(_ notification: Notification) { dismiss() }

    private func dismiss() {
        let callback = onDismiss
        hide()
        callback?()
    }

    func hide(animated: Bool = true) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        onDismiss = nil
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow { window?.makeKey() }
        let close = {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if animated {
            RelayWindowMotion.dismiss(panel, completion: close)
        } else {
            close()
        }
    }
}

private final class SettingsDropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
