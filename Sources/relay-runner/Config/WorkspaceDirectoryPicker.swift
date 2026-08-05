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

    static func runAppKitDirectoryPanel(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        return runAppKitPanel(panel)
    }

    static func runAppKitPanel(_ panel: NSSavePanel) -> URL? {
        NSApplication.shared.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
