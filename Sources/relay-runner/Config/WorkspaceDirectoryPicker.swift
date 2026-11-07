import AppKit
import Foundation

enum WorkspaceDirectoryPicker {
    static func pick(
        message _: String,
        onPrepareExternalWindow: (@escaping () -> Void) -> Void,
        chooseDirectory: @escaping () -> URL?,
        completion: @escaping (String?) -> Void
    ) {
        onPrepareExternalWindow {
            completion(chooseDirectory()?.path)
        }
    }

    /// Single entry point for every AppKit file/folder chooser in the app.
    /// Order: hide the Workspace, activate the app, present, restore.
    static func present<Result>(
        hideWorkspace: (@escaping () -> Void) -> Void,
        activate: @escaping () -> Void = { NSApplication.shared.activate(ignoringOtherApps: true) },
        presentPanel: @escaping () -> Result,
        restoreWorkspace: @escaping (Result) -> Void
    ) {
        hideWorkspace {
            activate()
            restoreWorkspace(presentPanel())
        }
    }

    static func runAppKitDirectoryPanel(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        return runAppKitPanel(panel)
    }

    /// Image chooser used by ticket attachments; shares the placement rules.
    static func runAppKitImagePanel(message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = message
        return runAppKitPanel(panel) == nil ? [] : panel.urls
    }

    static func runAppKitPanel(_ panel: NSSavePanel) -> URL? {
        NSApplication.shared.activate(ignoringOtherApps: true)
        placeOnActiveDisplay(panel)
        panel.level = .screenSaver
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Centers the panel on the display holding the pointer, falling back to
    /// the key window's screen.
    private static func placeOnActiveDisplay(_ panel: NSSavePanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSApp.keyWindow?.screen
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }
}
