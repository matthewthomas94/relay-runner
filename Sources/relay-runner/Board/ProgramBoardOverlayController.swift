import AppKit
import SwiftUI

/// Read-only Program Board overlay. Unlike `BoardOverlayController`, this
/// surface is not scoped to `ProjectResolver.resolve()` and never reads or
/// mutates the active project's `.orchestrator/` files directly.
final class ProgramBoardOverlayController {

    private var panel: BoardOverlayPanel?
    private(set) var isVisible = false
    private let model = ProgramBoardViewModel()
    private var themeResolver: (() -> ParticleFieldRenderer.Theme?)?
    private var themePollTimer: Timer?
    private var statusPollTimer: Timer?

    func setThemeResolver(_ resolver: @escaping () -> ParticleFieldRenderer.Theme?) {
        self.themeResolver = resolver
    }

    deinit {
        themePollTimer?.invalidate()
        statusPollTimer?.invalidate()
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }

        let p = panel ?? BoardOverlayPanel()
        if let screen = currentMouseScreen() {
            p.reframe(to: screen)
        }

        model.theme = themeResolver?()
        model.reload()

        let hosting = NSHostingView(rootView: ProgramBoardOverlayView(
            model: model,
            onDismiss: { [weak self] in self?.hide() },
            onRefresh: { [weak self] in self?.model.reload() }
        ))
        hosting.frame = p.frame
        hosting.autoresizingMask = [.width, .height]
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        p.contentView = hosting
        p.orderFrontRegardless()
        panel = p
        isVisible = true

        startThemePoll()
        startStatusPoll()
    }

    func hide() {
        guard isVisible else { return }
        stopThemePoll()
        stopStatusPoll()
        panel?.orderOut(nil)
        panel?.contentView = nil
        isVisible = false
    }

    private func startThemePoll() {
        stopThemePoll()
        themePollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let next = self.themeResolver?()
            if next != self.model.theme {
                self.model.theme = next
            }
        }
    }

    private func stopThemePoll() {
        themePollTimer?.invalidate()
        themePollTimer = nil
    }

    private func startStatusPoll() {
        stopStatusPoll()
        statusPollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.model.reload()
        }
    }

    private func stopStatusPoll() {
        statusPollTimer?.invalidate()
        statusPollTimer = nil
    }

    private func currentMouseScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        } ?? NSScreen.main
    }
}
