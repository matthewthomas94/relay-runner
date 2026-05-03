import AppKit
import Foundation
import ScreenCaptureKit

struct ScreenshotTool: MCPTool {
    let name = "screenshot"
    let description = """
        Capture a screenshot of a connected display and return it as a base64-encoded PNG. \
        Defaults to the primary display. Coordinates returned by other tools (clicks, scrolls) \
        are in the same pixel space as this image. Returns an error string if Screen Recording \
        permission has not been granted.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "display_index": [
                    "type": "integer",
                    "description": "Zero-based index into the list of connected displays. Default: 0 (primary).",
                ],
            ],
            "required": [],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let displayIndex = arguments["display_index"] as? Int ?? 0

        let content: SCShareableContent
        do {
            // SCShareableContent triggers the Screen Recording TCC prompt the first time.
            // If denied it throws — translate to an MCP tool error so Claude speaks it
            // via TTS rather than crashing the server.
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            // TCC attributes the request to the *responsible* process — not Relay Runner,
            // because Relay Runner didn't spawn this MCP server. `claude` spawned it,
            // and `claude` was spawned by the user's terminal (or IDE). Walk up the
            // process tree and name the actual app the user needs to grant.
            let blockerName = ParentProcess.detectTerminal()?.displayName
                ?? "the app you launched `claude` from"
            throw MCPToolError(message: """
                Could not capture the screen. Screen Recording permission is missing.

                IMPORTANT: macOS attributes screen-capture permission to the app that \
                launched `claude`, NOT to Relay Runner. You almost certainly need to grant \
                Screen Recording to **\(blockerName)**, not Relay Runner.

                1. Open System Settings → Privacy & Security → Screen Recording
                2. Toggle on \(blockerName)
                3. Quit and relaunch \(blockerName) (the permission only takes effect on relaunch)
                4. Restart your `claude` session

                Granting Relay Runner the same permission is harmless and recommended for \
                future menu-bar-driven tools, but won't fix today's prompt.

                Underlying error: \(error.localizedDescription)
                """)
        }

        guard !content.displays.isEmpty else {
            throw MCPToolError(message: "No displays detected.")
        }

        guard displayIndex >= 0, displayIndex < content.displays.count else {
            throw MCPToolError(message: "display_index \(displayIndex) out of range (\(content.displays.count) display(s) connected)")
        }

        let display = content.displays[displayIndex]
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        // SCDisplay.width / .height are in pixels — using them gives a native-resolution
        // screenshot. Coordinates we hand back to Claude are in this same pixel space, which
        // means downstream click/scroll tools must convert pixels → CGEvent points before
        // posting (CGEvent is in the global display coordinate space, points).
        config.width = display.width
        config.height = display.height
        config.showsCursor = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw MCPToolError(message: "Screenshot capture failed: \(error.localizedDescription)")
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw MCPToolError(message: "Failed to encode screenshot as PNG.")
        }

        let base64 = pngData.base64EncodedString()

        return [
            [
                "type": "image",
                "data": base64,
                "mimeType": "image/png",
            ],
            // Send dimensions as a sibling text block so the model gets the pixel bounds without
            // having to inspect the image — useful for grounding click coordinates.
            [
                "type": "text",
                "text": "Captured display \(displayIndex) at \(display.width)×\(display.height) pixels.",
            ],
        ]
    }
}
