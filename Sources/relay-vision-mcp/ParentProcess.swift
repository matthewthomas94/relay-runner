import Darwin
import Foundation

// Legacy parent-process detector retained for compatibility with older
// app-side metadata flows and tests. Current Relay Actions/Vision protected
// work is app-hosted, so normal Accessibility and Screen Recording grants
// target Relay Runner rather than the terminal, IDE, Codex, or Claude host.
//
// The walk stops at the first known terminal/IDE host app, or at launchd
// (pid 1). Native Codex.app / Claude.app matches are kept as fallbacks:
// when their bundled CLI is run inside Terminal, the executable path still
// contains `/Codex.app/` or `/Claude.app/`, but TCC belongs to Terminal.
//
// We don't try to be exhaustive; this is now diagnostic metadata, not the
// normal permission target.

enum ParentProcess {

    struct TerminalApp {
        let displayName: String
        let executablePath: String
        let pid: Int32
    }

    /// Diagnostic: dump the parent-chain executable paths. Used in stderr logs
    /// when no terminal pattern matched, so the user (or a future patch) can
    /// see what was actually in the chain.
    static func dumpChain() -> String {
        var pid: Int32 = getppid()
        var chain: [String] = []
        for _ in 0..<10 {
            guard pid > 1 else { break }
            let path = executablePath(for: pid) ?? "?"
            chain.append("\(pid):\(path)")
            let parent = parentPid(of: pid)
            if parent <= 0 || parent == pid { break }
            pid = parent
        }
        return chain.joined(separator: " → ")
    }

    static func detectTerminal() -> TerminalApp? {
        var pid: Int32 = getppid()
        var agentAppFallback: TerminalApp?
        // Cap the walk — most chains are 3–5 deep (agent CLI → shell → terminal),
        // and we never legitimately need to walk further than this.
        for _ in 0..<10 {
            guard pid > 1 else { break }

            let exePath = executablePath(for: pid) ?? ""
            if let match = matchParent(executablePath: exePath) {
                let app = TerminalApp(displayName: match.display, executablePath: exePath, pid: pid)
                switch match.kind {
                case .hostApp:
                    return app
                case .agentApp:
                    if agentAppFallback == nil {
                        agentAppFallback = app
                    }
                }
            }

            // Walk up. If sysctl fails or returns ourselves, stop to avoid
            // infinite loops on weird process tables.
            let parent = parentPid(of: pid)
            if parent <= 0 || parent == pid { break }
            pid = parent
        }
        return agentAppFallback
    }

    static func detectTerminal(inExecutablePathChain chain: [String]) -> TerminalApp? {
        var agentAppFallback: TerminalApp?
        for (index, exePath) in chain.enumerated() {
            guard let match = matchParent(executablePath: exePath) else { continue }
            let app = TerminalApp(
                displayName: match.display,
                executablePath: exePath,
                pid: Int32(index + 1)
            )
            switch match.kind {
            case .hostApp:
                return app
            case .agentApp:
                if agentAppFallback == nil {
                    agentAppFallback = app
                }
            }
        }
        return agentAppFallback
    }

    // MARK: - Helpers

    private static func executablePath(for pid: Int32) -> String? {
        // Equivalent of PROC_PIDPATHINFO_MAXSIZE (= 4 * MAXPATHLEN = 4096).
        // The constant isn't bridged to Swift; the literal is stable across
        // every macOS version that supports proc_pidpath.
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parentPid(of pid: Int32) -> Int32 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibPtr in
            sysctl(mibPtr.baseAddress, UInt32(mibPtr.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    /// Match an executable path to a known host app. Pattern is either a
    /// `/<App>.app/` substring (covers most GUI apps) or a basename match
    /// (covers headless / non-bundled binaries). The display name is what
    /// the user will look for in System Settings → Privacy → Screen Recording.
    private static func matchParent(executablePath path: String) -> ParentMatch? {
        let patterns: [Pattern] = [
            // GUI terminals
            Pattern(needle: "/Terminal.app/",  display: "Terminal",  isBundle: true, kind: .hostApp),
            Pattern(needle: "/iTerm.app/",     display: "iTerm",     isBundle: true, kind: .hostApp),
            Pattern(needle: "/iTerm2.app/",    display: "iTerm",     isBundle: true, kind: .hostApp),
            Pattern(needle: "/Warp.app/",      display: "Warp",      isBundle: true, kind: .hostApp),
            Pattern(needle: "/WezTerm.app/",   display: "WezTerm",   isBundle: true, kind: .hostApp),
            Pattern(needle: "/kitty.app/",     display: "kitty",     isBundle: true, kind: .hostApp),
            Pattern(needle: "/Alacritty.app/", display: "Alacritty", isBundle: true, kind: .hostApp),
            Pattern(needle: "/Hyper.app/",     display: "Hyper",     isBundle: true, kind: .hostApp),
            Pattern(needle: "/Ghostty.app/",   display: "Ghostty",   isBundle: true, kind: .hostApp),
            Pattern(needle: "/Tabby.app/",     display: "Tabby",     isBundle: true, kind: .hostApp),
            // IDE-embedded terminals — VS Code spawns the agent CLI from its
            // integrated terminal under Code Helper (Plugin) etc.
            Pattern(needle: "/Visual Studio Code.app/",      display: "Visual Studio Code", isBundle: true, kind: .hostApp),
            Pattern(needle: "/Code.app/",                    display: "Visual Studio Code", isBundle: true, kind: .hostApp),
            Pattern(needle: "/Cursor.app/",                  display: "Cursor",             isBundle: true, kind: .hostApp),
            Pattern(needle: "/Windsurf.app/",                display: "Windsurf",           isBundle: true, kind: .hostApp),
            Pattern(needle: "/JetBrains Toolbox.app/",       display: "JetBrains Toolbox",  isBundle: true, kind: .hostApp),
            Pattern(needle: "/Zed.app/",                     display: "Zed",                isBundle: true, kind: .hostApp),
            Pattern(needle: "/Sublime Text.app/",            display: "Sublime Text",       isBundle: true, kind: .hostApp),
            // First-class agent desktop apps. Keep walking after these so a
            // bundled CLI launched from Terminal resolves to Terminal instead.
            Pattern(needle: "/Codex.app/",                   display: "Codex",              isBundle: true, kind: .agentApp),
            Pattern(needle: "/Claude.app/",                  display: "Claude",             isBundle: true, kind: .agentApp),
            // Headless / direct-binary launches
            Pattern(needle: "/wezterm",   display: "WezTerm",   isBundle: false, kind: .hostApp),
            Pattern(needle: "/alacritty", display: "Alacritty", isBundle: false, kind: .hostApp),
            Pattern(needle: "/kitty",     display: "kitty",     isBundle: false, kind: .hostApp),
        ]
        for p in patterns {
            if p.isBundle {
                if path.contains(p.needle) { return ParentMatch(display: p.display, kind: p.kind) }
            } else {
                // Basename match for non-bundled binaries — `/Applications/x.app/Contents/MacOS/wezterm`
                // already matched the bundle path; only fire on bare paths.
                let basename = (path as NSString).lastPathComponent
                if basename == (p.needle as NSString).lastPathComponent {
                    return ParentMatch(display: p.display, kind: p.kind)
                }
            }
        }
        return nil
    }

    private enum ParentMatchKind {
        case hostApp
        case agentApp
    }

    private struct ParentMatch {
        let display: String
        let kind: ParentMatchKind
    }

    private struct Pattern {
        let needle: String
        let display: String
        let isBundle: Bool
        let kind: ParentMatchKind
    }
}
