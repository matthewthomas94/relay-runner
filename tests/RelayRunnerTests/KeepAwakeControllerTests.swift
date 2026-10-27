import Foundation
import RelayPowerHelperProtocol
import XCTest
@testable import relay_runner

extension KeepAwakeSystem {
    /// Never reads or changes host power settings or registers the helper.
    static var inert: KeepAwakeSystem {
        KeepAwakeSystem(sleepDisabled: { nil }, helperStatus: { .unavailable("inert") },
                        requestApproval: { .unavailable("inert") }, disableSleep: { .failed },
                        releaseSleep: { false }, restoreSleep: { false }, close: {},
                        holdAssertions: { nil }, releaseAssertions: { _ in }, pause: { _ in })
    }
}

/// Simulates pmset, the power helper, and its one-time macOS approval in memory.
/// Like the live client, closing refuses new requests but never `pmset -g` reads, and
/// the helper restores sleep it disabled once this app disconnects.
private final class FakePowerHost {
    var sleepDisabled: Bool? = false
    /// What SMAppService reports. The approval persists across relaunches.
    var helper: KeepAwakeSystem.Helper = .ready
    /// The user allows the helper in System Settings after this many approval polls.
    var approvesAfterPolls: Int?
    var holdResult: KeepAwakeSystem.Hold = .held
    var holdChangesSetting = true
    var releaseRestores = true
    var restoreResult = true
    var assertionsAvailable = true
    var duringHold: () -> Void = {}
    var onPause: () -> Void = {}
    var recoveryURL: URL?
    private(set) var holdCalls: [Bool] = []
    private(set) var releaseCalls = 0
    private(set) var restoreCalls = 0
    private(set) var closeCalls = 0
    private(set) var approvalRequests = 0
    private(set) var statusChecks = 0
    private(set) var pauses = 0
    private(set) var begun = 0
    private(set) var ended = 0
    private(set) var reads = 0
    private(set) var held = false
    private var closed = false
    private var approvalPolls = 0

    /// A new process connects afresh; the power setting and the approval persist.
    func relaunch() { closed = false }

    private func disconnect() {
        guard held else { return }
        held = false
        if releaseRestores { sleepDisabled = false }
    }

    var system: KeepAwakeSystem {
        KeepAwakeSystem(
            sleepDisabled: { [self] in
                reads += 1
                return sleepDisabled
            },
            helperStatus: { [self] in
                statusChecks += 1
                if helper == .needsApproval, let approvesAfterPolls, approvalPolls >= approvesAfterPolls {
                    helper = .ready
                }
                return helper
            },
            requestApproval: { [self] in
                guard !closed else { return .unavailable(KeepAwakePowerHelper.quittingMessage) }
                approvalRequests += 1
                return helper
            },
            disableSleep: { [self] in
                guard !closed else { return .failed }
                holdCalls.append(recoveryURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
                if holdResult == .held, holdChangesSetting {
                    held = true
                    sleepDisabled = true
                }
                duringHold()
                // Quit closes the connection mid-request: no reply, and the helper releases it.
                return closed ? .failed : holdResult
            },
            releaseSleep: { [self] in
                guard !closed else { return false }
                releaseCalls += 1
                disconnect()
                return true
            },
            restoreSleep: { [self] in
                guard !closed else { return false }
                restoreCalls += 1
                if restoreResult { sleepDisabled = false }
                return restoreResult
            },
            close: { [self] in
                closeCalls += 1
                closed = true
                disconnect()
            },
            holdAssertions: { [self] in
                guard assertionsAvailable else { return nil }
                begun += 1
                return NSObject()
            },
            releaseAssertions: { [self] _ in ended += 1 },
            pause: { [self] _ in
                pauses += 1
                if helper == .needsApproval { approvalPolls += 1 }
                onPause()
            }
        )
    }
}

/// The lid and built-in display. Brightness reads report what was last written, like a real panel.
private final class FakeLidDisplay {
    var lidClosed: Bool? = false
    var brightness: Float? = 0.7
    var failWrites = false
    private(set) var writes: [Float] = []
    private var changed: (() -> Void)?
    private weak var token: AnyObject?

    var isObserving: Bool { token != nil }

    func moveLid(closed: Bool?) {
        lidClosed = closed
        if isObserving { changed?() }
    }

    var display: KeepAwakeDisplay {
        KeepAwakeDisplay(
            lidClosed: { [self] in lidClosed },
            observeLid: { [self] changed in
                let token = NSObject()
                self.token = token
                self.changed = changed
                return token
            },
            brightness: { [self] in brightness },
            setBrightness: { [self] value in
                writes.append(value)
                guard !failWrites else { return false }
                brightness = value
                return true
            }
        )
    }
}

final class KeepAwakeControllerTests: XCTestCase {
    private var directory: URL!
    private var host: FakePowerHost!
    private var display: FakeLidDisplay!
    private var work: [() -> Void] = []
    private var main: [() -> Void] = []
    private var scheduled: [(delay: TimeInterval, job: () -> Void)] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-awake-\(UUID().uuidString)", isDirectory: true)
        host = FakePowerHost()
        host.recoveryURL = directory.appendingPathComponent("keep-awake-recovery")
        display = FakeLidDisplay()
        work = []
        main = []
        scheduled = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeController(queued: Bool = false) -> KeepAwakeController {
        KeepAwakeController(
            system: host.system, display: display.display, directory: directory,
            work: { [unowned self] job in queued ? work.append(job) : job() },
            main: { [unowned self] job in queued ? main.append(job) : job() },
            schedule: { [unowned self] delay, job in scheduled.append((delay, job)) },
            log: { _ in }
        )
    }

    private func drain() {
        while !work.isEmpty || !main.isEmpty {
            if !work.isEmpty { work.removeFirst()() } else { main.removeFirst()() }
        }
    }

    private func drainMain() {
        while !main.isEmpty { main.removeFirst()() }
    }

    /// Runs the pending sleep-setting checks, as the monitor timer would.
    private func runMonitor() {
        let jobs = scheduled.filter { $0.delay == KeepAwakeController.monitorInterval }
        scheduled.removeAll { $0.delay == KeepAwakeController.monitorInterval }
        jobs.forEach { $0.job() }
        drain()
    }

    private var monitorScheduled: Bool {
        scheduled.contains { $0.delay == KeepAwakeController.monitorInterval }
    }

    private func recoveryExists(_ controller: KeepAwakeController) -> Bool {
        FileManager.default.fileExists(atPath: controller.recoveryURL.path)
    }

    // MARK: Lifecycle

    func testFreshLaunchIsOffWithoutTouchingPowerSettingsTheHelperOrTheDisplay() {
        let controller = makeController()
        controller.recoverIfNeeded()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.reads, 0)
        XCTAssertEqual(host.statusChecks, 0)
        XCTAssertTrue(host.holdCalls.isEmpty)
        XCTAssertEqual(host.begun, 0)
        XCTAssertTrue(display.writes.isEmpty)
        XCTAssertFalse(display.isObserving)
    }

    func testApprovedHelperIsReusedForEveryToggleAndRelaunchWithoutAnApprovalRequest() {
        let controller = makeController()
        XCTAssertTrue(controller.toggle())
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.holdCalls, [true], "Recovery is recorded before the helper changes sleep")
        XCTAssertEqual(host.begun, 1)

        // Off releases through the helper, with no prompt.
        XCTAssertTrue(controller.toggle())
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false)
        XCTAssertEqual(host.releaseCalls, 1)
        XCTAssertEqual(host.ended, 1)
        XCTAssertFalse(recoveryExists(controller))

        controller.toggle()
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        controller.shutdown()

        host.relaunch()
        let relaunched = makeController()
        relaunched.recoverIfNeeded()
        relaunched.toggle()
        XCTAssertEqual(relaunched.state, .on(ownsSleepSetting: true))
        relaunched.toggle()
        XCTAssertEqual(relaunched.state, .off)
        XCTAssertEqual(host.approvalRequests, 0, "An approved helper never asks again")
        XCTAssertEqual(host.holdCalls.count, 3)
    }

    func testFirstUseShowsTheApprovalStateThenTurnsOnOnceAllowed() {
        host.helper = .needsApproval
        host.approvesAfterPolls = 3
        let controller = makeController(queued: true)
        var seen: [KeepAwakeState] = []
        host.onPause = { [unowned self] in
            drainMain()
            seen.append(controller.state)
        }
        controller.toggle()
        XCTAssertEqual(controller.state, .enabling)
        drain()
        XCTAssertEqual(seen.first, .awaitingApproval)
        XCTAssertFalse(seen.contains { $0.isOn }, "Nothing reports on while approval is pending")
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.approvalRequests, 1)

        // The approval is reused for later toggles.
        controller.toggle()
        drain()
        controller.toggle()
        drain()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.approvalRequests, 1)
    }

    func testApprovalThatNeverArrivesTurnsOffWithAnActionableMessage() {
        host.helper = .needsApproval
        let controller = makeController()
        controller.toggle()
        guard case .failed(let message) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertEqual(message, KeepAwakeController.approvalMissingMessage)
        XCTAssertTrue(message.contains(KeepAwakePowerHelper.approvalPlace))
        XCTAssertEqual(host.pauses, Int(KeepAwakeController.approvalTimeout / KeepAwakeController.approvalPollInterval),
                       "The wait is bounded")
        XCTAssertTrue(host.holdCalls.isEmpty)
        XCTAssertEqual(host.ended, host.begun, "Assertions alone are never left behind as Keep Awake")
        XCTAssertFalse(recoveryExists(controller))
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testCancelingWhileAwaitingApprovalTurnsOffWithoutHolding() {
        host.helper = .needsApproval
        host.approvesAfterPolls = 5
        let controller = makeController(queued: true)
        host.onPause = { [unowned self] in
            drainMain()
            if controller.state == .awaitingApproval {
                XCTAssertEqual(controller.state.actionTitle, "Cancel Keep Awake")
                XCTAssertTrue(controller.toggle(), "Waiting for approval can be canceled")
                XCTAssertEqual(controller.state, .off)
            }
        }
        controller.toggle()
        drain()
        XCTAssertEqual(controller.state, .off)
        XCTAssertTrue(host.holdCalls.isEmpty)
        XCTAssertEqual(host.ended, host.begun)
        XCTAssertFalse(recoveryExists(controller))
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testRevokedApprovalIsExplicitAndNeverReportsOn() {
        let controller = makeController()
        controller.toggle()
        controller.toggle()
        XCTAssertEqual(controller.state, .off)

        // The user turned Relay Runner off in Login Items.
        host.helper = .needsApproval
        controller.toggle()
        guard case .failed(let message) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertEqual(message, KeepAwakeController.approvalMissingMessage)
        XCTAssertEqual(host.approvalRequests, 1, "Revocation reopens the approval rather than a password prompt")
        XCTAssertEqual(host.holdCalls.count, 1)
    }

    func testUnavailableHelperFailsExplicitlyWithoutAnyFallback() {
        host.helper = .unavailable(KeepAwakePowerHelper.missingMessage)
        let controller = makeController()
        controller.toggle()
        XCTAssertEqual(controller.state, .failed(KeepAwakePowerHelper.missingMessage))
        XCTAssertTrue(host.holdCalls.isEmpty)
        XCTAssertEqual(host.approvalRequests, 0)
        XCTAssertEqual(host.ended, host.begun)
        XCTAssertFalse(recoveryExists(controller))
        XCTAssertEqual(host.sleepDisabled, false)
    }

    func testSleepAlreadyDisabledByAnotherAppNeedsNoHelperAndIsPreserved() {
        host.sleepDisabled = true
        host.helper = .unavailable("unused")
        let controller = makeController()
        controller.toggle()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: false))
        XCTAssertEqual(host.statusChecks, 0, "No helper or approval for a setting another app owns")
        XCTAssertEqual(host.begun, 1)
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, true, "Never reset another app's disabled sleep")
        XCTAssertEqual(host.releaseCalls, 0)
        controller.toggle()
        controller.shutdown()
        XCTAssertEqual(host.sleepDisabled, true)
        XCTAssertEqual(host.ended, 2)
    }

    func testHelperReportingAnotherOwnerIsOnWithoutClaimingTheSetting() {
        host.holdResult = .heldElsewhere
        let controller = makeController()
        controller.toggle()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: false))
        XCTAssertFalse(recoveryExists(controller), "Relay changed nothing, so there is nothing to recover")
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.releaseCalls, 0)
    }

    func testHelperThatDidNotChangeSleepIsAFailureAndReleasesItsHold() {
        host.holdChangesSetting = false
        let controller = makeController()
        controller.toggle()
        XCTAssertEqual(controller.state, .failed(KeepAwakeController.unchangedMessage))
        XCTAssertEqual(host.releaseCalls, 1)
        XCTAssertEqual(host.ended, host.begun)
        XCTAssertFalse(recoveryExists(controller))
        XCTAssertTrue(scheduled.isEmpty, "Nothing monitors a failed attempt")
    }

    func testUnreadableSleepSettingsFailBeforeTheHelper() {
        host.sleepDisabled = nil
        let controller = makeController()
        controller.toggle()
        guard case .failed(let message) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(message.contains("Couldn't read"))
        XCTAssertEqual(host.statusChecks, 0)
        XCTAssertTrue(host.holdCalls.isEmpty)
    }

    func testUnconfirmedRestoreOffersARestoreThroughTheHelper() {
        host.releaseRestores = false
        let controller = makeController()
        controller.toggle()
        controller.toggle()
        guard case .restoreNeeded = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(recoveryExists(controller), "Recovery stays until restore is confirmed")
        XCTAssertEqual(controller.state.actionTitle, "Restore sleep")

        host.restoreResult = false
        controller.toggle()
        guard case .restoreNeeded = controller.state else { return XCTFail("\(controller.state)") }

        host.restoreResult = true
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.restoreCalls, 2)
        XCTAssertEqual(host.approvalRequests, 0)
        XCTAssertFalse(recoveryExists(controller))
    }

    func testRestoreThatNeedsApprovalOpensItAndStaysExplicit() {
        host.releaseRestores = false
        let controller = makeController()
        controller.toggle()
        controller.toggle()
        host.helper = .needsApproval
        controller.toggle()
        XCTAssertEqual(controller.state, .restoreNeeded(KeepAwakeController.restoreApprovalMessage))
        XCTAssertEqual(host.approvalRequests, 1)
        XCTAssertEqual(host.restoreCalls, 0)
        XCTAssertTrue(recoveryExists(controller))
    }

    func testRapidTogglesWhilePendingAreIgnored() {
        let controller = makeController(queued: true)
        XCTAssertTrue(controller.toggle())
        XCTAssertEqual(controller.state, .enabling)
        XCTAssertFalse(controller.toggle())
        XCTAssertFalse(controller.toggle())
        drain()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.holdCalls.count, 1)
        XCTAssertTrue(controller.toggle())
        XCTAssertEqual(controller.state, .disabling)
        XCTAssertFalse(controller.toggle())
        drain()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.holdCalls.count, 1)
    }

    // MARK: Quit

    func testQuitBeforeQueuedEnableStartsNeverHolds() {
        let controller = makeController(queued: true)
        controller.toggle()
        controller.shutdown()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.closeCalls, 1)
        drain()
        XCTAssertEqual(controller.state, .off)
        XCTAssertTrue(host.holdCalls.isEmpty)
        XCTAssertFalse(recoveryExists(controller))
    }

    func testQuitWhileAwaitingApprovalStopsWaitingAndNeverHolds() {
        host.helper = .needsApproval
        host.approvesAfterPolls = 4
        let controller = makeController(queued: true)
        host.onPause = { [unowned self] in
            drainMain()
            if controller.state == .awaitingApproval { controller.shutdown() }
        }
        controller.toggle()
        drain()
        XCTAssertEqual(controller.state, .off)
        XCTAssertTrue(host.holdCalls.isEmpty)
        XCTAssertLessThan(host.pauses, 4, "Quit ends the wait")
        XCTAssertEqual(host.ended, host.begun)
        XCTAssertFalse(controller.toggle(), "Nothing restarts after quit")
    }

    func testQuitDuringTheHelperRequestRestoresAndDropsTheLateResult() {
        let controller = makeController(queued: true)
        host.duringHold = { controller.shutdown() }
        controller.toggle()
        drain()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false, "Closing the connection ends the helper's hold")
        XCTAssertEqual(host.ended, host.begun)
        XCTAssertFalse(recoveryExists(controller))
        XCTAssertFalse(controller.toggle())
        XCTAssertEqual(controller.state, .off)
    }

    func testQuitWhileOnReleasesSynchronouslyOnce() {
        let controller = makeController()
        controller.toggle()
        let readsBeforeQuit = host.reads
        controller.shutdown()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false)
        XCTAssertEqual(host.closeCalls, 1)
        XCTAssertGreaterThan(host.reads, readsBeforeQuit, "Quit confirms the restore after closing the connection")
        XCTAssertEqual(host.ended, 1)
        XCTAssertFalse(recoveryExists(controller), "A confirmed quit leaves nothing to recover")

        // The next launch has nothing to recover, so it never touches sleep.
        host.relaunch()
        let relaunched = makeController()
        relaunched.recoverIfNeeded()
        XCTAssertEqual(relaunched.state, .off)
        controller.shutdown()
        XCTAssertEqual(host.closeCalls, 1)
        XCTAssertEqual(host.ended, 1)
    }

    func testQuitWithUnconfirmedRestoreKeepsRecoveryForNextLaunch() {
        host.releaseRestores = false
        let controller = makeController()
        controller.toggle()
        controller.shutdown()
        XCTAssertEqual(controller.state, .off)
        XCTAssertTrue(recoveryExists(controller))

        host.relaunch()
        let relaunched = makeController()
        relaunched.recoverIfNeeded()
        guard case .restoreNeeded = relaunched.state else { return XCTFail("\(relaunched.state)") }
        XCTAssertEqual(host.begun, 1, "Recovery never resumes Keep Awake")
        relaunched.toggle()
        XCTAssertEqual(relaunched.state, .off)
        XCTAssertEqual(host.restoreCalls, 1)
        XCTAssertFalse(recoveryExists(relaunched))
    }

    func testLaunchMigratesALegacyWatchdogSessionOnceSleepIsRestored() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = makeController(queued: true)
        try Data().write(to: controller.recoveryURL)
        try Data().write(to: controller.legacyLeaseURL)
        controller.recoverIfNeeded()
        XCTAssertEqual(controller.state, .disabling)
        XCTAssertFalse(controller.toggle())
        drain()
        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.legacyLeaseURL.path),
                       "Deleting the lease lets an earlier build's watchdog restore sleep")
        XCTAssertFalse(recoveryExists(controller))
        XCTAssertEqual(host.begun, 0)
        XCTAssertEqual(host.statusChecks, 0)
    }

    func testAssertionsAreRequiredBeforeTheHelperOrAnOnState() {
        host.assertionsAvailable = false
        let controller = makeController()
        XCTAssertTrue(controller.toggle())
        guard case .failed(let message) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(message.contains("Keep Awake is off"))
        XCTAssertTrue(host.holdCalls.isEmpty)
        XCTAssertEqual(host.reads, 0)
        XCTAssertFalse(recoveryExists(controller))
        host.assertionsAvailable = true
        controller.toggle()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.begun, 1)
    }

    // MARK: Lost override

    /// RR-436's regression: another app had disabled sleep, then restored it while Keep
    /// Awake still reported on, so the lid slept the Mac.
    func testAnotherAppRestoringSleepWhileOnIsTakenOverWithoutAPrompt() {
        host.sleepDisabled = true
        let controller = makeController()
        controller.toggle()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: false))
        runMonitor()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: false), "Still disabled: nothing to do")
        XCTAssertTrue(host.holdCalls.isEmpty)
        XCTAssertTrue(monitorScheduled, "Monitoring continues while on")

        host.sleepDisabled = false
        runMonitor()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.holdCalls, [true])
        XCTAssertEqual(host.approvalRequests, 0)
        XCTAssertEqual(host.begun, 1)
        XCTAssertEqual(host.ended, 0, "Assertions are held throughout the takeover")

        // Relay now owns the setting it re-disabled, so off restores it.
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false)
        XCTAssertFalse(recoveryExists(controller))
        XCTAssertEqual(host.ended, 1)
    }

    func testTakeoverThatIsNotApprovedIsReportedOffInsteadOfAFalseOn() {
        host.sleepDisabled = true
        let controller = makeController()
        controller.toggle()
        host.sleepDisabled = false
        host.helper = .needsApproval
        runMonitor()
        guard case .failed(let message) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(message.hasPrefix(KeepAwakeController.lostSettingContext))
        XCTAssertTrue(message.hasSuffix(KeepAwakeController.approvalMissingMessage))
        XCTAssertEqual(host.ended, host.begun)
        XCTAssertFalse(recoveryExists(controller))
        XCTAssertFalse(monitorScheduled)
    }

    func testCancelingATakeoverApprovalSettlesItsRecoveryRecord() {
        let controller = makeController(queued: true)
        controller.toggle()
        drain()
        // Revoked while on: launchd stops the helper, which restores sleep.
        host.helper = .needsApproval
        host.sleepDisabled = false
        host.onPause = { [unowned self] in
            drainMain()
            if controller.state == .awaitingApproval { controller.toggle() }
        }
        runMonitor()
        drain()
        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(recoveryExists(controller))
        XCTAssertEqual(host.ended, host.begun)
    }

    func testOwnedSettingClearedElsewhereIsReestablished() {
        let controller = makeController()
        controller.toggle()
        // Another app's restore clears the override for everyone.
        host.sleepDisabled = false
        runMonitor()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.holdCalls, [true, true])
        XCTAssertEqual(host.sleepDisabled, true)
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false)
    }

    func testMonitoringIgnoresUnreadableReadsAndStopsWhenOff() {
        let controller = makeController()
        controller.toggle()
        host.sleepDisabled = nil
        runMonitor()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true), "An unreadable report is not a lost setting")
        XCTAssertEqual(host.holdCalls.count, 1)
        host.sleepDisabled = true
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        let reads = host.reads
        runMonitor()
        XCTAssertEqual(host.reads, reads, "A stale check never reads or prompts after off")
        XCTAssertFalse(monitorScheduled)
    }

    func testQuitDuringTakeoverReleasesEverything() {
        host.sleepDisabled = true
        let controller = makeController(queued: true)
        controller.toggle()
        drain()
        host.sleepDisabled = false
        host.duringHold = { controller.shutdown() }
        runMonitor()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false)
        XCTAssertEqual(host.ended, host.begun)
        XCTAssertFalse(recoveryExists(controller))
        XCTAssertFalse(controller.toggle())
    }

    // MARK: Closed-lid dimming

    func testClosedLidDimsOnlyWhileOnAndRestoresTheCapturedBrightness() throws {
        let controller = makeController()
        display.moveLid(closed: true)
        XCTAssertTrue(display.writes.isEmpty, "Never dims while Keep Awake is off")
        XCTAssertFalse(display.isObserving)
        display.moveLid(closed: false)

        controller.toggle()
        XCTAssertTrue(display.isObserving)
        XCTAssertTrue(display.writes.isEmpty, "An open lid leaves brightness alone")

        display.moveLid(closed: true)
        XCTAssertEqual(display.brightness, 0)
        XCTAssertEqual(try String(contentsOf: controller.brightnessRecordURL, encoding: .utf8), "0.7",
                       "The previous brightness is recorded before dimming")
        // Repeated notifications keep the captured value instead of the zero now on screen.
        display.moveLid(closed: true)
        runMonitor()
        XCTAssertEqual(display.brightness, 0)

        display.moveLid(closed: false)
        XCTAssertEqual(display.brightness, 0.7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.brightnessRecordURL.path))

        display.brightness = 0.4
        display.moveLid(closed: true)
        XCTAssertEqual(display.brightness, 0)
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(display.brightness, 0.4, "Turning off restores while the lid is still closed")
        XCTAssertFalse(display.isObserving)
        let writes = display.writes.count
        display.moveLid(closed: false)
        display.moveLid(closed: true)
        XCTAssertEqual(display.writes.count, writes)
    }

    func testEnablingWithTheLidAlreadyClosedDimsOnceOnAndQuitRestores() {
        display.lidClosed = true
        let controller = makeController(queued: true)
        controller.toggle()
        display.moveLid(closed: true)
        XCTAssertTrue(display.writes.isEmpty, "A lid event during activation doesn't dim before Keep Awake is on")
        drain()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(display.writes, [0])
        controller.shutdown()
        XCTAssertEqual(display.brightness, 0.7)
        XCTAssertFalse(display.isObserving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.brightnessRecordURL.path))
    }

    func testDisablingRestoresBrightnessBeforeTheChangeSettles() {
        let controller = makeController(queued: true)
        controller.toggle()
        drain()
        display.moveLid(closed: true)
        XCTAssertEqual(display.brightness, 0)
        controller.toggle()
        XCTAssertEqual(controller.state, .disabling)
        XCTAssertEqual(display.brightness, 0.7)
        display.moveLid(closed: true)
        XCTAssertEqual(display.brightness, 0.7, "No dimming once Keep Awake is turning off")
        drain()
        XCTAssertEqual(controller.state, .off)
    }

    func testFailedOrPendingKeepAwakeNeverDims() {
        display.lidClosed = true
        host.helper = .unavailable(KeepAwakePowerHelper.missingMessage)
        let controller = makeController()
        controller.toggle()
        guard case .failed = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(display.writes.isEmpty)
        XCTAssertFalse(display.isObserving)
    }

    func testUnreadableOrAlreadyDarkBrightnessIsLeftUnchanged() {
        let controller = makeController()
        controller.toggle()
        display.brightness = nil
        display.moveLid(closed: true)
        XCTAssertTrue(display.writes.isEmpty, "Nothing valid to restore later, so nothing is dimmed")
        display.moveLid(closed: false)
        display.brightness = 0
        display.moveLid(closed: true)
        XCTAssertTrue(display.writes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.brightnessRecordURL.path))
        display.moveLid(closed: nil)
        XCTAssertTrue(display.writes.isEmpty, "An unreadable lid is not evidence it moved")
    }

    func testFailedRestoreRetriesThenRecoversAtTheNextLaunch() {
        let controller = makeController()
        controller.toggle()
        display.moveLid(closed: true)
        display.failWrites = true
        display.moveLid(closed: false)
        for _ in 1..<KeepAwakeLidDimmer.restoreAttempts {
            let retry = scheduled.firstIndex { $0.delay == KeepAwakeLidDimmer.restoreRetryInterval }
            guard let retry else { return XCTFail("Missing restore retry") }
            scheduled.remove(at: retry).job()
        }
        XCTAssertFalse(scheduled.contains { $0.delay == KeepAwakeLidDimmer.restoreRetryInterval }, "Retries are bounded")
        XCTAssertEqual(display.writes.filter { $0 == 0.7 }.count, KeepAwakeLidDimmer.restoreAttempts)
        controller.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.brightnessRecordURL.path),
                      "An unconfirmed restore keeps its record")

        display.failWrites = false
        let relaunched = makeController()
        relaunched.recoverIfNeeded()
        XCTAssertEqual(display.brightness, 0.7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: relaunched.brightnessRecordURL.path))
        XCTAssertEqual(relaunched.state, .off, "Recovery never turns Keep Awake on")
    }

    func testClosingTheLidAgainCancelsAPendingRestoreRetry() {
        let controller = makeController()
        controller.toggle()
        display.moveLid(closed: true)
        display.failWrites = true
        display.moveLid(closed: false)
        display.failWrites = false
        display.moveLid(closed: true)
        let writes = display.writes.count
        scheduled.filter { $0.delay == KeepAwakeLidDimmer.restoreRetryInterval }.forEach { $0.job() }
        XCTAssertEqual(display.writes.count, writes, "A superseded retry never re-brightens a closed lid")
        XCTAssertEqual(display.brightness, 0)
        display.moveLid(closed: false)
        XCTAssertEqual(display.brightness, 0.7, "The original capture survives the failed restore")
    }

    // MARK: Text and parsing

    func testStatusTextIsTruthfulForEveryState() {
        XCTAssertEqual(KeepAwakeState.off.actionTitle, "Turn on Keep Awake")
        XCTAssertEqual(KeepAwakeState.on(ownsSleepSetting: true).actionTitle, "Turn off Keep Awake")
        XCTAssertEqual(KeepAwakeState.awaitingApproval.actionTitle, "Cancel Keep Awake")
        XCTAssertTrue(KeepAwakeState.on(ownsSleepSetting: true).status.contains("lid closed"))
        XCTAssertFalse(KeepAwakeState.on(ownsSleepSetting: false).status.contains("lid closed"))
        XCTAssertTrue(KeepAwakeState.awaitingApproval.status.contains(KeepAwakePowerHelper.approvalPlace))
        XCTAssertTrue(KeepAwakeState.awaitingApproval.status.contains("only once"))
        XCTAssertFalse(KeepAwakeState.awaitingApproval.isPending, "Approval can be canceled")
        XCTAssertFalse(KeepAwakeState.awaitingApproval.isOn)
        XCTAssertTrue(KeepAwakeState.enabling.isPending)
        XCTAssertTrue(KeepAwakeState.disabling.isPending)
        XCTAssertFalse(KeepAwakeState.enabling.isOn)
        XCTAssertFalse(KeepAwakeState.failed("x").isOn)
        XCTAssertFalse(KeepAwakeState.description.contains("administrator"))
        XCTAssertEqual(GeneralSettingsTab.keepAwakeDescription(.off), KeepAwakeState.description)
        XCTAssertTrue(GeneralSettingsTab.keepAwakeDescription(.awaitingApproval).hasSuffix(KeepAwakeState.awaitingApproval.status))
    }

    func testPmsetParsingNeverGuessesAnUnreadableValue() {
        let output = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"
        XCTAssertEqual(RelayPowerSettings.sleepDisabled(inPmsetOutput: output), true)
        XCTAssertEqual(RelayPowerSettings.sleepDisabled(inPmsetOutput: " SleepDisabled 0"), false)
        XCTAssertNil(RelayPowerSettings.sleepDisabled(inPmsetOutput: "Currently in use:\n sleep 1"))
        XCTAssertNil(RelayPowerSettings.sleepDisabled(inPmsetOutput: " SleepDisabled maybe"))
        XCTAssertEqual(RelayPowerSettings.setArguments(sleepDisabled: true), ["-a", "disablesleep", "1"])
        XCTAssertEqual(RelayPowerSettings.setArguments(sleepDisabled: false), ["-a", "disablesleep", "0"])
        XCTAssertEqual(RelayPowerSettings.pmset, "/usr/bin/pmset")
    }

    func testCommandRunnerIsBounded() {
        let echo = RelayPowerCommandRunner.run("/bin/echo", ["SleepDisabled 0"], timeout: 5)
        XCTAssertEqual(echo.status, 0)
        XCTAssertEqual(RelayPowerSettings.sleepDisabled(inPmsetOutput: echo.output), false)
        let start = Date()
        XCTAssertNil(RelayPowerCommandRunner.run("/bin/sleep", ["5"], timeout: 0.2).status)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertNil(RelayPowerCommandRunner.run("/nonexistent/pmset", [], timeout: 1).status)
    }
}
