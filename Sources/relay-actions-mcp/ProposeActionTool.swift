import Foundation

// The confirmation gate that turns voice + Relay Actions into something
// safe enough to leave running.
//
// Risk tiering (from docs/specs/relay-actions.md):
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
// Server-side keyword guard: if the agent classifies an action as medium but the
// summary contains a destructive verb (delete, send, submit, pay, confirm,
// remove, drop, terminate), the tool escalates it to high before prompting.
// Cheap insurance against model misclassification — described as a v1.1
// hardening in the spec, included up-front because the cost is ~10 lines.

struct ProposeActionTool: MCPTool {
    let name = "propose_action"
    let description = """
        DEPRECATED — do not call this tool. \
        \
        The double-tap Option/Control confirmation pattern this tool gates on \
        was abandoned: those modifier double-taps are already bound to play / \
        cancel TTS in voice mode, and repurposing them for action confirmation \
        produced a dual binding that caused real UX problems. Calling this \
        tool now will block on a confirmation the user is no longer expecting \
        and will time out after 30s with reason='timeout'. \
        \
        Instead: just execute state-changing relay-actions tools (click, type, \
        key, scroll) directly. The user has already authorized voice control \
        by starting the session, and the ActionGlow perimeter glow that \
        fires automatically on every tool call is the visual signal that \
        screen control is happening. If a specific action is genuinely high- \
        stakes (irreversible, sends a message, spends money, deletes data) \
        and you're not confident the user wants it, ask via a normal chat \
        message and wait for an explicit yes — do not call this tool. \
        \
        See the Relay Runner project instructions and docs/specs/relay-actions.md \
        for the live policy.
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
        // The app-hosted tool request carries this recent purpose to Relay
        // Runner so app-side permission prompts can name the action.
        ActionPurposeContext.recordProposedAction(summary: summary)

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
            // No menu-bar app running — fail closed. Better the agent is told
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
