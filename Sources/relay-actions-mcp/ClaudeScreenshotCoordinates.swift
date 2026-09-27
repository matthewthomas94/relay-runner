import Foundation

// Claude Code re-encodes MCP images to fit 2000x2000, so relay-vision hands
// `claude-code` clients a screenshot downscaled by a stated `screenshot_scale`
// (image pixels per native pixel). Claude passes that scale back with
// click/scroll; this maps image-space x/y to the native pixels the app-hosted
// input path already expects, so the app's pixel-to-point conversion is
// unchanged. Other clients never reach this code.
enum ClaudeScreenshotCoordinates {
    static let tools: Set<String> = ["click", "scroll"]

    /// The tool's schema with a required `screenshot_scale` property.
    static func schema(adding base: [String: Any]) -> [String: Any] {
        var schema = base
        var properties = base["properties"] as? [String: Any] ?? [:]
        properties["screenshot_scale"] = [
            "type": "number",
            "description": "The screenshot_scale stated by the screenshot x/y were read from "
                + "(image pixels per native pixel, 0 < scale <= 1). Use 1 for native-pixel "
                + "coordinates such as list_windows frames.",
        ]
        schema["properties"] = properties
        schema["required"] = (base["required"] as? [String] ?? []) + ["screenshot_scale"]
        return schema
    }

    /// Maps an image pixel to the native pixel under its centre.
    static func nativeCoordinate(_ value: Int, scale: Double) -> Int {
        Int(((Double(value) + 0.5) / scale).rounded(.down))
    }

    /// Returns the arguments with x/y in native pixels and `screenshot_scale`
    /// removed, so the hosted request matches the non-Claude shape. Missing
    /// x/y are left for the tool's own validation error.
    static func nativeArguments(tool: String, _ arguments: [String: Any]) throws -> [String: Any] {
        guard let x = arguments["x"] as? Int, let y = arguments["y"] as? Int else { return arguments }
        guard let scale = (arguments["screenshot_scale"] as? NSNumber)?.doubleValue,
              scale > 0, scale <= 1 else {
            throw MCPToolError(message: """
                \(tool) requires screenshot_scale (0 < scale <= 1): pass the screenshot_scale stated by the \
                screenshot you read x/y from, or 1 for native-pixel coordinates.
                """)
        }
        var mapped = arguments
        mapped["x"] = nativeCoordinate(x, scale: scale)
        mapped["y"] = nativeCoordinate(y, scale: scale)
        mapped.removeValue(forKey: "screenshot_scale")
        return mapped
    }
}
