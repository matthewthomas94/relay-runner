import AppKit
import CoreGraphics
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

        // Pre-flight: if Screen Recording isn't granted yet, ask now. TCC walks
        // the responsibility chain, so this prompt fires for the terminal/IDE
        // that spawned `claude` — not for relay-actions-mcp itself. If the
        // status is .notDetermined this surfaces a system dialog the user can
        // act on. If it's .denied this is a no-op (TCC remembers and won't
        // re-prompt; only Settings can flip the toggle).
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            // SCShareableContent failed. Two real reasons:
            //  (a) user just got prompted and dismissed/denied
            //  (b) status is .denied from a previous session
            // Either way, re-trigger the prompt one more time so a user who
            // changed their mind gets another chance, then describe exactly
            // which app needs the grant.
            _ = CGRequestScreenCaptureAccess()

            let blockerName = ParentProcess.detectTerminal()?.displayName
                ?? "the app you launched `claude` from"
            throw MCPToolError(message: """
                Could not capture the screen. Screen Recording permission is not granted.

                IMPORTANT: macOS attributes screen capture to the app that launched \
                `claude`, NOT to Relay Runner. You need to grant Screen Recording to \
                **\(blockerName)**.

                If you just saw a system prompt and dismissed it, try again — I just \
                re-requested. If no prompt appeared, you previously denied it and macOS \
                won't ask again until you grant it manually:

                1. Open System Settings → Privacy & Security → Screen Recording
                2. Toggle on \(blockerName)
                3. Quit and relaunch \(blockerName) (the permission only takes effect on relaunch)
                4. Restart your `claude` session

                Without this permission, every screenshot, click, and computer-vision \
                request I make will fail. Voice transcription and speech still work.

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
