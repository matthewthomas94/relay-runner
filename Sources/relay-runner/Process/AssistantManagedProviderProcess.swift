import Darwin
import Foundation

/// Persisted only for processes launched by this app. A PID alone never
/// authorizes a signal: compare its birth time, user and process group first.
struct AssistantManagedProviderProcess: Codable, Equatable {
    let pid: Int
    let identity: String

    enum State: Equatable { case exited, stale, matching, unknown }

    func state(identityForPID: (Int) -> String? = Self.identity,
               isAlive: (Int) -> Bool = Self.isAlive) -> State {
        guard isAlive(pid) else { return .exited }
        guard let current = identityForPID(pid) else { return .unknown }
        return current == identity ? .matching : .stale
    }

    /// A stale PID belongs to another process. An unknown live identity blocks
    /// replacement without signaling it. Both paths leave unrelated apps alone.
    func requestTermination(identityForPID: (Int) -> String? = Self.identity,
                            isAlive: (Int) -> Bool = Self.isAlive,
                            terminate: (Int) -> Bool = Self.terminate) -> Bool {
        switch state(identityForPID: identityForPID, isAlive: isAlive) {
        case .exited, .stale: return true
        case .unknown: return false
        case .matching: return terminate(pid)
        }
    }

    static func identity(_ pid: Int) -> String? {
        guard pid > 1 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart=", "-o", "uid=", "-o", "pgid="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func isAlive(_ pid: Int) -> Bool {
        guard pid > 1 else { return false }
        guard Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM else { return false }
        // kill(pid, 0) also succeeds for a zombie, which cannot own more work.
        return !isZombie(pid)
    }

    static func isZombie(_ pid: Int) -> Bool {
        processInfo(pid).map { Int32($0.kp_proc.p_stat) == SZOMB } ?? false
    }

    /// SwiftTerm cancels its child monitor on explicit termination. Reap only
    /// that stopped direct child, preserving other monitored children's status.
    @discardableResult
    static func reapExplicitlyStoppedChild(_ pid: Int) -> Task<Void, Never>? {
        guard let stopped = processInfo(pid), stopped.kp_eproc.e_ppid == getpid() else { return nil }
        let birth = stopped.kp_proc.p_starttime
        return Task.detached(priority: .utility) {
            while let current = processInfo(pid), current.kp_eproc.e_ppid == getpid(),
                  current.kp_proc.p_starttime.tv_sec == birth.tv_sec,
                  current.kp_proc.p_starttime.tv_usec == birth.tv_usec {
                var status: Int32 = 0
                let result = waitpid(pid_t(pid), &status, WNOHANG)
                if result == pid_t(pid) { return }
                if result < 0, errno != EINTR { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private static func processInfo(_ pid: Int) -> kinfo_proc? {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        let result = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, UInt32($0.count), &info, &size, nil, 0)
        }
        return result == 0 && size > 0 ? info : nil
    }

    private static func terminate(_ pid: Int) -> Bool {
        Darwin.kill(pid_t(pid), SIGTERM) == 0 || errno == ESRCH
    }
}
