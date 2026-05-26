import Darwin
import Foundation

// Walks up the process tree from this MCP server's parent to find the
// terminal (or IDE) that spawned `claude`. macOS attributes Screen Recording
// permission to the *responsible* process — typically that's the terminal,
// not Relay Runner — so the user has to grant Screen Recording to e.g.
// Terminal.app, not (only) to Relay Runner.app. Without naming the right app
// the user opens System Settings, grants Relay Runner, and is confused when
// the next screenshot still fails.
//
// The walk stops at the first known terminal-class app, or at launchd (pid 1).
//
// We don't try to be exhaustive — the goal is "you probably need to grant
// Screen Recording to <X>", and a friendly fallback when detection fails.

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
        // Cap the walk — most chains are 3–5 deep (claude → shell → terminal),
        // and we never legitimately need to walk further than this.
        for _ in 0..<10 {
            guard pid > 1 else { break }

            let exePath = executablePath(for: pid) ?? ""
            if let match = matchTerminal(executablePath: exePath) {
                return TerminalApp(displayName: match, executablePath: exePath, pid: pid)
            }

            // Walk up. If sysctl fails or returns ourselves, stop to avoid
            // infinite loops on weird process tables.
            let parent = parentPid(of: pid)
            if parent <= 0 || parent == pid { break }
            pid = parent
        }
        return nil
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

    /// Match an executable path to a known terminal-class app. Pattern is
    /// either a `/<App>.app/` substring (covers most GUI terminals) or a
    /// basename match (covers headless / non-bundled binaries). The display
    /// name is what the user will look for in System Settings → Privacy →
    /// Screen Recording.
    private static func matchTerminal(executablePath path: String) -> String? {
        struct Pattern { let needle: String; let display: String; let isBundle: Bool }
        let patterns: [Pattern] = [
            // GUI terminals
            Pattern(needle: "/Terminal.app/",  display: "Terminal",  isBundle: true),
            Pattern(needle: "/iTerm.app/",     display: "iTerm",     isBundle: true),
            Pattern(needle: "/iTerm2.app/",    display: "iTerm",     isBundle: true),
            Pattern(needle: "/Warp.app/",      display: "Warp",      isBundle: true),
            Pattern(needle: "/WezTerm.app/",   display: "WezTerm",   isBundle: true),
            Pattern(needle: "/kitty.app/",     display: "kitty",     isBundle: true),
            Pattern(needle: "/Alacritty.app/", display: "Alacritty", isBundle: true),
            Pattern(needle: "/Hyper.app/",     display: "Hyper",     isBundle: true),
            Pattern(needle: "/Ghostty.app/",   display: "Ghostty",   isBundle: true),
            Pattern(needle: "/Tabby.app/",     display: "Tabby",     isBundle: true),
            // Anthropic's own Claude Code desktop app — spawns `claude` from
            // its embedded shell. Worth handling explicitly because (a) it's
            // increasingly common and (b) the `/Claude.app/` bundle is what
            // TCC attributes to.
            Pattern(needle: "/Claude.app/",                  display: "Claude",             isBundle: true),
            // IDE-embedded terminals — VS Code spawns claude from its
            // integrated terminal under Code Helper (Plugin) etc.
            Pattern(needle: "/Visual Studio Code.app/",      display: "Visual Studio Code", isBundle: true),
            Pattern(needle: "/Code.app/",                    display: "Visual Studio Code", isBundle: true),
            Pattern(needle: "/Cursor.app/",                  display: "Cursor",             isBundle: true),
            Pattern(needle: "/Windsurf.app/",                display: "Windsurf",           isBundle: true),
            Pattern(needle: "/JetBrains Toolbox.app/",       display: "JetBrains Toolbox",  isBundle: true),
            Pattern(needle: "/Zed.app/",                     display: "Zed",                isBundle: true),
            Pattern(needle: "/Sublime Text.app/",            display: "Sublime Text",       isBundle: true),
            // Headless / direct-binary launches
            Pattern(needle: "/wezterm",   display: "WezTerm",   isBundle: false),
            Pattern(needle: "/alacritty", display: "Alacritty", isBundle: false),
            Pattern(needle: "/kitty",     display: "kitty",     isBundle: false),
        ]
        for p in patterns {
            if p.isBundle {
                if path.contains(p.needle) { return p.display }
            } else {
                // Basename match for non-bundled binaries — `/Applications/x.app/Contents/MacOS/wezterm`
                // already matched the bundle path; only fire on bare paths.
                let basename = (path as NSString).lastPathComponent
                if basename == (p.needle as NSString).lastPathComponent { return p.display }
            }
        }
        return nil
    }
}
