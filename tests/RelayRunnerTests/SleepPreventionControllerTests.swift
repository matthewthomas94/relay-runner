import Foundation
import XCTest
@testable import relay_runner

final class SleepPreventionControllerTests: XCTestCase {
    func testActivityOptionsDisableIdleSystemSleepOnly() {
        XCTAssertTrue(SleepPreventionController.activityOptions.contains(.idleSystemSleepDisabled))
        XCTAssertTrue(SleepPreventionController.activityOptions.contains(.userInitiated))
        XCTAssertFalse(SleepPreventionController.activityOptions.contains(.idleDisplaySleepDisabled))
    }

    func testControllerHoldsOneTokenAcrossOverlappingTasks() {
        let token = NSObject()
        var beginCalls: [(ProcessInfo.ActivityOptions, String)] = []
        var endedTokens: [NSObjectProtocol] = []
        let controller = SleepPreventionController(
            beginActivity: { options, reason in
                beginCalls.append((options, reason))
                return token
            },
            endActivity: { endedTokens.append($0) },
            log: { _ in }
        )

        controller.sync(
            preferenceEnabled: true,
            activity: SleepPreventionActivity(
                foregroundProviderTurnActive: true,
                activeWorkerRunCount: 0
            )
        )
        controller.sync(
            preferenceEnabled: true,
            activity: SleepPreventionActivity(
                foregroundProviderTurnActive: true,
                activeWorkerRunCount: 2
            )
        )
        controller.sync(
            preferenceEnabled: true,
            activity: SleepPreventionActivity(
                foregroundProviderTurnActive: false,
                activeWorkerRunCount: 2
            )
        )

        XCTAssertEqual(beginCalls.count, 1)
        XCTAssertTrue(controller.isHoldingAssertion)
        XCTAssertTrue(endedTokens.isEmpty)

        controller.sync(
            preferenceEnabled: true,
            activity: SleepPreventionActivity(
                foregroundProviderTurnActive: false,
                activeWorkerRunCount: 0
            )
        )

        XCTAssertFalse(controller.isHoldingAssertion)
        XCTAssertEqual(endedTokens.count, 1)
    }

    func testSettingOffReleasesImmediately() {
        let token = NSObject()
        var endCount = 0
        let controller = SleepPreventionController(
            beginActivity: { _, _ in token },
            endActivity: { _ in endCount += 1 },
            log: { _ in }
        )

        controller.sync(
            preferenceEnabled: true,
            activity: SleepPreventionActivity(
                foregroundProviderTurnActive: false,
                activeWorkerRunCount: 1
            )
        )
        controller.sync(
            preferenceEnabled: false,
            activity: SleepPreventionActivity(
                foregroundProviderTurnActive: false,
                activeWorkerRunCount: 1
            )
        )

        XCTAssertFalse(controller.isHoldingAssertion)
        XCTAssertEqual(endCount, 1)
    }

    func testAcquireFailureIsLoggedAndThrottled() {
        var now = Date(timeIntervalSince1970: 100)
        var beginCount = 0
        var logs: [String] = []
        let controller = SleepPreventionController(
            beginActivity: { _, _ in
                beginCount += 1
                return nil
            },
            endActivity: { _ in },
            now: { now },
            log: { logs.append($0) }
        )
        let active = SleepPreventionActivity(
            foregroundProviderTurnActive: true,
            activeWorkerRunCount: 0
        )

        controller.sync(preferenceEnabled: true, activity: active)
        controller.sync(preferenceEnabled: true, activity: active)
        now = now.addingTimeInterval(SleepPreventionController.retryDelay)
        controller.sync(preferenceEnabled: true, activity: active)

        XCTAssertEqual(beginCount, 2)
        XCTAssertEqual(logs.count, 2)
        XCTAssertFalse(controller.isHoldingAssertion)
    }

    func testSleepActivityRequiresEnabledPreferenceAndQualifyingTask() {
        XCTAssertFalse(
            SleepPreventionActivity.shouldPreventSleep(
                preferenceEnabled: false,
                activity: SleepPreventionActivity(
                    foregroundProviderTurnActive: true,
                    activeWorkerRunCount: 1
                )
            )
        )
        XCTAssertFalse(
            SleepPreventionActivity.shouldPreventSleep(
                preferenceEnabled: true,
                activity: SleepPreventionActivity(
                    foregroundProviderTurnActive: false,
                    activeWorkerRunCount: 0
                )
            )
        )
        XCTAssertTrue(
            SleepPreventionActivity.shouldPreventSleep(
                preferenceEnabled: true,
                activity: SleepPreventionActivity(
                    foregroundProviderTurnActive: true,
                    activeWorkerRunCount: 0
                )
            )
        )
        XCTAssertTrue(
            SleepPreventionActivity.shouldPreventSleep(
                preferenceEnabled: true,
                activity: SleepPreventionActivity(
                    foregroundProviderTurnActive: false,
                    activeWorkerRunCount: 1
                )
            )
        )
    }

    func testWorkerRunStatesThatPreventSleepExcludeQueuedReviewPendingAndTerminalStates() {
        let states = [
            RunState(
                ticketId: "RR-1",
                repoPath: "/tmp/repo",
                runId: 1,
                state: "Claimed",
                lastError: nil,
                activity: nil,
                activityAt: nil
            ),
            RunState(
                ticketId: "RR-2",
                repoPath: "/tmp/repo",
                runId: 2,
                state: "Running",
                lastError: nil,
                activity: nil,
                activityAt: nil
            ),
            RunState(
                ticketId: "RR-3",
                repoPath: "/tmp/repo",
                runId: 3,
                state: "Reviewing",
                lastError: nil,
                activity: nil,
                activityAt: nil
            ),
            RunState(
                ticketId: "RR-4",
                repoPath: "/tmp/repo",
                runId: 4,
                state: "AwaitingReview",
                lastError: nil,
                activity: nil,
                activityAt: nil
            ),
            RunState(
                ticketId: "RR-5",
                repoPath: "/tmp/repo",
                runId: 5,
                state: "Stalled",
                lastError: nil,
                activity: nil,
                activityAt: nil
            ),
            RunState(
                ticketId: "RR-6",
                repoPath: "/tmp/repo",
                runId: 6,
                state: "Canceled",
                lastError: nil,
                activity: nil,
                activityAt: nil
            ),
            RunState(
                ticketId: "RR-7",
                repoPath: "/tmp/repo",
                runId: 7,
                state: "Merged",
                lastError: nil,
                activity: nil,
                activityAt: nil
            ),
        ]

        XCTAssertEqual(SleepPreventionActivity.activeWorkerRunCount(in: states), 3)
    }

    func testProviderTurnStoreIsProviderNeutral() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-turns-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        try """
        {
          "records": [
            { "state": "completed_final", "provider": "codex" },
            { "state": "active", "provider": "claude" }
          ]
        }
        """.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(ProcessManager.providerTurnActive(providerTurnsURL: url))
    }
}
