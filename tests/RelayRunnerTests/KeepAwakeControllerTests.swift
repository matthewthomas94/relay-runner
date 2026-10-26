import Foundation
import XCTest
@testable import relay_runner

extension KeepAwakeSystem {
    /// Never reads or changes host power settings.
    static var inert: KeepAwakeSystem {
        KeepAwakeSystem(sleepDisabled: { nil }, disableSleep: { _, _ in .failed }, restoreSleep: { .failed },
                        cancelApproval: {}, holdAssertions: { nil }, releaseAssertions: { _ in }, pause: { _ in })
    }
}

/// Simulates pmset, the administrator prompt, and the root watchdog in memory.
/// Like the live runners, canceling refuses approvals but never `pmset -g` reads.
private final class FakeSleepHost {
    var sleepDisabled: Bool? = false
    var approval: KeepAwakeSystem.Approval = .approved
    var approvalChangesSetting = true
    var watchdogRestores = true
    var restoreApproval: KeepAwakeSystem.Approval = .approved
    var assertionsAvailable = true
    var duringApproval: () -> Void = {}
    private(set) var disableCalls: [(lease: URL, pid: Int32, filesExisted: Bool)] = []
    private(set) var restoreCalls = 0
    private(set) var cancelCalls = 0
    private var approvalsCanceled = false
    private(set) var begun = 0
    private(set) var ended = 0
    private(set) var reads = 0
    private var watchedLease: URL?
    var recoveryURL: URL?

    /// A new process gets fresh command runners; the power setting persists.
    func relaunch() { approvalsCanceled = false }

    var system: KeepAwakeSystem {
        KeepAwakeSystem(
            sleepDisabled: { [self] in
                reads += 1
                if let lease = watchedLease, watchdogRestores,
                   !FileManager.default.fileExists(atPath: lease.path) {
                    watchedLease = nil
                    sleepDisabled = false
                }
                return sleepDisabled
            },
            disableSleep: { [self] lease, pid in
                guard !approvalsCanceled else { return .failed }
                let files = FileManager.default
                disableCalls.append((lease, pid, files.fileExists(atPath: lease.path)
                    && recoveryURL.map { files.fileExists(atPath: $0.path) } == true))
                if approval == .approved, approvalChangesSetting {
                    watchedLease = lease
                    sleepDisabled = true
                }
                duringApproval()
                // Quit terminates the in-flight prompt.
                return approvalsCanceled ? .failed : approval
            },
            restoreSleep: { [self] in
                guard !approvalsCanceled else { return .failed }
                restoreCalls += 1
                if restoreApproval == .approved { sleepDisabled = false }
                return restoreApproval
            },
            cancelApproval: { [self] in
                cancelCalls += 1
                approvalsCanceled = true
            },
            holdAssertions: { [self] in
                guard assertionsAvailable else { return nil }
                begun += 1
                return NSObject()
            },
            releaseAssertions: { [self] _ in ended += 1 },
            pause: { _ in }
        )
    }
}

final class KeepAwakeControllerTests: XCTestCase {
    private var directory: URL!
    private var host: FakeSleepHost!
    private var work: [() -> Void] = []
    private var main: [() -> Void] = []
    private var scheduled: [(delay: TimeInterval, job: () -> Void)] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-awake-\(UUID().uuidString)", isDirectory: true)
        host = FakeSleepHost()
        host.recoveryURL = directory.appendingPathComponent("keep-awake-recovery")
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
            system: host.system, directory: directory, pid: 4242,
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

    /// Runs the pending sleep-setting checks, as the monitor timer would.
    private func runMonitor() {
        let jobs = scheduled
        scheduled = []
        for (delay, job) in jobs {
            XCTAssertEqual(delay, KeepAwakeController.monitorInterval)
            job()
        }
        drain()
    }

    private func ownershipFilesExist(_ controller: KeepAwakeController) -> (lease: Bool, recovery: Bool) {
        (FileManager.default.fileExists(atPath: controller.leaseURL.path),
         FileManager.default.fileExists(atPath: controller.recoveryURL.path))
    }

    func testFreshLaunchIsOffWithoutTouchingPowerSettings() {
        let controller = makeController()
        controller.recoverIfNeeded()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.reads, 0)
        XCTAssertTrue(host.disableCalls.isEmpty)
        XCTAssertEqual(host.begun, 0)
    }

    func testEnablingRecordsOwnershipBeforeTheApprovedChangeAndHoldsUntilSwitchedOff() {
        let controller = makeController()
        XCTAssertTrue(controller.toggle())
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.disableCalls.count, 1)
        XCTAssertTrue(host.disableCalls[0].filesExisted, "Recovery is recorded before the change")
        XCTAssertEqual(host.disableCalls[0].pid, 4242)
        XCTAssertEqual(host.disableCalls[0].lease, controller.leaseURL)
        XCTAssertEqual(host.begun, 1)

        // Off restores through the watchdog lease, with no second approval.
        XCTAssertTrue(controller.toggle())
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false)
        XCTAssertEqual(host.restoreCalls, 0)
        XCTAssertEqual(host.ended, 1)
        XCTAssertFalse(ownershipFilesExist(controller).lease)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
    }

    func testSleepAlreadyDisabledByAnotherAppIsPreserved() {
        host.sleepDisabled = true
        let controller = makeController()
        controller.toggle()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: false))
        XCTAssertTrue(host.disableCalls.isEmpty, "No approval prompt for a setting another app owns")
        XCTAssertEqual(host.begun, 1)
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, true, "Never reset another app's disabled sleep")
        XCTAssertEqual(host.restoreCalls, 0)
        controller.toggle()
        controller.shutdown()
        XCTAssertEqual(host.sleepDisabled, true)
        XCTAssertEqual(host.ended, 2)
    }

    func testCanceledApprovalIsReportedAndLeavesNoOwnership() {
        host.approval = .canceled
        let controller = makeController()
        controller.toggle()
        guard case .failed(let message) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(message.contains("canceled"))
        XCTAssertFalse(controller.state.isOn)
        XCTAssertEqual(host.ended, host.begun, "Assertions alone are never left behind as Keep Awake")
        XCTAssertFalse(ownershipFilesExist(controller).lease)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
        // A failed attempt can be retried.
        host.approval = .approved
        XCTAssertTrue(controller.toggle())
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
    }

    func testApprovedCommandThatDidNotChangeSleepIsAFailure() {
        host.approvalChangesSetting = false
        let controller = makeController()
        controller.toggle()
        guard case .failed = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertEqual(host.ended, host.begun)
        XCTAssertTrue(scheduled.isEmpty, "Nothing monitors a failed attempt")
    }

    func testUnreadableSleepSettingsFailBeforeAnyPrompt() {
        host.sleepDisabled = nil
        let controller = makeController()
        controller.toggle()
        guard case .failed(let message) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(message.contains("Couldn't read"))
        XCTAssertTrue(host.disableCalls.isEmpty)
    }

    func testUnconfirmedRestoreAsksForApprovedRestore() {
        host.watchdogRestores = false
        let controller = makeController()
        controller.toggle()
        controller.toggle()
        guard case .restoreNeeded = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(ownershipFilesExist(controller).recovery, "Recovery stays until restore is confirmed")
        XCTAssertEqual(controller.state.actionTitle, "Restore sleep")

        host.restoreApproval = .canceled
        controller.toggle()
        guard case .restoreNeeded(let message) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(message.contains("canceled"))

        host.restoreApproval = .approved
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.restoreCalls, 2)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
    }

    func testRapidTogglesWhilePendingAreIgnored() {
        let controller = makeController(queued: true)
        XCTAssertTrue(controller.toggle())
        XCTAssertEqual(controller.state, .enabling)
        XCTAssertFalse(controller.toggle())
        XCTAssertFalse(controller.toggle())
        drain()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.disableCalls.count, 1)
        XCTAssertTrue(controller.toggle())
        XCTAssertEqual(controller.state, .disabling)
        XCTAssertFalse(controller.toggle())
        drain()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.disableCalls.count, 1)
    }

    func testQuitBeforeQueuedApprovalStartsNeverPrompts() {
        let controller = makeController(queued: true)
        controller.toggle()
        controller.shutdown()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.cancelCalls, 1)
        drain()
        XCTAssertEqual(controller.state, .off)
        XCTAssertTrue(host.disableCalls.isEmpty)
        XCTAssertFalse(ownershipFilesExist(controller).lease)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
    }

    func testQuitDuringApprovalRestoresAnyChangeAndDropsTheLateResult() {
        let controller = makeController(queued: true)
        host.duringApproval = { controller.shutdown() }
        controller.toggle()
        drain()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false, "The watchdog restores once quit removes the lease")
        XCTAssertEqual(host.ended, host.begun)
        XCTAssertFalse(ownershipFilesExist(controller).lease)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
        XCTAssertFalse(controller.toggle(), "Nothing restarts after quit")
        XCTAssertEqual(controller.state, .off)
    }

    func testQuitWhileOnReleasesSynchronouslyOnce() {
        let controller = makeController()
        controller.toggle()
        let readsBeforeQuit = host.reads
        controller.shutdown()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false)
        XCTAssertGreaterThan(host.reads, readsBeforeQuit, "Quit confirms the restore after canceling approval")
        XCTAssertEqual(host.ended, 1)
        XCTAssertFalse(ownershipFilesExist(controller).lease)
        XCTAssertFalse(ownershipFilesExist(controller).recovery, "A confirmed quit leaves nothing to recover")

        // The next launch has nothing to recover, so it never prompts or touches sleep.
        let relaunched = makeController()
        relaunched.recoverIfNeeded()
        XCTAssertEqual(relaunched.state, .off)
        controller.shutdown()
        XCTAssertEqual(host.cancelCalls, 1)
        XCTAssertEqual(host.ended, 1)
    }

    func testQuitWithUnconfirmedRestoreKeepsRecoveryForNextLaunch() {
        host.watchdogRestores = false
        let controller = makeController()
        controller.toggle()
        controller.shutdown()
        XCTAssertEqual(controller.state, .off)
        XCTAssertTrue(ownershipFilesExist(controller).recovery)

        host.relaunch()
        let relaunched = makeController()
        relaunched.recoverIfNeeded()
        guard case .restoreNeeded = relaunched.state else { return XCTFail("\(relaunched.state)") }
        XCTAssertEqual(host.begun, 1, "Recovery never resumes Keep Awake")
        XCTAssertEqual(host.ended, 1)
        relaunched.toggle()
        XCTAssertEqual(relaunched.state, .off)
        XCTAssertFalse(ownershipFilesExist(relaunched).recovery)
    }

    func testLaunchRecoveryClearsAnInterruptedRunOnceSleepIsRestored() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = makeController(queued: true)
        try Data().write(to: controller.recoveryURL)
        try Data().write(to: controller.leaseURL)
        host.sleepDisabled = false
        controller.recoverIfNeeded()
        XCTAssertEqual(controller.state, .disabling)
        XCTAssertFalse(controller.toggle())
        drain()
        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(ownershipFilesExist(controller).lease)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
        XCTAssertEqual(host.begun, 0)
    }

    func testAssertionsAreRequiredBeforeAnyPromptOrOnState() {
        host.assertionsAvailable = false
        let controller = makeController()
        XCTAssertTrue(controller.toggle())
        guard case .failed(let message) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(message.contains("Keep Awake is off"))
        XCTAssertTrue(host.disableCalls.isEmpty)
        XCTAssertEqual(host.reads, 0)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
        host.assertionsAvailable = true
        controller.toggle()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.begun, 1)
    }

    /// The reported regression: another app had disabled sleep, then restored it while
    /// Keep Awake still reported on with only an idle assertion, so the lid slept the Mac.
    func testAnotherAppRestoringSleepWhileOnIsTakenOverWithApproval() {
        host.sleepDisabled = true
        let controller = makeController()
        controller.toggle()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: false))
        runMonitor()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: false), "Still disabled: nothing to do")
        XCTAssertTrue(host.disableCalls.isEmpty)
        XCTAssertEqual(scheduled.count, 1, "Monitoring continues while on")

        host.sleepDisabled = false
        runMonitor()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.disableCalls.count, 1)
        XCTAssertTrue(host.disableCalls[0].filesExisted)
        XCTAssertEqual(host.begun, 1)
        XCTAssertEqual(host.ended, 0, "Assertions are held throughout the takeover")

        // Relay now owns the setting it re-disabled, so off restores it.
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
        XCTAssertEqual(host.ended, 1)
    }

    func testDeclinedTakeoverIsReportedOffInsteadOfAFalseOn() {
        host.sleepDisabled = true
        let controller = makeController(queued: true)
        controller.toggle()
        drain()
        host.sleepDisabled = false
        host.approval = .canceled
        runMonitor()
        guard case .failed(let message) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(message.hasPrefix(KeepAwakeController.lostSettingContext))
        XCTAssertTrue(message.contains("canceled"))
        XCTAssertEqual(host.ended, host.begun)
        XCTAssertFalse(ownershipFilesExist(controller).lease)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testOwnedSettingClearedElsewhereIsReestablishedWithoutDroppingTheLease() {
        let controller = makeController()
        controller.toggle()
        // Another app's restore clears the override for everyone.
        host.sleepDisabled = false
        runMonitor()
        XCTAssertEqual(controller.state, .on(ownsSleepSetting: true))
        XCTAssertEqual(host.disableCalls.count, 2)
        XCTAssertTrue(host.disableCalls[1].filesExisted, "The lease never disappears, so no watchdog restores early")
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
        XCTAssertEqual(host.disableCalls.count, 1)
        host.sleepDisabled = true
        controller.toggle()
        XCTAssertEqual(controller.state, .off)
        let reads = host.reads
        runMonitor()
        XCTAssertEqual(host.reads, reads, "A stale check never reads or prompts after off")
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testQuitDuringTakeoverApprovalReleasesEverything() {
        host.sleepDisabled = true
        let controller = makeController(queued: true)
        controller.toggle()
        drain()
        host.sleepDisabled = false
        host.duringApproval = { controller.shutdown() }
        runMonitor()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false)
        XCTAssertEqual(host.ended, host.begun)
        XCTAssertFalse(ownershipFilesExist(controller).lease)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
        XCTAssertFalse(controller.toggle())
    }

    func testPmsetParsingNeverGuessesAnUnreadableValue() {
        let output = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"
        XCTAssertEqual(KeepAwakeCommand.sleepDisabled(inPmsetOutput: output), true)
        XCTAssertEqual(KeepAwakeCommand.sleepDisabled(inPmsetOutput: " SleepDisabled 0"), false)
        XCTAssertNil(KeepAwakeCommand.sleepDisabled(inPmsetOutput: "Currently in use:\n sleep 1"))
        XCTAssertNil(KeepAwakeCommand.sleepDisabled(inPmsetOutput: " SleepDisabled maybe"))
    }

    func testPrivilegedCommandsAreFixedAndStartTheWatchdogFirst() throws {
        let lease = "/Users/me/Library/Application Support/relay-runner/keep-awake-lease"
        let script = try XCTUnwrap(KeepAwakeCommand.disableScript(lease: lease, pid: 77))
        XCTAssertTrue(script.contains("/bin/kill -0 77"))
        XCTAssertTrue(script.contains("/bin/test -e '\(lease)'"))
        let watchdog = try XCTUnwrap(script.range(of: "disablesleep 0"))
        let change = try XCTUnwrap(script.range(of: "disablesleep 1"))
        XCTAssertLessThan(watchdog.lowerBound, change.lowerBound)
        XCTAssertTrue(script.contains(") >/dev/null 2>&1 & "), "The watchdog is detached so approval returns")
        for unsafe in ["relative/lease", "/tmp/it's", "/tmp/a\"b", "/tmp/a\\b", "/tmp/$(id)", "/tmp/`id`", "/tmp/a\nb"] {
            XCTAssertNil(KeepAwakeCommand.disableScript(lease: unsafe, pid: 77), unsafe)
        }
        XCTAssertNil(KeepAwakeCommand.disableScript(lease: lease, pid: 0))
        XCTAssertEqual(KeepAwakeCommand.restoreScript, "/usr/bin/pmset -a disablesleep 0")
        let apple = KeepAwakeCommand.appleScript(KeepAwakeCommand.restoreScript)
        XCTAssertTrue(apple.hasPrefix("do shell script \"/usr/bin/pmset -a disablesleep 0\""))
        XCTAssertTrue(apple.hasSuffix("with administrator privileges"))
    }

    func testApprovalResultsMapCancellationAndTimeouts() {
        XCTAssertEqual(KeepAwakeCommand.approval(status: 0, output: ""), .approved)
        XCTAssertEqual(KeepAwakeCommand.approval(status: 1, output: "execution error: User canceled. (-128)"), .canceled)
        XCTAssertEqual(KeepAwakeCommand.approval(status: 1, output: "execution error"), .failed)
        XCTAssertEqual(KeepAwakeCommand.approval(status: nil, output: ""), .failed)
    }

    func testCommandRunnerIsBoundedAndRefusesWorkAfterCancel() {
        let runner = KeepAwakeCommandRunner()
        let echo = runner.run("/bin/echo", ["SleepDisabled 0"], timeout: 5)
        XCTAssertEqual(echo.status, 0)
        XCTAssertEqual(KeepAwakeCommand.sleepDisabled(inPmsetOutput: echo.output), false)
        let start = Date()
        XCTAssertNil(runner.run("/bin/sleep", ["5"], timeout: 0.2).status)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        runner.cancel()
        XCTAssertNil(runner.run("/bin/echo", ["late"], timeout: 5).status)
    }

    func testCancelingApprovalKeepsLiveReadsAvailable() {
        let approvals = KeepAwakeCommandRunner()
        let reads = KeepAwakeCommandRunner()
        let system = KeepAwakeSystem.live(approvals: approvals, reads: reads)
        system.cancelApproval()
        XCTAssertNil(approvals.run("/bin/echo", ["late"], timeout: 5).status)
        XCTAssertEqual(reads.run("/bin/echo", ["SleepDisabled 0"], timeout: 5).status, 0)
    }

    func testStatusTextIsTruthfulForEveryState() {
        XCTAssertEqual(KeepAwakeState.off.actionTitle, "Turn on Keep Awake")
        XCTAssertEqual(KeepAwakeState.on(ownsSleepSetting: true).actionTitle, "Turn off Keep Awake")
        XCTAssertTrue(KeepAwakeState.on(ownsSleepSetting: true).status.contains("lid closed"))
        XCTAssertFalse(KeepAwakeState.on(ownsSleepSetting: false).status.contains("lid closed"))
        XCTAssertTrue(KeepAwakeState.enabling.status.contains("approval"))
        XCTAssertTrue(KeepAwakeState.enabling.isPending)
        XCTAssertTrue(KeepAwakeState.disabling.isPending)
        XCTAssertFalse(KeepAwakeState.enabling.isOn)
        XCTAssertFalse(KeepAwakeState.failed("x").isOn)
        XCTAssertEqual(GeneralSettingsTab.keepAwakeDescription(.off), KeepAwakeState.description)
        XCTAssertTrue(GeneralSettingsTab.keepAwakeDescription(.enabling).hasSuffix(KeepAwakeState.enabling.status))
    }
}
