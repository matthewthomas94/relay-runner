import Foundation
import RelayRemoteProtocol

/// Runs the tutorial's `TutorialMachine`: starts the reply timeout on "play
/// the reply", holds "You're all done" briefly, and ends the tutorial once
/// when it is skipped or done.
@MainActor
@Observable
final class TutorialModel {
    /// How long step 4 waits for a reply before telling the user.
    static let replyTimeout: TimeInterval = 30
    /// How long "You're all done" shows before the app.
    static let closingHold: TimeInterval = 1.5

    private(set) var machine = TutorialMachine()

    @ObservationIgnored private let onFinished: () -> Void
    @ObservationIgnored private let sleep: (TimeInterval) async -> Void
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var didFinish = false

    /// `sleep` is how long waits happen; tests pass their own.
    init(sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         onFinished: @escaping () -> Void) {
        self.sleep = sleep
        self.onFinished = onFinished
    }

    func observe(_ signals: TutorialSignals) { change { $0.observe(signals) } }
    func holdBegan() { change { $0.holdBegan() } }
    func released() { change { $0.released() } }
    func playTapped() { change { $0.playTapped() } }
    func stopTapped() { change { $0.stopTapped() } }

    /// Skip → at any step: the app takes over and onboarding is finished.
    func skip() { finish() }

    func cancel() {
        timer?.cancel()
        timer = nil
    }

    private func change(_ edit: (inout TutorialMachine) -> Void) {
        guard !didFinish else { return }
        let before = machine.step
        edit(&machine)
        if machine.step != before { stepChanged() }
    }

    private func stepChanged() {
        cancel()
        switch machine.step {
        case .playReply:
            timer = Task { [weak self] in
                await self?.sleep(Self.replyTimeout)
                guard !Task.isCancelled else { return }
                self?.change { $0.replyTimeoutElapsed() }
            }
        case .allDone:
            timer = Task { [weak self] in
                await self?.sleep(Self.closingHold)
                guard !Task.isCancelled else { return }
                self?.finish()
            }
        default:
            break
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        cancel()
        machine.finish()
        onFinished()
    }
}

/// Which agent the tutorial talks to: the one the Mac reports running, and
/// George (with no project) when none is.
enum TutorialAgent {
    /// nil until the Mac has reported its agents.
    static func choose(activities: [String: AgentActivity], active: String?) -> String? {
        guard !activities.isEmpty else { return nil }
        let running = AgentsModel.slugs.filter { activities[$0].map { $0 != .off } ?? false }
        if let active, running.contains(active) { return active }
        return running.first ?? "george"
    }

    /// Ready to take a message: running, and past starting.
    static func isAvailable(_ activity: AgentActivity?) -> Bool {
        guard let activity else { return false }
        return activity != .off && activity != .starting
    }
}
