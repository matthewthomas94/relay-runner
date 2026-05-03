import AppKit
import Foundation

// Window introspection tools: frontmost_app, list_windows.
//
// Used by Claude to ground itself before clicking — knowing what app is in front
// and what windows are visible avoids the "click coordinate but the app changed
// underneath" failure mode common in vision-only loops.

struct FrontmostAppTool: MCPTool {
    let name = "frontmost_app"
    let description = """
        Return the name, bundle identifier, and PID of the currently focused application. \
        Useful before clicking to verify the expected app is in front.
        """

    var inputSchema: [String: Any] {
        ["type": "object", "properties": [String: Any](), "required": []]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw MCPToolError(message: "No frontmost application detected.")
        }
        let info: [String: Any] = [
            "name": app.localizedName ?? "unknown",
            "bundle_id": app.bundleIdentifier ?? "unknown",
            "pid": app.processIdentifier,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: json, encoding: .utf8) else {
            throw MCPToolError(message: "Failed to serialize frontmost app info.")
        }
        return [["type": "text", "text": str]]
    }
}

struct ListWindowsTool: MCPTool {
    let name = "list_windows"
    let description = """
        Enumerate on-screen windows. Returns app name, window title, frame in pixels (matching \
        the `screenshot` coordinate space), and whether the window is on screen. Hidden / \
        minimized windows are excluded by default.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "include_offscreen": [
                    "type": "boolean",
                    "description": "Include hidden / minimized windows. Default: false.",
                ],
            ],
            "required": [],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let includeOffscreen = arguments["include_offscreen"] as? Bool ?? false

        // CGWindowListCopyWindowInfo returns a snapshot of every window in the window
        // server's database. .optionOnScreenOnly filters to currently visible — combined
        // with .excludeDesktopElements that drops the wallpaper and other system surfaces.
        let options: CGWindowListOption = includeOffscreen
            ? [.excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw MCPToolError(message: "Failed to enumerate windows.")
        }

        // Convert each window's CGRect (point coordinates, top-left origin) to pixel
        // coordinates matching ScreenshotTool. Use the primary display's scale factor —
        // CGWindow geometry is in the same global coordinate space CGEvent uses.
        let primaryScale = NSScreen.screens.first?.backingScaleFactor ?? 1.0

        let windows: [[String: Any]] = raw.compactMap { entry in
            let appName = entry[kCGWindowOwnerName as String] as? String ?? "unknown"
            let title = entry[kCGWindowName as String] as? String ?? ""
            let onScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }

            let xPx = Int((bounds["X"] ?? 0) * primaryScale)
            let yPx = Int((bounds["Y"] ?? 0) * primaryScale)
            let wPx = Int((bounds["Width"] ?? 0) * primaryScale)
            let hPx = Int((bounds["Height"] ?? 0) * primaryScale)

            // Filter out the chrome of system surfaces — menubar, dock, notification center
            // overlays — by skipping zero-titled windows owned by 'Window Server' or 'Dock'.
            // Also drop tiny ornamental windows (≤ 5 px in either dimension) that clutter
            // the list without helping Claude.
            if (wPx <= 5 || hPx <= 5) && title.isEmpty { return nil }

            return [
                "app": appName,
                "title": title,
                "frame": ["x": xPx, "y": yPx, "width": wPx, "height": hPx],
                "on_screen": onScreen,
            ]
        }

        guard let json = try? JSONSerialization.data(withJSONObject: windows, options: [.prettyPrinted]),
              let str = String(data: json, encoding: .utf8) else {
            throw MCPToolError(message: "Failed to serialize window list.")
        }
        return [["type": "text", "text": str]]
    }
}
