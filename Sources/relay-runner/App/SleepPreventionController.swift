import Foundation

struct SleepPreventionActivity: Equatable {
    let foregroundProviderTurnActive: Bool
    let activeWorkerRunCount: Int

    var hasQualifyingTask: Bool {
        foregroundProviderTurnActive || activeWorkerRunCount > 0
    }

    static func activeWorkerRunCount(in runs: [RunState]) -> Int {
        runs.filter(\.preventsIdleSystemSleep).count
    }

    static func shouldPreventSleep(preferenceEnabled: Bool, activity: SleepPreventionActivity) -> Bool {
        preferenceEnabled && activity.hasQualifyingTask
    }
}

extension RunState {
    var preventsIdleSystemSleep: Bool {
        state == "Claimed" || state == "Running" || state == "Reviewing"
    }
}

final class SleepPreventionController {
    typealias BeginActivity = (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol?
    typealias EndActivity = (NSObjectProtocol) -> Void
    typealias Log = (String) -> Void

    static let activityOptions: ProcessInfo.ActivityOptions = [
        .userInitiated,
        .idleSystemSleepDisabled,
    ]
    static let activityReason = "Relay Runner is running a task."
    static let retryDelay: TimeInterval = 30

    private let beginActivity: BeginActivity
    private let endActivity: EndActivity
    private let log: Log
    private let now: () -> Date
    private var token: NSObjectProtocol?
    private var lastAcquireFailureAt: Date?

    init(
        beginActivity: @escaping BeginActivity = { options, reason in
            ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        },
        endActivity: @escaping EndActivity = { token in
            ProcessInfo.processInfo.endActivity(token)
        },
        now: @escaping () -> Date = Date.init,
        log: @escaping Log = { message in
            NSLog("[RelayRunner] %@", message)
        }
    ) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
        self.log = log
        self.now = now
    }

    var isHoldingAssertion: Bool {
        token != nil
    }

    func sync(preferenceEnabled: Bool, activity: SleepPreventionActivity) {
        let shouldHold = SleepPreventionActivity.shouldPreventSleep(
            preferenceEnabled: preferenceEnabled,
            activity: activity
        )
        if shouldHold {
            acquireIfNeeded(activity: activity)
        } else {
            release(reason: preferenceEnabled ? "no-active-task" : "setting-disabled")
        }
    }

    func release(reason: String) {
        guard let held = token else { return }
        token = nil
        endActivity(held)
        log("Released prevent-sleep activity reason=\(sanitized(reason))")
    }

    private func acquireIfNeeded(activity: SleepPreventionActivity) {
        guard token == nil else { return }
        if let lastAcquireFailureAt,
           now().timeIntervalSince(lastAcquireFailureAt) < Self.retryDelay {
            return
        }
        guard let activityToken = beginActivity(Self.activityOptions, Self.activityReason) else {
            lastAcquireFailureAt = now()
            log("Failed to acquire prevent-sleep activity foreground=\(activity.foregroundProviderTurnActive) workers=\(activity.activeWorkerRunCount)")
            return
        }
        token = activityToken
        lastAcquireFailureAt = nil
        log("Acquired prevent-sleep activity foreground=\(activity.foregroundProviderTurnActive) workers=\(activity.activeWorkerRunCount)")
    }

    private func sanitized(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
        let clipped = String(String.UnicodeScalarView(allowed).prefix(48))
        return clipped.isEmpty ? "unspecified" : clipped
    }
}
