import Foundation
import IOKit.pwr_mgt
import Observation
import RelayPowerHelperProtocol

/// Keep Awake lasts until it is switched off or Relay Runner quits, including idle
/// periods and with the lid closed. It is never persisted: every launch starts off.
///
/// Media keeps playing with the lid closed only while two protections hold: Relay's
/// idle-system and idle-display assertions, and the system-wide `pmset disablesleep`
/// override (closing the lid ignores assertions). Relay's power helper, a launchd daemon
/// the user allows once in System Settings, sets that override for as long as the app
/// holds it. The override is re-checked while on, because another app restoring sleep
/// clears it for everyone. While on with the lid closed, the built-in display is dimmed.
enum KeepAwakeState: Equatable {
    case off
    case enabling
    /// Waiting for the user to allow Relay's power helper, which macOS asks only once.
    case awaitingApproval
    /// `ownsSleepSetting` is false when another app had already disabled system sleep.
    case on(ownsSleepSetting: Bool)
    case disabling
    case failed(String)
    /// Relay may have left system sleep disabled; activating retries the restore.
    case restoreNeeded(String)

    static let label = "Keep Awake"
    static let description = "Keep your Mac and its display awake, even with the lid closed, until you turn this off or quit Relay Runner. The built-in display goes dark while the lid is closed. The first time, macOS asks you to allow Relay Runner's power helper."

    var isOn: Bool {
        if case .on = self { return true }
        return false
    }

    /// Clicks are ignored until a pending change settles. Waiting for approval can be canceled.
    var isPending: Bool { self == .enabling || self == .disabling }

    var actionTitle: String {
        switch self {
        case .on: return "Turn off Keep Awake"
        case .awaitingApproval: return "Cancel Keep Awake"
        case .restoreNeeded: return "Restore sleep"
        default: return "Turn on Keep Awake"
        }
    }

    var status: String {
        switch self {
        case .off: return "Keep Awake is off."
        case .enabling: return "Turning on Keep Awake…"
        case .awaitingApproval:
            return "Allow Relay Runner in \(KeepAwakePowerHelper.approvalPlace) to finish turning on Keep Awake. macOS asks only once."
        case .on(true): return "Keep Awake is on, including with the lid closed."
        case .on(false): return "Keep Awake is on. Another app had already disabled sleep, so Relay Runner leaves that setting to it and takes it over if sleep is turned back on."
        case .disabling: return "Restoring sleep…"
        case .failed(let message), .restoreNeeded(let message): return message
        }
    }
}

/// Host effects, injected so tests never register the helper or change power settings.
struct KeepAwakeSystem {
    enum Helper: Equatable {
        case ready
        /// macOS needs the user to allow the helper in System Settings.
        case needsApproval
        /// Missing, rejected, or not responding; the message says what to do.
        case unavailable(String)
    }

    enum Hold: Equatable { case held, heldElsewhere, failed }

    /// `pmset -g`'s system-wide SleepDisabled value; nil when unreadable.
    var sleepDisabled: () -> Bool?
    /// Never prompts.
    var helperStatus: () -> Helper
    /// Registers the helper and opens its one-time approval in System Settings when needed.
    var requestApproval: () -> Helper
    /// The helper disables sleep until this app releases it or disconnects.
    var disableSleep: () -> Hold
    /// The helper restores sleep it disabled once this app no longer holds it.
    var releaseSleep: () -> Bool
    /// The helper re-enables sleep left disabled by an earlier session.
    var restoreSleep: () -> Bool
    /// Quit: refuses new requests and ends the helper connection, which ends this app's hold.
    /// `sleepDisabled` stays available so quit can still confirm the restore.
    var close: () -> Void
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
    /// How often an on state re-reads the system-wide sleep override and the lid.
    static let monitorInterval: TimeInterval = 5
    /// How long turning on waits for the one-time approval before giving up.
    static let approvalTimeout: TimeInterval = 120
    static let approvalPollInterval: TimeInterval = 1
    static let lostSettingContext = "Sleep was turned back on outside Relay Runner. "
    static let approvalMissingMessage = "Keep Awake needs your approval once. Allow Relay Runner in \(KeepAwakePowerHelper.approvalPlace), then turn on Keep Awake again."
    static let restoreApprovalMessage = "Restoring sleep needs Relay Runner's power helper. Allow Relay Runner in \(KeepAwakePowerHelper.approvalPlace), then choose Restore sleep again."
    static let unconfirmedRestoreMessage = "Couldn't confirm sleep was restored. Activate Keep Awake to restore it."
    static let unchangedMessage = "Couldn't turn on Keep Awake. Sleep settings weren't changed."

    private(set) var state: KeepAwakeState = .off
    /// Main thread, after each change: the previous state, then the new one.
    @ObservationIgnored var onStateChange: ((KeepAwakeState, KeepAwakeState) -> Void)?

    @ObservationIgnored private let system: KeepAwakeSystem
    @ObservationIgnored private let dimmer: KeepAwakeLidDimmer
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let work: (@escaping () -> Void) -> Void
    @ObservationIgnored private let main: (@escaping () -> Void) -> Void
    @ObservationIgnored private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    @ObservationIgnored private let log: (String) -> Void
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var storedGeneration = 0
    @ObservationIgnored private var assertions: NSObjectProtocol?

    /// Cleared only after a confirmed restore, so an interrupted run is recovered at launch.
    var recoveryURL: URL { directory.appendingPathComponent("keep-awake-recovery") }
    /// Builds before the power helper ran a root watchdog that restored sleep once this
    /// file disappeared. Deleting it migrates a session those builds left running.
    var legacyLeaseURL: URL { directory.appendingPathComponent("keep-awake-lease") }
    var brightnessRecordURL: URL { dimmer.recordURL }

    init(
        system: KeepAwakeSystem = .live(),
        display: KeepAwakeDisplay = .live(),
        directory: URL = KeepAwakeController.defaultDirectory,
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
        self.work = work
        self.main = main
        self.schedule = schedule
        self.log = log
        dimmer = KeepAwakeLidDimmer(display: display,
                                    recordURL: directory.appendingPathComponent("keep-awake-brightness"),
                                    schedule: schedule, log: log)
    }

    static let defaultDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("relay-runner", isDirectory: true)
    // One serial queue keeps every sleep-setting change ordered.
    static let queue = DispatchQueue(label: "com.relay-runner.keep-awake", qos: .userInitiated)

    /// Returns false when the request was ignored because a change is still pending.
    @discardableResult
    func toggle() -> Bool {
        guard !shutDown else { return false }
        switch state {
        case .off, .failed: enable()
        case .awaitingApproval: cancelApproval()
        case .on(let owns): disable(owns: owns)
        case .restoreNeeded: restore()
        case .enabling, .disabling: return false
        }
        return true
    }

    /// Restores a sleep setting or brightness left behind by a crash, power loss, or failed restore.
    func recoverIfNeeded() {
        dimmer.recoverIfNeeded()
        let files = FileManager.default
        guard files.fileExists(atPath: recoveryURL.path) || files.fileExists(atPath: legacyLeaseURL.path) else { return }
        let generation = begin(.disabling)
        work { [self] in
            // A legacy watchdog restores once its lease is gone; the helper restores when the app disconnects.
            try? FileManager.default.removeItem(at: legacyLeaseURL)
            finish(generation, confirmRestored() ? .off : .restoreNeeded(
                "Sleep may still be disabled from an earlier Relay Runner session. Activate Keep Awake to restore it."))
        }
    }

    /// Quit and update relaunch: release synchronously. Closing the helper connection ends
    /// this app's hold even if confirmation times out, and the recovery record covers the rest.
    func shutdown() {
        generation += 1
        lock.lock()
        let alreadyShutDown = isShutDown
        isShutDown = true
        lock.unlock()
        guard !alreadyShutDown else { return }
        system.close()
        dimmer.shutdown()
        releaseAssertions()
        if FileManager.default.fileExists(atPath: recoveryURL.path)
            || FileManager.default.fileExists(atPath: legacyLeaseURL.path) {
            try? FileManager.default.removeItem(at: legacyLeaseURL)
            if confirmRestored(timeout: Self.quitRestoreTimeout) {
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
            setState(.failed("Couldn't keep this Mac awake. Keep Awake is off."))
            log("Keep Awake could not hold its sleep assertions")
            return
        }
        let generation = begin(.enabling)
        work { [self] in
            guard let disabled = system.sleepDisabled() else {
                finish(generation, .failed("Couldn't read this Mac's sleep settings. Keep Awake is off."))
                return
            }
            // Another app's override needs no helper, and Relay never changes or resets it.
            if disabled {
                finish(generation, .on(ownsSleepSetting: false))
            } else if let result = takeOwnership(generation) {
                finish(generation, result)
            }
        }
    }

    /// Records ownership, then asks the approved helper to disable sleep. Returns nil when
    /// a cancel, newer request, or quit ended the wait for approval.
    private func takeOwnership(_ generation: Int, context: String = "") -> KeepAwakeState? {
        guard let helper = approvedHelper(generation) else { return nil }
        guard helper == .ready else {
            if case .unavailable(let message) = helper { return .failed(context + message) }
            return .failed(context + Self.approvalMissingMessage)
        }
        guard writeRecoveryRecord() else { return .failed(context + Self.unchangedMessage) }
        switch system.disableSleep() {
        case .held where system.sleepDisabled() == true:
            return .on(ownsSleepSetting: true)
        case .heldElsewhere:
            // Another app disabled sleep first; the helper changed nothing.
            try? FileManager.default.removeItem(at: recoveryURL)
            return .on(ownsSleepSetting: false)
        default:
            // A partial change is undone once the helper releases it.
            guard releaseAndConfirm() else { return .restoreNeeded(context + Self.unconfirmedRestoreMessage) }
            return .failed(context + Self.unchangedMessage)
        }
    }

    /// The helper's state once any first-use approval is settled. Waits, bounded, for the user
    /// to allow it in System Settings, showing an actionable pending state meanwhile.
    private func approvedHelper(_ generation: Int) -> KeepAwakeSystem.Helper? {
        var helper = system.helperStatus()
        guard isCurrent(generation) else { return nil }
        guard helper == .needsApproval else { return helper }
        helper = system.requestApproval()
        guard helper == .needsApproval else { return helper }
        log("Keep Awake waiting for the power helper's approval")
        main { [self] in if isCurrent(generation) { setState(.awaitingApproval) } }
        let attempts = max(1, Int((Self.approvalTimeout / Self.approvalPollInterval).rounded(.up)))
        for _ in 0..<attempts {
            system.pause(Self.approvalPollInterval)
            guard isCurrent(generation) else { return nil }
            helper = system.helperStatus()
            if helper != .needsApproval {
                main { [self] in if isCurrent(generation) { setState(.enabling) } }
                return helper
            }
        }
        return .unavailable(Self.approvalMissingMessage)
    }

    private func cancelApproval() {
        log("Keep Awake approval canceled")
        // A takeover that was waiting still has a recovery record to settle.
        guard !FileManager.default.fileExists(atPath: recoveryURL.path) else { return disable(owns: true) }
        generation += 1
        releaseAssertions()
        setState(.off)
    }

    /// Another app (or a restore) re-enabled sleep while Keep Awake was on, so closing the
    /// lid would sleep the Mac. Take it back rather than keep reporting a false on.
    private func sleepSettingLost() {
        log("Keep Awake lost the disabled sleep setting; taking it back")
        let generation = begin(.enabling)
        work { [self] in
            if let result = takeOwnership(generation, context: Self.lostSettingContext) { finish(generation, result) }
        }
    }

    private func monitor(_ generation: Int) {
        schedule(Self.monitorInterval) { [self] in
            guard isCurrent(generation), state.isOn else { return }
            // Covers a lid message that never arrived.
            dimmer.refresh()
            work { [self] in
                let disabled = system.sleepDisabled()
                main { [self] in
                    guard isCurrent(generation), state.isOn else { return }
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
            setState(.off)
            log("Keep Awake off; sleep setting left to its owner")
            return
        }
        let generation = begin(.disabling)
        work { [self] in
            finish(generation, releaseAndConfirm() ? .off : .restoreNeeded(Self.unconfirmedRestoreMessage))
        }
    }

    private func restore() {
        let generation = begin(.disabling)
        work { [self] in
            if confirmRestored(timeout: Self.restorePollInterval) {
                finish(generation, .off)
                return
            }
            var helper = system.helperStatus()
            if helper == .needsApproval { helper = system.requestApproval() }
            switch helper {
            case .ready:
                finish(generation, system.restoreSleep() && confirmRestored()
                    ? .off : .restoreNeeded("Couldn't restore sleep. Activate Keep Awake to try again."))
            case .needsApproval:
                finish(generation, .restoreNeeded(Self.restoreApprovalMessage))
            case .unavailable(let message):
                finish(generation, .restoreNeeded(message))
            }
        }
    }

    private func begin(_ pending: KeepAwakeState) -> Int {
        generation += 1
        setState(pending)
        return generation
    }

    private func finish(_ generation: Int, _ result: KeepAwakeState) {
        main { [self] in
            // A newer request or quit supersedes this result.
            guard isCurrent(generation) else { return }
            setState(result)
            log("Keep Awake state=\(result.logName)")
            if result.isOn { monitor(generation) } else { releaseAssertions() }
        }
    }

    /// Dimming follows only a confirmed on state.
    private func setState(_ next: KeepAwakeState) {
        let previous = state
        state = next
        dimmer.setActive(next.isOn)
        if previous != next { onStateChange?(previous, next) }
    }

    /// Main-thread writes; the approval wait reads it to stop once superseded.
    private var generation: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedGeneration
        }
        set {
            lock.lock()
            storedGeneration = newValue
            lock.unlock()
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == storedGeneration && !isShutDown
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

    private func writeRecoveryRecord() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutDown else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: recoveryURL, options: .atomic)
            return true
        } catch {
            log("Keep Awake could not write its recovery record")
            return false
        }
    }

    private func releaseAndConfirm() -> Bool {
        _ = system.releaseSleep()
        return confirmRestored()
    }

    /// Waits for a readable report that sleep is enabled, then clears the recovery record.
    /// An unreadable report never counts as restored. The deadline keeps a slow read from
    /// stretching the wait (quit blocks on it).
    private func confirmRestored(timeout: TimeInterval = KeepAwakeController.restoreTimeout) -> Bool {
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
        case .awaitingApproval: return "awaiting-approval"
        case .on(let owns): return owns ? "on-owned" : "on-external"
        case .disabling: return "disabling"
        case .failed: return "failed"
        case .restoreNeeded: return "restore-needed"
        }
    }
}

extension KeepAwakeSystem {
    static let readTimeout: TimeInterval = 5

    /// Unprivileged `pmset -g` reads stay in the app; every change goes through the helper.
    static func live(helper: KeepAwakePowerHelper = KeepAwakePowerHelper()) -> KeepAwakeSystem {
        KeepAwakeSystem(
            sleepDisabled: {
                let result = RelayPowerCommandRunner.run(RelayPowerSettings.pmset, RelayPowerSettings.readArguments,
                                                         timeout: readTimeout)
                guard result.status == 0 else { return nil }
                return RelayPowerSettings.sleepDisabled(inPmsetOutput: result.output)
            },
            helperStatus: helper.status,
            requestApproval: helper.requestApproval,
            disableSleep: helper.hold,
            releaseSleep: helper.release,
            restoreSleep: helper.restore,
            close: helper.close,
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
