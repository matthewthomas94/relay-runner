import Foundation

/// Tracks which parent terminals/IDEs (Terminal, Warp, VS Code, Claude.app, …)
/// the user has already walked through the permissions wizard for.
///
/// The MCP server is spawned per-Claude-session by the parent (terminal/IDE),
/// and macOS attributes Accessibility / Screen Recording grants to that
/// parent — so each new parent the user runs `claude` from triggers a fresh
/// "you need to grant Terminal these permissions" prompt. We persist a list
/// of acknowledged parents in UserDefaults so the wizard fires once per
/// parent per install (or again after a permission revocation forces a reset).
///
/// This is purely a UI hint store. We CANNOT verify whether the parent app
/// actually has the OS permissions — macOS doesn't expose other apps' TCC
/// state to us — so this is best-effort. The runtime safety net is
/// `PermissionPreflight` in the MCP server, which still throws a clear error
/// if a CGEvent / SCShareableContent call fails post-onboarding.
enum ParentOnboardingTracker {

    private static let defaultsKey = "com.relayrunner.onboardedParents"

    /// True if the user has already walked through the wizard for this parent
    /// in any prior session.
    static func isOnboarded(_ parent: String) -> Bool {
        loadAll().contains(parent)
    }

    /// Mark this parent as onboarded — the wizard won't auto-surface for it
    /// again unless `resetOnboarded` clears it (e.g. on permission revocation).
    static func markOnboarded(_ parent: String) {
        var all = loadAll()
        all.insert(parent)
        persist(all)
    }

    /// Forget the wizard ever ran for this parent. Called when the MCP server
    /// reports a permission missing post-onboarding — most likely the user
    /// (or macOS) revoked it, and we want the wizard to walk them through
    /// re-granting on the next attempt.
    static func resetOnboarded(_ parent: String) {
        var all = loadAll()
        all.remove(parent)
        persist(all)
    }

    /// Diagnostic helper for the menu's "Reset onboarding" action and tests.
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    // MARK: - Private

    private static func loadAll() -> Set<String> {
        guard let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [String] else {
            return []
        }
        return Set(raw)
    }

    private static func persist(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set).sorted(), forKey: defaultsKey)
    }
}
