import Foundation

/// One-time automatic switch from implicit Parakeet v2 to Phonon 2. Phonon is
/// downloaded, compiled and smoke-tested first; only after validation does the
/// config change, and only at an idle boundary (no recording, no Note Taker
/// session). A failure leaves the previous model in place and offers retry.
@Observable
final class STTPhononMigration {
    enum State: Equatable {
        case idle
        case preparing(String)
        case waitingForIdle
        case completed
        case failed(String)
    }

    struct Environment {
        /// Downloads, loads and verifies `model`, releasing it afterwards.
        var prepare: (STTModel, @escaping @Sendable (String) -> Void) async throws -> Void
        var currentConfig: () -> SttConfig
        var isIdle: () -> Bool
        var apply: (SttConfig) -> Void
        var operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        var phononDefaultActive: Bool = STTModelPolicy.phononDefaultActive
        var idlePollInterval: Duration = .milliseconds(500)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var task: Task<Void, Never>?

    init(environment: Environment) {
        self.environment = environment
    }

    var isEligible: Bool {
        STTModelPolicy.migrationTarget(
            for: environment.currentConfig(),
            operatingSystem: environment.operatingSystem,
            phononDefaultActive: environment.phononDefaultActive
        ) != nil
    }

    /// Starts the migration when eligible; a no-op while in flight or done.
    @discardableResult
    func startIfEligible() -> Task<Void, Never>? {
        guard task == nil, isEligible else { return nil }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run()
        }
        self.task = task
        return task
    }

    /// Retries after a failure. Eligibility is re-checked, so a user who chose
    /// a model in the meantime is left alone.
    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard case .failed = state else { return nil }
        state = .idle
        return startIfEligible()
    }

    func cancel() {
        task?.cancel()
    }

    @MainActor
    private func run() async {
        defer { task = nil }
        state = .preparing(STTPreparationPhase.checking.statusText(for: .phonon2))
        do {
            try await environment.prepare(.phonon2) { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, case .preparing = self.state else { return }
                    self.state = .preparing(status)
                }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            state = .failed("Phonon 2 setup was cancelled. Parakeet v2 is still active; retry to continue.")
            return
        } catch {
            state = .failed(
                "Phonon 2 setup failed: \(error.localizedDescription) Parakeet v2 is still active; retry to continue."
            )
            return
        }

        state = .waitingForIdle
        while !environment.isIdle() {
            do {
                try await Task.sleep(for: environment.idlePollInterval)
            } catch {
                state = .failed("Phonon 2 setup was cancelled. Parakeet v2 is still active; retry to continue.")
                return
            }
        }
        // The user may have chosen a model while Phonon was preparing.
        let config = environment.currentConfig()
        guard isEligible else {
            state = .idle
            return
        }
        environment.apply(config.applyingPhononMigration())
        state = .completed
    }
}
