import Foundation
import IOKit.pwr_mgt
import Observation

/// Keep Awake lasts until it is switched off or Relay Runner quits, including idle
/// periods and with the lid closed. It is never persisted: every launch starts off.
///
/// Media keeps playing with the lid closed only while two protections hold: Relay's
/// idle-system and idle-display assertions, and the system-wide `pmset disablesleep`
/// override (closing the lid ignores assertions). The override is re-checked while on,
/// because another app restoring sleep clears it for everyone.
enum KeepAwakeState: Equatable {
    case off
    case enabling
    /// `ownsSleepSetting` is false when another app had already disabled system sleep.
    case on(ownsSleepSetting: Bool)
    case disabling
    case failed(String)
    /// Relay may have left system sleep disabled; activating retries an approved restore.
    case restoreNeeded(String)

    static let label = "Keep Awake"
    static let description = "Keep your Mac and its display awake, even with the lid closed, until you turn this off or quit Relay Runner. Turning it on asks for administrator approval."

    var isOn: Bool {
        if case .on = self { return true }
        return false
    }

    var isPending: Bool { self == .enabling || self == .disabling }

    var actionTitle: String {
        switch self {
        case .on: return "Turn off Keep Awake"
        case .restoreNeeded: return "Restore sleep"
        default: return "Turn on Keep Awake"
        }
    }

    var status: String {
        switch self {
        case .off: return "Keep Awake is off."
        case .enabling: return "Waiting for administrator approval…"
        case .on(true): return "Keep Awake is on, including with the lid closed."
        case .on(false): return "Keep Awake is on. Another app had already disabled sleep, so Relay Runner leaves that setting to it and asks for approval if sleep is turned back on."
        case .disabling: return "Restoring sleep…"
        case .failed(let message), .restoreNeeded(let message): return message
        }
    }
}

/// Host effects, injected so tests never prompt for administrator access or change power settings.
struct KeepAwakeSystem {
    enum Approval: Equatable { case approved, canceled, failed }

    /// `pmset -g`'s system-wide SleepDisabled value; nil when unreadable.
    var sleepDisabled: () -> Bool?
    /// Starts a root watchdog that restores sleep once `lease` disappears or `pid` exits,
    /// then disables system sleep.
    var disableSleep: (_ lease: URL, _ pid: Int32) -> Approval
    var restoreSleep: () -> Approval
    /// Quit: ends any in-flight administrator approval and refuses new ones.
    /// `sleepDisabled` stays available so quit can still confirm the restore.
    var cancelApproval: () -> Void
    /// Holds both the idle-system and idle-display sleep assertions; nil unless both are held.
    var holdAssertions: () -> NSObjectProtocol?
    var releaseAssertions: (NSObjectProtocol) -> Void
    var pause: (TimeInterval) -> Void
}

@Observable
final class KeepAwakeController {
    static let restorePollInterval: TimeInterval = 0.25
    static let restoreTimeout: TimeInterval = 5
    static let quitRestoreTimeout: TimeInterval = 2
    /// How often an on state re-reads the system-wide sleep override.
    static let monitorInterval: TimeInterval = 5
    static let lostSettingContext = "Sleep was turned back on outside Relay Runner. "

    private(set) var state: KeepAwakeState = .off

    @ObservationIgnored private let system: KeepAwakeSystem
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let pid: Int32
    @ObservationIgnored private let work: (@escaping () -> Void) -> Void
    @ObservationIgnored private let main: (@escaping () -> Void) -> Void
    @ObservationIgnored private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    @ObservationIgnored private let log: (String) -> Void
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var assertions: NSObjectProtocol?

    /// Deleting the lease tells the root watchdog to restore sleep.
    var leaseURL: URL { directory.appendingPathComponent("keep-awake-lease") }
    /// Cleared only after a confirmed restore, so an interrupted run is recovered at launch.
    var recoveryURL: URL { directory.appendingPathComponent("keep-awake-recovery") }

    init(
        system: KeepAwakeSystem = .live(),
        directory: URL = KeepAwakeController.defaultDirectory,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        work: @escaping (@escaping () -> Void) -> Void = { job in
            KeepAwakeController.queue.async(execute: job)
        },
        main: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, job in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
        },
        log: @escaping (String) -> Void = { NSLog("[RelayRunner] %@", $0) }
    ) {
        self.system = system
        self.directory = directory
        self.pid = pid
        self.work = work
        self.main = main
        self.schedule = schedule
        self.log = log
    }

    static let defaultDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("relay-runner", isDirectory: true)
    // One serial queue keeps every sleep-setting mutation ordered.
    static let queue = DispatchQueue(label: "com.relay-runner.keep-awake", qos: .userInitiated)

    /// Returns false when the request was ignored because a change is still pending.
    @discardableResult
    func toggle() -> Bool {
        guard !shutDown else { return false }
        switch state {
        case .off, .failed: enable()
        case .on(let owns): disable(owns: owns)
        case .restoreNeeded: restore()
        case .enabling, .disabling: return false
        }
        return true
    }

    /// Restores a sleep setting left disabled by a crash, power loss, or failed restore.
    func recoverIfNeeded() {
        let files = FileManager.default
        guard files.fileExists(atPath: recoveryURL.path) || files.fileExists(atPath: leaseURL.path) else { return }
        let generation = begin(.disabling)
        work { [self] in
            let restored = releaseLeaseAndConfirm()
            finish(generation, restored ? .off : .restoreNeeded(
                "Sleep may still be disabled from an earlier Relay Runner session. Activate Keep Awake to restore it with administrator approval."))
        }
    }

    /// Quit and update relaunch: release synchronously. The root watchdog restores sleep
    /// even if confirmation times out, and the recovery record covers anything left over.
    func shutdown() {
        generation += 1
        lock.lock()
        let alreadyShutDown = isShutDown
        isShutDown = true
        lock.unlock()
        guard !alreadyShutDown else { return }
        system.cancelApproval()
        releaseAssertions()
        if FileManager.default.fileExists(atPath: recoveryURL.path)
            || FileManager.default.fileExists(atPath: leaseURL.path) {
            if releaseLeaseAndConfirm(timeout: Self.quitRestoreTimeout) {
                log("Keep Awake released at quit; sleep restored")
            } else {
                log("Keep Awake released at quit; sleep restore unconfirmed")
            }
        }
        state = .off
    }

    private func enable() {
        // Assertions come first, so nothing reports on without them.
        if assertions == nil { assertions = system.holdAssertions() }
        guard assertions != nil else {
            generation += 1
            state = .failed("Couldn't keep this Mac awake. Keep Awake is off.")
            log("Keep Awake could not hold its sleep assertions")
            return
        }
        let generation = begin(.enabling)
        work { [self] in
            guard let disabled = system.sleepDisabled() else {
                finish(generation, .failed("Couldn't read this Mac's sleep settings. Keep Awake is off."))
                return
            }
            finish(generation, disabled ? .on(ownsSleepSetting: false) : takeOwnership())
        }
    }

    /// Records ownership, then asks for approval to disable sleep. Re-entering keeps an
    /// existing lease in place, so an earlier watchdog never sees it disappear.
    private func takeOwnership(context: String = "") -> KeepAwakeState {
        let approval = writeOwnershipFiles() ? system.disableSleep(leaseURL, pid) : .failed
        if approval == .approved, system.sleepDisabled() == true {
            return .on(ownsSleepSetting: true)
        }
        // A partial change is undone by the watchdog once the lease is gone.
        guard releaseLeaseAndConfirm() else {
            return .restoreNeeded(context
                + "Couldn't confirm sleep was restored. Activate Keep Awake to restore it with administrator approval.")
        }
        return .failed(context + (approval == .canceled
            ? "Administrator approval was canceled. Keep Awake is off."
            : "Couldn't turn on Keep Awake. Sleep settings weren't changed."))
    }

    /// Another app (or a restore) re-enabled sleep while Keep Awake was on, so closing the
    /// lid would sleep the Mac. Ask to take over rather than keep reporting a false on.
    private func sleepSettingLost() {
        log("Keep Awake lost the disabled sleep setting; asking to restore it")
        let generation = begin(.enabling)
        work { [self] in
            finish(generation, takeOwnership(context: Self.lostSettingContext))
        }
    }

    private func monitor(_ generation: Int) {
        schedule(Self.monitorInterval) { [self] in
            guard generation == self.generation, state.isOn, !shutDown else { return }
            work { [self] in
                let disabled = system.sleepDisabled()
                main { [self] in
                    guard generation == self.generation, state.isOn, !shutDown else { return }
                    // An unreadable report is not evidence the setting is gone.
                    if disabled == false { sleepSettingLost() } else { monitor(generation) }
                }
            }
        }
    }

    private func disable(owns: Bool) {
        releaseAssertions()
        guard owns else {
            // Another app owns the disabled sleep setting; leave it as it was.
            generation += 1
            state = .off
            log("Keep Awake off; sleep setting left to its owner")
            return
        }
        let generation = begin(.disabling)
        work { [self] in
            finish(generation, releaseLeaseAndConfirm() ? .off : .restoreNeeded(
                "Couldn't confirm sleep was restored. Activate Keep Awake to restore it with administrator approval."))
        }
    }

    private func restore() {
        let generation = begin(.disabling)
        work { [self] in
            if releaseLeaseAndConfirm(timeout: Self.restorePollInterval) {
                finish(generation, .off)
                return
            }
            let approval = system.restoreSleep()
            if approval == .approved, releaseLeaseAndConfirm() {
                finish(generation, .off)
            } else {
                finish(generation, .restoreNeeded(approval == .canceled
                    ? "Administrator approval was canceled. Sleep is still disabled."
                    : "Couldn't restore sleep. Activate Keep Awake to try again."))
            }
        }
    }

    private func begin(_ pending: KeepAwakeState) -> Int {
        generation += 1
        state = pending
        return generation
    }

    private func finish(_ generation: Int, _ result: KeepAwakeState) {
        main { [self] in
            // A newer request or quit supersedes this result.
            guard generation == self.generation, !shutDown else { return }
            state = result
            log("Keep Awake state=\(result.logName)")
            if result.isOn { monitor(generation) } else { releaseAssertions() }
        }
    }

    private var shutDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShutDown
    }

    private func releaseAssertions() {
        if let assertions { system.releaseAssertions(assertions) }
        assertions = nil
    }

    private func writeOwnershipFiles() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutDown else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: recoveryURL, options: .atomic)
            try Data().write(to: leaseURL, options: .atomic)
            return true
        } catch {
            log("Keep Awake could not write its ownership files")
            return false
        }
    }

    /// Deletes the lease, then waits for a readable report that sleep is enabled.
    /// An unreadable report never counts as restored. The deadline keeps a slow read
    /// from stretching the wait (quit blocks on it).
    private func releaseLeaseAndConfirm(timeout: TimeInterval = KeepAwakeController.restoreTimeout) -> Bool {
        try? FileManager.default.removeItem(at: leaseURL)
        let deadline = Date().addingTimeInterval(timeout)
        let attempts = max(1, Int((timeout / Self.restorePollInterval).rounded(.up)))
        for attempt in 0..<attempts {
            if system.sleepDisabled() == false {
                try? FileManager.default.removeItem(at: recoveryURL)
                return true
            }
            guard Date() < deadline else { break }
            if attempt < attempts - 1 { system.pause(Self.restorePollInterval) }
        }
        return false
    }
}

private extension KeepAwakeState {
    var logName: String {
        switch self {
        case .off: return "off"
        case .enabling: return "enabling"
        case .on(let owns): return owns ? "on-owned" : "on-external"
        case .disabling: return "disabling"
        case .failed: return "failed"
        case .restoreNeeded: return "restore-needed"
        }
    }
}

/// Fixed commands only: the lease path and pid are validated, never user text.
enum KeepAwakeCommand {
    static let approvalTimeout: TimeInterval = 120
    static let readTimeout: TimeInterval = 5

    static func sleepDisabled(inPmsetOutput output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.first == "SleepDisabled", fields.count >= 2 else { continue }
            switch fields[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// The watchdog starts before the change, so no successful change can outlive Relay
    /// Runner or the lease. It exits after restoring sleep.
    static func disableScript(lease: String, pid: Int32) -> String? {
        let forbidden = CharacterSet(charactersIn: "'\"\\$`").union(.newlines).union(.controlCharacters)
        guard pid > 0, lease.hasPrefix("/"), lease.rangeOfCharacter(from: forbidden) == nil else { return nil }
        return "( while /bin/kill -0 \(pid) 2>/dev/null && /bin/test -e '\(lease)'; do /bin/sleep 1; done; "
            + "/usr/bin/pmset -a disablesleep 0 ) >/dev/null 2>&1 & /usr/bin/pmset -a disablesleep 1"
    }

    static let restoreScript = "/usr/bin/pmset -a disablesleep 0"

    static func appleScript(_ shell: String) -> String {
        "do shell script \"\(shell)\" with prompt \"Relay Runner needs administrator approval to change this Mac's sleep setting.\" with administrator privileges"
    }

    static func approval(status: Int32?, output: String) -> KeepAwakeSystem.Approval {
        guard let status else { return .failed }
        if status == 0 { return .approved }
        // osascript reports "User canceled. (-128)".
        return output.contains("-128") ? .canceled : .failed
    }
}

/// Runs bounded child processes; `cancel` terminates the current one and refuses new ones.
final class KeepAwakeCommandRunner {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32?, output: String) {
        let process = Process()
        let pipe = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { _ in exited.signal() }
        lock.lock()
        guard !cancelled, (try? process.run()) != nil else {
            lock.unlock()
            return (nil, "")
        }
        self.process = process
        lock.unlock()
        try? pipe.fileHandleForWriting.close()
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
        }
        lock.lock()
        self.process = nil
        lock.unlock()
        let output = Self.drain(pipe.fileHandleForReading.fileDescriptor)
        return (timedOut || process.isRunning ? nil : process.terminationStatus, output)
    }

    /// Never blocks on a descendant that might still hold the pipe open.
    private static func drain(_ descriptor: Int32) -> String {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65_536 {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        process?.terminate()
        lock.unlock()
    }
}

extension KeepAwakeSystem {
    /// Approvals and bounded `pmset -g` reads use separate runners, so canceling
    /// approval at quit never blocks the reads that confirm the restore.
    static func live(
        approvals: KeepAwakeCommandRunner = KeepAwakeCommandRunner(),
        reads: KeepAwakeCommandRunner = KeepAwakeCommandRunner()
    ) -> KeepAwakeSystem {
        func approve(_ shell: String) -> Approval {
            let result = approvals.run("/usr/bin/osascript", ["-e", KeepAwakeCommand.appleScript(shell)],
                                       timeout: KeepAwakeCommand.approvalTimeout)
            return KeepAwakeCommand.approval(status: result.status, output: result.output)
        }
        return KeepAwakeSystem(
            sleepDisabled: {
                let result = reads.run("/usr/bin/pmset", ["-g"], timeout: KeepAwakeCommand.readTimeout)
                guard result.status == 0 else { return nil }
                return KeepAwakeCommand.sleepDisabled(inPmsetOutput: result.output)
            },
            disableSleep: { lease, pid in
                guard let shell = KeepAwakeCommand.disableScript(lease: lease.path, pid: pid) else { return .failed }
                return approve(shell)
            },
            restoreSleep: { approve(KeepAwakeCommand.restoreScript) },
            cancelApproval: { approvals.cancel() },
            holdAssertions: { KeepAwakeAssertions.hold() },
            releaseAssertions: { ($0 as? KeepAwakeAssertions)?.release() },
            pause: { Thread.sleep(forTimeInterval: $0) }
        )
    }
}

/// Named IOKit assertions report failure, unlike a ProcessInfo activity. Holding the
/// display assertion too matches Vorssaint's default Keep Awake.
final class KeepAwakeAssertions: NSObject {
    private var ids: [IOPMAssertionID]

    private init(_ ids: [IOPMAssertionID]) { self.ids = ids }

    static func hold() -> KeepAwakeAssertions? {
        var ids: [IOPMAssertionID] = []
        for type in [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] {
            var id = IOPMAssertionID(0)
            guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                              "Keep Awake is on in Relay Runner." as CFString, &id) == kIOReturnSuccess else {
                ids.forEach { IOPMAssertionRelease($0) }
                return nil
            }
            ids.append(id)
        }
        return KeepAwakeAssertions(ids)
    }

    func release() {
        ids.forEach { IOPMAssertionRelease($0) }
        ids = []
    }

    deinit { release() }
}
