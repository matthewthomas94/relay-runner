import Foundation

// Relay Desktop tools. Each one maps a small typed schema onto one
// agent-desktop argv; Relay Runner.app validates and runs it. The result is the
// CLI's JSON envelope verbatim (`ok`, then `data` or `error` with `code`,
// `disposition` and usually a `suggestion`), so the agent reads refs, states
// and retry safety straight from the tool output.

/// Builds argv incrementally from tool arguments, skipping absent values.
struct ArgvBuilder {
    private(set) var argv: [String]

    init(_ subcommand: String) {
        argv = [subcommand]
    }

    mutating func positional(_ value: String) {
        argv.append(value)
    }

    mutating func option(_ flag: String, _ value: Any?) {
        guard let value else { return }
        switch value {
        case let string as String:
            guard !string.isEmpty else { return }
            argv.append(flag)
            argv.append(string)
        case let number as NSNumber:
            argv.append(flag)
            argv.append(number.stringValue)
        default:
            return
        }
    }

    mutating func toggle(_ flag: String, _ value: Any?, default defaultValue: Bool = false) {
        let enabled = (value as? Bool) ?? defaultValue
        if enabled { argv.append(flag) }
    }
}

/// Ref actions the hosted path accepts, and which of them take a value.
enum DesktopAction: String, CaseIterable {
    case click, rightClick = "right-click", type, setValue = "set-value", clear, focus, select,
         toggle, check, uncheck, expand, collapse, scroll, scrollTo = "scroll-to"

    var takesText: Bool {
        switch self {
        case .type, .setValue, .select: return true
        default: return false
        }
    }
}

struct DesktopTool: MCPTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    /// Seconds Relay Runner waits for the CLI before stopping it. The socket
    /// read timeout is this plus a margin so a slow wait never looks like a
    /// dead app host.
    let timeoutSeconds: ([String: Any]) -> Double
    let build: ([String: Any]) throws -> [String]

    /// Relay Runner's socket listener reads one request line of at most 8 KB.
    static let maxArgvBytes = 6 * 1024

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let argv = try build(arguments)
        let timeout = timeoutSeconds(arguments)
        return try DesktopTool.forward(tool: name, argv: argv, timeoutSeconds: timeout)
    }

    static func forward(tool: String, argv: [String], timeoutSeconds: Double) throws -> [[String: Any]] {
        let encoded = try? JSONSerialization.data(withJSONObject: argv)
        if (encoded?.count ?? 0) > maxArgvBytes {
            throw MCPToolError(message: "\(tool): the request is longer than \(maxArgvBytes / 1024) KB. Split long text into several calls.")
        }
        let forwarded: [String: Any] = [
            "argv": argv,
            "timeout_seconds": timeoutSeconds,
            "purpose": "read or operate an app through its accessibility tree (\(argv[0]))",
        ]
        switch ConfirmationClient.requestHostedTool(name: "desktop", arguments: forwarded, timeoutSeconds: Int(timeoutSeconds) + 10) {
        case .succeeded(let content):
            return content
        case .failed(let message):
            throw MCPToolError(message: message)
        case .menuBarUnavailable:
            throw MCPToolError(message: """
                Relay Runner is not running or its app-side tool host is unavailable. Start Relay Runner, then retry the \(tool) tool.
                """)
        }
    }
}

enum DesktopTools {
    static let defaultTimeout: Double = 60

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func choice(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    static let surfaces = ["window", "focused", "menu", "menubar", "sheet", "popover", "alert", "desktop", "toolbar", "dock", "spotlight", "notification-center", "menu-bar-extras"]

    private static let appProperty = string("Application name as shown by `list_apps` (e.g. 'Finder', 'Safari'). Omit for the focused app.")
    private static let windowIDProperty = string("Window id from `list_windows` (e.g. 'w-204749'). Required when the app has several windows (AMBIGUOUS_TARGET lists them).")
    private static let refProperty = string("Qualified ref from the latest snapshot or find, e.g. '@s8f3k2p9:e8'. Refs belong to their snapshot; take a new one after the UI changes.")
    private static let surfaceProperty = choice(surfaces, "Surface to read instead of the window: 'menubar' for File/Edit/View and menu-bar apps, 'menu', 'sheet', 'alert' or 'popover' while one is open. Default: window.")
    private static let waitForProperty = string("After acting, poll until an element matching this 'role:text' selector appears, then return that snapshot.")
    private static let waitForGoneProperty = string("After acting, poll until no element matches this 'role:text' selector, then return that snapshot.")
    private static let waitTimeoutProperty = integer("Maximum milliseconds for wait_for / wait_for_gone. Default: 30000.")

    private static func withWait(_ builder: inout ArgvBuilder, _ arguments: [String: Any]) {
        builder.option("--wait-for", arguments["wait_for"])
        builder.option("--wait-for-gone", arguments["wait_for_gone"])
        builder.option("--wait-timeout", arguments["wait_timeout_ms"])
    }

    private static func waitAwareTimeout(_ arguments: [String: Any]) -> Double {
        guard arguments["wait_for"] != nil || arguments["wait_for_gone"] != nil else { return defaultTimeout }
        let waitMilliseconds = (arguments["wait_timeout_ms"] as? NSNumber)?.doubleValue ?? 30_000
        return max(defaultTimeout, waitMilliseconds / 1000 + 15)
    }

    static let snapshot = DesktopTool(
        name: "snapshot",
        description: """
            Read an app's accessibility tree as JSON with a ref ('@<snapshot_id>:eN') for every element you can act \
            on. This is the first thing to call to learn what a window contains, what its controls, text, values and \
            states are, or before acting: it replaces a screenshot for everything except pixels. Defaults to \
            interactive elements only, compacted. For a dense app call with `skeleton` first, then drill into one \
            region with `root`. Pass `surface` while a menu, sheet, alert or popover is open. Refs are valid until the \
            UI changes; then snapshot again. Output can include private text from the app.
            """,
        inputSchema: schema([
            "app": appProperty,
            "window_id": windowIDProperty,
            "root": string("Start from this ref instead of the window root (drill into one region of an earlier snapshot)."),
            "surface": surfaceProperty,
            "skeleton": boolean("Shallow overview with children_count on cut branches. Default: false."),
            "interactive_only": boolean("Keep only elements that can be acted on. Default: true. Set false to read static text and labels."),
            "compact": boolean("Collapse single-child unnamed containers. Default: true."),
            "max_depth": integer("Maximum tree depth. Default: 10."),
            "include_bounds": boolean("Include each element's x, y, width, height in screen points. Default: false."),
            "timeout_ms": integer("Observation deadline in milliseconds. Default: 3000; raise for a very large window or a slow Chromium app."),
        ]),
        timeoutSeconds: { _ in defaultTimeout },
        build: { arguments in
            var builder = ArgvBuilder("snapshot")
            builder.option("--app", arguments["app"])
            builder.option("--window-id", arguments["window_id"])
            builder.option("--root", arguments["root"])
            builder.option("--surface", arguments["surface"])
            builder.toggle("--skeleton", arguments["skeleton"])
            builder.toggle("-i", arguments["interactive_only"], default: true)
            builder.toggle("--compact", arguments["compact"], default: true)
            builder.option("--max-depth", arguments["max_depth"])
            builder.toggle("--include-bounds", arguments["include_bounds"])
            builder.option("--timeout-ms", arguments["timeout_ms"])
            return builder.argv
        }
    )

    static let find = DesktopTool(
        name: "find",
        description: """
            Search an app's accessibility tree for elements by role, name, text, value or description and return \
            matches with refs. Use it when you know what you are looking for ('the Save button', 'the search field'); \
            use `snapshot` to map an unfamiliar window. Pass `exact` for a whole-name match, `first` for one result.
            """,
        inputSchema: schema([
            "app": appProperty,
            "window_id": windowIDProperty,
            "root": string("Search only inside this ref's subtree."),
            "surface": surfaceProperty,
            "role": string("Accessibility role: button, textfield, checkbox, menuitem, link, ..."),
            "name": string("Accessible name or label."),
            "text": string("Text in the name, value, title or description."),
            "value": string("Current value."),
            "description": string("Accessible description."),
            "exact": boolean("Require exact (case-insensitive) name/description/value matches. Default: false."),
            "first": boolean("Return only the first match. Default: false."),
            "limit": integer("Return at most this many matches. Default: 50; 0 for all."),
            "timeout_ms": integer("Traversal deadline in milliseconds. Default: 5000."),
        ]),
        timeoutSeconds: { _ in defaultTimeout },
        build: { arguments in
            var builder = ArgvBuilder("find")
            builder.option("--app", arguments["app"])
            builder.option("--window-id", arguments["window_id"])
            builder.option("--root", arguments["root"])
            builder.option("--surface", arguments["surface"])
            builder.option("--role", arguments["role"])
            builder.option("--name", arguments["name"])
            builder.option("--text", arguments["text"])
            builder.option("--value", arguments["value"])
            builder.option("--description", arguments["description"])
            builder.toggle("--exact", arguments["exact"])
            builder.toggle("--first", arguments["first"])
            builder.option("--limit", arguments["limit"])
            builder.option("--timeout-ms", arguments["timeout_ms"])
            return builder.argv
        }
    )

    static let act = DesktopTool(
        name: "act",
        description: """
            Act on a ref from the latest snapshot or find, headlessly through accessibility: no pointer movement, no \
            focus change. `click` presses a button or row; `type` inserts text into a field; `set-value` writes a \
            field or slider value directly; `select` picks an option in a list, combo box or menu button; `toggle`, \
            `check`, `uncheck`, `expand`, `collapse`, `focus`, `clear`, `scroll` (direction/amount) and `scroll-to` \
            do what they say. The result's `disposition.retry` says whether a repeat is safe; verify by observing \
            again. A STALE_REF or AMBIGUOUS_TARGET error means snapshot again. Physical input (double-click, hover, \
            drag, coordinates) is Relay Actions, not this tool.
            """,
        inputSchema: schema([
            "action": choice(DesktopAction.allCases.map(\.rawValue), "The accessibility action to perform."),
            "ref": refProperty,
            "text": string("Text to type, the value to set, or the option to select. Required for type, set-value and select."),
            "direction": choice(["up", "down", "left", "right"], "scroll only. Default: down."),
            "amount": integer("scroll only: number of scroll units. Default: 3."),
            "wait_for": waitForProperty,
            "wait_for_gone": waitForGoneProperty,
            "wait_timeout_ms": waitTimeoutProperty,
            "timeout_ms": integer("Maximum milliseconds to resolve the ref and deliver the action. Default: 5000."),
        ], required: ["action", "ref"]),
        timeoutSeconds: waitAwareTimeout,
        build: { arguments in
            guard let actionName = arguments["action"] as? String, let action = DesktopAction(rawValue: actionName) else {
                throw MCPToolError(message: "act requires `action`, one of: \(DesktopAction.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            guard let ref = arguments["ref"] as? String, ref.hasPrefix("@") else {
                throw MCPToolError(message: "act requires `ref`, a qualified ref such as '@s8f3k2p9:e8' from the latest snapshot or find.")
            }
            var builder = ArgvBuilder(action.rawValue)
            builder.positional(ref)
            if action.takesText {
                guard let text = arguments["text"] as? String else {
                    throw MCPToolError(message: "act \(action.rawValue) requires `text`.")
                }
                builder.positional(text)
            }
            if action == .scroll {
                builder.option("--direction", arguments["direction"])
                builder.option("--amount", arguments["amount"])
            }
            builder.option("--timeout-ms", arguments["timeout_ms"])
            withWait(&builder, arguments)
            return builder.argv
        }
    )

    static let press = DesktopTool(
        name: "press",
        description: """
            Send a keyboard shortcut such as 'return', 'escape', 'cmd+s', 'cmd+shift+t' or 'shift+tab' to an app \
            without focusing it (the focused app when `app` is omitted). Quit shortcuts are refused; use `act` on \
            a control when one exists.
            """,
        inputSchema: schema([
            "combo": string("Key combo: return, escape, tab, space, arrows, a-z, 0-9, F1-F12 and punctuation, with cmd/shift/alt/ctrl modifiers joined by '+'."),
            "app": appProperty,
            "window_id": string("Target the app instance that owns this window id when several instances share one name."),
            "wait_for": waitForProperty,
            "wait_for_gone": waitForGoneProperty,
            "wait_timeout_ms": waitTimeoutProperty,
        ], required: ["combo"]),
        timeoutSeconds: waitAwareTimeout,
        build: { arguments in
            guard let combo = arguments["combo"] as? String, !combo.isEmpty else {
                throw MCPToolError(message: "press requires a `combo` such as 'cmd+s'.")
            }
            var builder = ArgvBuilder("press")
            builder.positional(combo)
            builder.option("--app", arguments["app"])
            builder.option("--window-id", arguments["window_id"])
            withWait(&builder, arguments)
            return builder.argv
        }
    )

    static let stateProperties = ["visible", "enabled", "checked", "focused", "expanded", "selected"]
    static let valueProperties = ["text", "value", "title", "bounds", "role", "states"]

    static let get = DesktopTool(
        name: "get",
        description: """
            Read one property of a ref: `text` (what a person reads), `value`, `title`, `bounds`, `role` or `states`, \
            or check one state: `visible`, `enabled`, `checked`, `focused`, `expanded`, `selected`. Use it to verify \
            an action's effect without re-reading the whole window.
            """,
        inputSchema: schema([
            "ref": refProperty,
            "property": choice(valueProperties + stateProperties, "Property to read or state to check. Default: text."),
        ], required: ["ref"]),
        timeoutSeconds: { _ in defaultTimeout },
        build: { arguments in
            guard let ref = arguments["ref"] as? String, ref.hasPrefix("@") else {
                throw MCPToolError(message: "get requires `ref`, a qualified ref from the latest snapshot or find.")
            }
            let property = arguments["property"] as? String ?? "text"
            let isState = stateProperties.contains(property)
            guard isState || valueProperties.contains(property) else {
                throw MCPToolError(message: "get: unknown property '\(property)'.")
            }
            var builder = ArgvBuilder(isState ? "is" : "get")
            builder.positional(ref)
            builder.option("--property", property)
            return builder.argv
        }
    )

    static let wait = DesktopTool(
        name: "wait",
        description: """
            Block until something happens instead of sleeping: a number of milliseconds, text appearing in an app's \
            tree, a window with a title appearing, a ref reaching a predicate (exists, enabled, visible, actionable, \
            value), a menu opening or closing, or a lifecycle event (window-opened, window-closed, app-launched, \
            app-terminated, focus-changed, surface-appeared, surface-dismissed). Returns when the condition holds or \
            the timeout passes.
            """,
        inputSchema: schema([
            "ms": integer("Milliseconds to pause when no condition is given."),
            "app": appProperty,
            "text": string("Wait until this text appears in the app's accessibility tree."),
            "window": string("Wait until a window with this title appears."),
            "element": string("Wait until this ref satisfies `predicate` (default: exists)."),
            "predicate": choice(["exists", "enabled", "visible", "actionable", "value"], "Condition for `element`."),
            "value": string("Expected value when predicate is 'value'."),
            "event": choice(["window-opened", "window-closed", "app-launched", "app-terminated", "focus-changed", "surface-appeared", "surface-dismissed"], "Wait for a desktop lifecycle event."),
            "menu": boolean("Wait until a menu surface is open."),
            "menu_closed": boolean("Wait until the menu surface is dismissed."),
            "timeout_ms": integer("Maximum milliseconds to wait for a condition. Default: 30000."),
        ]),
        timeoutSeconds: { arguments in
            let pause = (arguments["ms"] as? NSNumber)?.doubleValue ?? 0
            let conditionTimeout = (arguments["timeout_ms"] as? NSNumber)?.doubleValue ?? 30_000
            return max(defaultTimeout, (max(pause, conditionTimeout)) / 1000 + 15)
        },
        build: { arguments in
            var builder = ArgvBuilder("wait")
            if let ms = arguments["ms"] as? NSNumber {
                builder.positional(ms.stringValue)
            }
            builder.option("--app", arguments["app"])
            builder.option("--text", arguments["text"])
            builder.option("--window", arguments["window"])
            builder.option("--element", arguments["element"])
            builder.option("--predicate", arguments["predicate"])
            builder.option("--value", arguments["value"])
            builder.option("--event", arguments["event"])
            builder.toggle("--menu", arguments["menu"])
            builder.toggle("--menu-closed", arguments["menu_closed"])
            builder.option("--timeout", arguments["timeout_ms"])
            return builder.argv
        }
    )

    static let listApps = DesktopTool(
        name: "list_apps",
        description: "List running GUI applications with name, bundle id, pid and whether they are regular or background apps. Use the `name` with the `app` argument of other tools.",
        inputSchema: schema([
            "app": string("Filter by application name."),
        ]),
        timeoutSeconds: { _ in defaultTimeout },
        build: { arguments in
            var builder = ArgvBuilder("list-apps")
            builder.option("--app", arguments["app"])
            return builder.argv
        }
    )

    static let listWindows = DesktopTool(
        name: "list_windows",
        description: "List visible windows with their ids, titles and owning apps. Pass a window id as `window_id` to other tools when an app has several windows.",
        inputSchema: schema([
            "app": string("Filter by exact (case-insensitive) application name."),
        ]),
        timeoutSeconds: { _ in defaultTimeout },
        build: { arguments in
            var builder = ArgvBuilder("list-windows")
            builder.option("--app", arguments["app"])
            return builder.argv
        }
    )

    static let focusWindow = DesktopTool(
        name: "focus_window",
        description: "Bring a window to the front by id, app name or (partial) title and confirm it has focus. Only needed before Relay Actions physical input or when the user asked to switch apps; Relay Desktop reads and acts without focusing.",
        inputSchema: schema([
            "window_id": string("Window id from `list_windows`."),
            "app": string("Application name."),
            "title": string("Window title (partial match accepted)."),
        ]),
        timeoutSeconds: { _ in defaultTimeout },
        build: { arguments in
            var builder = ArgvBuilder("focus-window")
            builder.option("--window-id", arguments["window_id"])
            builder.option("--app", arguments["app"])
            builder.option("--title", arguments["title"])
            guard builder.argv.count > 1 else {
                throw MCPToolError(message: "focus_window requires `window_id`, `app` or `title`.")
            }
            return builder.argv
        }
    )

    static let launch = DesktopTool(
        name: "launch",
        description: "Launch an application by display name or bundle id and return once its process runs (attaches to a running instance). Pass `activate` to bring it forward and wait for a window. Prefer this over clicking through the Dock or Finder.",
        inputSchema: schema([
            "app": string("Application display name ('System Settings') or bundle id ('com.apple.systempreferences')."),
            "activate": boolean("Bring the app forward and wait for a window. Default: false."),
            "timeout_ms": integer("Upper bound for the whole launch in milliseconds. Default: 30000."),
        ], required: ["app"]),
        timeoutSeconds: { arguments in
            let launchTimeout = (arguments["timeout_ms"] as? NSNumber)?.doubleValue ?? 30_000
            return max(defaultTimeout, launchTimeout / 1000 + 15)
        },
        build: { arguments in
            guard let app = arguments["app"] as? String, !app.isEmpty else {
                throw MCPToolError(message: "launch requires `app`.")
            }
            var builder = ArgvBuilder("launch")
            builder.positional(app)
            builder.toggle("--activate", arguments["activate"])
            builder.option("--timeout", arguments["timeout_ms"])
            return builder.argv
        }
    )

    static let status = DesktopTool(
        name: "status",
        description: "Report the bundled agent-desktop version, platform, Accessibility permission state and supported surfaces. Call it when another Relay Desktop tool reports a permission or platform error.",
        inputSchema: schema([:]),
        timeoutSeconds: { _ in defaultTimeout },
        build: { _ in ["status"] }
    )

    static let all: [DesktopTool] = [
        snapshot, find, act, press, get, wait, listApps, listWindows, focusWindow, launch, status,
    ]
}
