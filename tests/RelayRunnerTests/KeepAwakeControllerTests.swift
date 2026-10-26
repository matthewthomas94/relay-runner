import Foundation
import XCTest
@testable import relay_runner

extension KeepAwakeSystem {
    /// Never reads or changes host power settings.
    static var inert: KeepAwakeSystem {
        KeepAwakeSystem(sleepDisabled: { nil }, disableSleep: { _, _ in .failed }, restoreSleep: { .failed },
                        cancel: {}, beginActivity: { nil }, endActivity: { _ in }, pause: { _ in })
    }
}

/// Simulates pmset, the administrator prompt, and the root watchdog in memory.
private final class FakeSleepHost {
    var sleepDisabled: Bool? = false
    var approval: KeepAwakeSystem.Approval = .approved
    var approvalChangesSetting = true
    var watchdogRestores = true
    var restoreApproval: KeepAwakeSystem.Approval = .approved
    var duringApproval: () -> Void = {}
    private(set) var disableCalls: [(lease: URL, pid: Int32, filesExisted: Bool)] = []
    private(set) var restoreCalls = 0
    private(set) var cancelCalls = 0
    private(set) var begun = 0
    private(set) var ended = 0
    private(set) var reads = 0
    private var watchedLease: URL?
    var recoveryURL: URL?

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
                let files = FileManager.default
                disableCalls.append((lease, pid, files.fileExists(atPath: lease.path)
                    && recoveryURL.map { files.fileExists(atPath: $0.path) } == true))
                if approval == .approved, approvalChangesSetting {
                    watchedLease = lease
                    sleepDisabled = true
                }
                duringApproval()
                return approval
            },
            restoreSleep: { [self] in
                restoreCalls += 1
                if restoreApproval == .approved { sleepDisabled = false }
                return restoreApproval
            },
            cancel: { [self] in cancelCalls += 1 },
            beginActivity: { [self] in
                begun += 1
                return NSObject()
            },
            endActivity: { [self] _ in ended += 1 },
            pause: { _ in }
        )
    }
}

final class KeepAwakeControllerTests: XCTestCase {
    private var directory: URL!
    private var host: FakeSleepHost!
    private var work: [() -> Void] = []
    private var main: [() -> Void] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-awake-\(UUID().uuidString)", isDirectory: true)
        host = FakeSleepHost()
        host.recoveryURL = directory.appendingPathComponent("keep-awake-recovery")
        work = []
        main = []
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
            log: { _ in }
        )
    }

    private func drain() {
        while !work.isEmpty || !main.isEmpty {
            if !work.isEmpty { work.removeFirst()() } else { main.removeFirst()() }
        }
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
        XCTAssertEqual(host.begun, 0, "An idle assertion alone is never reported as Keep Awake")
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
        XCTAssertEqual(host.begun, 0)
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
        XCTAssertEqual(host.begun, 0)
        XCTAssertFalse(ownershipFilesExist(controller).lease)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
        XCTAssertFalse(controller.toggle(), "Nothing restarts after quit")
        XCTAssertEqual(controller.state, .off)
    }

    func testQuitWhileOnReleasesSynchronouslyOnce() {
        let controller = makeController()
        controller.toggle()
        controller.shutdown()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(host.sleepDisabled, false)
        XCTAssertEqual(host.ended, 1)
        XCTAssertFalse(ownershipFilesExist(controller).recovery)
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

        let relaunched = makeController()
        relaunched.recoverIfNeeded()
        guard case .restoreNeeded = relaunched.state else { return XCTFail("\(relaunched.state)") }
        XCTAssertEqual(host.begun, 1, "Recovery never resumes Keep Awake")
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
