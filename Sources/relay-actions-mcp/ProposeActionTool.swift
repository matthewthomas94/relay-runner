import Foundation

// The confirmation gate that turns voice + computer actions into something
// safe enough to leave running.
//
// Risk tiering (from docs/specs/computer-actions.md):
// - "low":    auto-confirms instantly. For read-only / reversible actions.
//             Examples: scrolling, hovering, reading window titles, screenshots.
// - "medium": blocks on user double-tap. For single-step state changes.
//             Examples: clicking a button, typing into a field, key combo.
// - "high":   blocks on user double-tap. For irreversible / destructive actions.
//             Examples: clicking Send / Delete / Pay / Submit.
//
// Resolution sources:
//   double-tap Option (in CapsLockGesture)  → "confirmed"
//   double-tap Control (in CapsLockGesture) → "rejected"
//   no input for 30s (server-side in ActionsConfirmBus) → "timeout"
//   menu-bar app not running                → "menu_bar_unavailable"
//
// Server-side keyword guard: if Claude classifies an action as medium but the
// summary contains a destructive verb (delete, send, submit, pay, confirm,
// remove, drop, terminate), the tool escalates it to high before prompting.
// Cheap insurance against model misclassification — described as a v1.1
// hardening in the spec, included up-front because the cost is ~10 lines.

struct ProposeActionTool: MCPTool {
    let name = "propose_action"
    let description = """
        Request user confirmation before performing a state-changing action. \
        Required before every click/type/key/scroll that modifies app state. \
        \
        risk='low' auto-confirms (use for read-only / reversible actions like \
        scrolling and screenshots — but you usually don't need propose_action \
        for those). risk='medium' blocks on the user's double-tap Option \
        (yes) or double-tap Control (no) for single-step state changes. \
        risk='high' for irreversible or destructive actions. \
        \
        Returns {confirmed: bool, reason?: string}. If confirmed=false, do NOT \
        perform the action — fall back to either describing what you wanted to \
        do or asking the user to clarify via voice.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "summary": [
                    "type": "string",
                    "description": "One-line plain-English description of the action you want to perform, e.g. 'Click Send in Slack' or 'Type the password into the login form'.",
                ],
                "risk": [
                    "type": "string",
                    "enum": ["low", "medium", "high"],
                    "description": "Risk classification. See tool description.",
                ],
            ],
            "required": ["summary", "risk"],
        ]
    }

    private static let destructiveKeywords: Set<String> = [
        "delete", "remove", "drop", "terminate", "destroy", "wipe",
        "send", "submit", "publish", "post",
        "pay", "purchase", "buy", "charge",
        "confirm", "approve", "authorize",
        "logout", "sign out",
    ]

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let summary = arguments["summary"] as? String,
              let risk = arguments["risk"] as? String else {
            throw MCPToolError(message: "propose_action requires 'summary' and 'risk' arguments.")
        }

        // Stash the summary so the pre-flight permission warning can use it
        // verbatim: "To click Send in Slack, macOS needs to give …" instead of
        // a generic "to click at (x, y)". Pre-flight reads back through
        // PermissionPreflight.recentPurpose() with a 15s TTL.
        PermissionPreflight.recordProposedAction(summary: summary)

        var effectiveRisk = risk

        // Server-side keyword escalation: medium → high if summary contains a
        // destructive verb. Doesn't apply to high or low (high is already
        // gated, low is intentionally fast).
        if effectiveRisk == "medium" {
            let lower = summary.lowercased()
            if Self.destructiveKeywords.contains(where: { lower.contains($0) }) {
                effectiveRisk = "high"
                log("Escalated medium → high based on summary: \(summary)")
            }
        }

        // Low risk: skip the user prompt. Still notify so the perimeter glow
        // lights up for read-only activity.
        if effectiveRisk == "low" {
            ConfirmationClient.notifyToolFired(toolName: "propose_action")
            return [confirmedReply()]
        }

        // Medium / high: block on the bus.
        let outcome = await Task.detached(priority: .userInitiated) {
            ConfirmationClient.requestConfirmation(summary: summary, risk: effectiveRisk)
        }.value

        switch outcome {
        case .confirmed:
            return [confirmedReply()]
        case .rejected:
            return [rejectedReply(reason: "user_rejected")]
        case .timeout:
            return [rejectedReply(reason: "timeout")]
        case .menuBarUnavailable:
            // No menu-bar app running — fail closed. Better Claude is told
            // it can't act than silently letting actions through ungated.
            return [rejectedReply(reason: "menu_bar_unavailable")]
        }
    }

    private func confirmedReply() -> [String: Any] {
        let payload: [String: Any] = ["confirmed": true]
        return jsonContent(payload)
    }

    private func rejectedReply(reason: String) -> [String: Any] {
        let payload: [String: Any] = ["confirmed": false, "reason": reason]
        return jsonContent(payload)
    }

    private func jsonContent(_ payload: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let str = String(data: data, encoding: .utf8) ?? "{}"
        return ["type": "text", "text": str]
    }
}
