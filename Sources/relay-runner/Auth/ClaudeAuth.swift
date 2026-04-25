import Foundation
import Security

/// Tells whether the Claude Code CLI (used by voice_bridge.py) has
/// credentials it can use. Used to decide whether onboarding should
/// show the "Sign in" step and whether session-start is going to
/// hit an immediate auth wall.
///
/// claude.ai/install.sh's `claude /login` writes an OAuth token into
/// the macOS login keychain under service name `Claude Code-credentials`.
/// On a freshly-installed CLI that's never been signed in, the entry
/// doesn't exist. We check for the *existence* of the entry — not the
/// password value — so the keychain doesn't prompt the user for an
/// access password (reading `kSecReturnAttributes` is silent; reading
/// `kSecReturnData` is the call that triggers the ACL).
///
/// Doesn't cover the Anthropic-Console-API-key path (where the user
/// sets `ANTHROPIC_API_KEY` in their shell profile or `claude config`).
/// That's a small edge case and the user can simply skip the onboarding
/// step in that flow.
enum ClaudeAuth {

    private static let keychainService = "Claude Code-credentials"

    /// True iff the Claude Code keychain entry is present.
    static var isAuthenticated: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
    }

    /// Path to the bundled Claude binary that relay-bridge installed.
    /// Used by the "Sign in" button as the explicit interpreter, since
    /// `claude` may not be on PATH yet for a fresh install (the user
    /// hasn't restarted their shell since the binary was symlinked).
    static var claudeBinaryPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/bin/claude")
    }

    /// Open Terminal.app and run `claude /login` in it. Returns once
    /// the AppleScript dispatch is fired — the user completes the
    /// login flow on their own time, and the onboarding view polls
    /// `isAuthenticated` to detect completion.
    static func openLoginInTerminal() {
        let claude = claudeBinaryPath
        // The trailing echo gives the user a clear "you can close this
        // window" cue after the OAuth flow finishes, instead of leaving
        // a bare shell prompt that looks unfinished.
        let script = """
        tell application "Terminal"
            activate
            do script "'\(claude)' /login; echo ''; echo '[Relay Runner] Sign-in complete — you can close this window.'"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        try? proc.run()
    }
}
