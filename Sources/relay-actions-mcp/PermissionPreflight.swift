import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Pre-flight permission UX.
//
// macOS surfaces TCC dialogs the first time a process touches a gated API
// (Accessibility for CGEvent, Screen Recording for SCShareableContent). When a
// user is voice-driving Claude they have no idea a dialog is about to appear,
// what it's for, or which app to grant — TCC attributes to the *responsible*
// parent (Terminal / Warp / VS Code etc.), not Relay Runner.
//
// This helper warns the user via TTS *before* the API call that triggers the
// dialog. The warning explicitly names:
//   - what action is about to happen (derived from the latest propose_action
//     summary, falling back to a generic per-tool string)
//   - which app the macOS dialog will reference (via ParentProcess.detectTerminal)
//
// We warn at most once per (permission × session), so a chatty session doesn't
// re-narrate the same permission ask. After the warning we sleep briefly so the
// user can react before the dialog blocks the screen, then attempt the system
// prompt and re-check. If the permission is still missing we surface a clear
// error to Claude so it can speak a helpful follow-up rather than silently
// posting CGEvents that get dropped.

enum PermissionPreflight {

    enum Outcome {
        /// Permission is (already) granted — proceed.
        case granted
        /// User has not yet granted; subsequent action will likely fail. Caller
        /// should surface the message to Claude as a tool error.
        case stillMissing(message: String)
    }

    // MARK: - Action context

    /// Most recent propose_action summary, used as the human-readable purpose
    /// in pre-flight warnings. ProposeActionTool records here on every call.
    private static var lastProposedSummary: String?
    private static var lastProposedAt: Date?
    private static let purposeTTL: TimeInterval = 15

    static func recordProposedAction(summary: String) {
        lock.lock(); defer { lock.unlock() }
        lastProposedSummary = summary
        lastProposedAt = Date()
    }

    static func recentPurpose() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let when = lastProposedAt,
              Date().timeIntervalSince(when) < purposeTTL,
              let s = lastProposedSummary else { return nil }
        return s
    }

    // MARK: - Public entry points

    /// Pre-flight check before posting CGEvents (click / key / type / scroll).
    /// `fallbackPurpose` is used when the model didn't call propose_action
    /// recently — keep it short and starting with a verb ("click at (x, y)").
    static func ensureAccessibility(fallbackPurpose: String) -> Outcome {
        if AXIsProcessTrusted() { return .granted }

        let purpose = recentPurpose() ?? fallbackPurpose
        let parent = ParentProcess.detectTerminal()?.displayName
            ?? "the app you launched `claude` from"

        warnOnceIfNeeded(permission: .accessibility) {
            speak("""
                To \(purpose), macOS needs to give \(parent) permission to control your Mac. \
                A dialog will pop up — please click Allow.
                """)
        }

        // Trigger the system prompt. AXIsProcessTrustedWithOptions only fires a
        // dialog the first time per cdhash; subsequent denied state requires
        // the user to flip the toggle in System Settings manually.
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        // Give the user a moment to read/hear the warning and click Allow on
        // the OS dialog. We poll for up to ~4s so a quick grant takes effect
        // before we give up — most users click Allow within that window.
        if pollUntilGranted(check: { AXIsProcessTrusted() }, timeout: 4.0) {
            return .granted
        }

        return .stillMissing(message: """
            Could not perform the action. Accessibility permission is not granted.

            macOS attributes input control to the app that launched `claude`, NOT to \
            Relay Runner. Grant Accessibility to **\(parent)**:

            1. Open System Settings → Privacy & Security → Accessibility
            2. Toggle on \(parent)
            3. (No restart needed for Accessibility — try the action again)

            Without this permission, every click, keystroke, and scroll I post will be \
            silently dropped by macOS. Voice transcription and speech still work.
            """)
    }

    /// Pre-flight check before SCShareableContent / SCScreenshotManager use.
    /// Mirrors ensureAccessibility but for Screen Recording.
    static func ensureScreenRecording(fallbackPurpose: String) -> Outcome {
        if CGPreflightScreenCaptureAccess() { return .granted }

        let purpose = recentPurpose() ?? fallbackPurpose
        let parent = ParentProcess.detectTerminal()?.displayName
            ?? "the app you launched `claude` from"

        warnOnceIfNeeded(permission: .screenRecording) {
            speak("""
                To \(purpose), macOS needs to give \(parent) permission to record the screen. \
                A dialog will pop up — please click Allow, then I'll need you to restart \
                your Claude session for it to take effect.
                """)
        }

        // CGRequestScreenCaptureAccess registers the cdhash with TCC and
        // surfaces the prompt on first encounter. Returns true only when
        // already granted — we treat it as fire-and-forget.
        _ = CGRequestScreenCaptureAccess()

        if pollUntilGranted(check: { CGPreflightScreenCaptureAccess() }, timeout: 4.0) {
            return .granted
        }

        // Screen Recording grants notoriously don't take effect for already-running
        // processes. Tell the user explicitly so they don't grant, retry, fail, and
        // wonder why.
        return .stillMissing(message: """
            Could not capture the screen. Screen Recording permission is not granted.

            macOS attributes screen capture to the app that launched `claude`, NOT to \
            Relay Runner. Grant Screen Recording to **\(parent)**:

            1. Open System Settings → Privacy & Security → Screen Recording
            2. Toggle on \(parent)
            3. Quit and relaunch \(parent) (the permission only takes effect on relaunch)
            4. Restart your `claude` session

            Without this permission, every screenshot, click, and computer-vision \
            request I make will fail. Voice transcription and speech still work.
            """)
    }

    // MARK: - Private

    private enum Permission: Hashable {
        case accessibility
        case screenRecording
    }

    private static let lock = NSLock()
    private static var warnedThisSession: Set<Permission> = []

    /// Warn at most once per (permission × session). The first call also blocks
    /// briefly so the user hears a chunk before the OS dialog blocks the screen.
    private static func warnOnceIfNeeded(permission: Permission, _ work: () -> Void) {
        lock.lock()
        let alreadyWarned = warnedThisSession.contains(permission)
        warnedThisSession.insert(permission)
        lock.unlock()

        guard !alreadyWarned else { return }
        work()
        // ~1.5s lets the bridge start speaking and the user register what's
        // about to happen before the OS dialog steals focus. Empirically this
        // is the smallest window that doesn't feel like the dialog "just
        // appeared" with no warning.
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Speak `text` via the voice bridge's TTS FIFO. Best-effort: if the bridge
    /// isn't running (no FIFO or no reader on the other end), silently drop —
    /// pre-flight still runs and the API call still happens; the user just
    /// won't hear the warning. The perimeter overlay is a separate visual
    /// signal driven by tool_fired.
    ///
    /// Important: must open with O_NONBLOCK. The default blocking open of a
    /// FIFO with no reader hangs forever — we'd deadlock the MCP server if
    /// the bridge had crashed.
    private static func speak(_ text: String) {
        let path = "/tmp/tts_in.fifo"
        let fd = open(path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else {
            log("TTS FIFO unavailable at \(path) (errno \(errno)) — skipping spoken pre-flight warning.")
            return
        }
        defer { close(fd) }
        let line = text.replacingOccurrences(of: "\n", with: " ") + "\n"
        let data = Array(line.utf8)
        let n = data.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress, buf.count)
        }
        if n < 0 {
            // EPIPE = reader vanished between open and write. EAGAIN = pipe
            // buffer full (very unlikely for a single short line). Either way,
            // we can't help the user further — the visual perimeter pulse is
            // still active via tool_fired.
            log("TTS FIFO write failed (errno \(errno)).")
        }
    }

    /// Poll `check` every 100ms up to `timeout` seconds. Returns true on first
    /// granted observation, false on timeout.
    private static func pollUntilGranted(check: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return check()
    }
}
