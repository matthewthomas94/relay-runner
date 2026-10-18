import Foundation
import XCTest
@testable import relay_runner

@MainActor
final class STTPhononMigrationTests: XCTestCase {
    private let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)

    private struct Failure: LocalizedError {
        var errorDescription: String? { "smoke test failed." }
    }

    private final class Harness {
        var stt = SttConfig()
        var idle = true
        var prepared: [STTModel] = []
        var applied: [SttConfig] = []
        var prepareError: Error?
        var onPrepare: () -> Void = {}
    }

    private func makeMigration(
        _ harness: Harness,
        operatingSystem: OperatingSystemVersion? = nil,
        active: Bool = true
    ) -> STTPhononMigration {
        STTPhononMigration(environment: .init(
            prepare: { model, progress in
                await MainActor.run {
                    harness.prepared.append(model)
                    harness.onPrepare()
                }
                progress("Downloading Phonon 2: 50%")
                if let error = await MainActor.run(body: { harness.prepareError }) { throw error }
            },
            currentConfig: { harness.stt },
            isIdle: { harness.idle },
            apply: { stt in
                harness.applied.append(stt)
                harness.stt = stt
            },
            operatingSystem: operatingSystem ?? sequoia,
            phononDefaultActive: active,
            idlePollInterval: .milliseconds(5)
        ))
    }

    func testValidatedPhononIsAppliedAndRecordsPreviousModel() async {
        let harness = Harness()
        let migration = makeMigration(harness)

        await migration.startIfEligible()?.value

        XCTAssertEqual(harness.prepared, [.phonon2])
        XCTAssertEqual(migration.state, .completed)
        XCTAssertEqual(harness.stt.model, "phonon-2")
        XCTAssertEqual(harness.stt.phonon_migration, "completed")
        XCTAssertEqual(harness.stt.phonon_migration_previous_model, "parakeet-tdt-v2")
        // Relaunch: a completed migration never runs again.
        XCTAssertNil(makeMigration(harness).startIfEligible())
    }

    func testFailureKeepsPreviousModelAndRetrySucceeds() async {
        let harness = Harness()
        harness.prepareError = Failure()
        let migration = makeMigration(harness)

        await migration.startIfEligible()?.value

        guard case .failed(let message) = migration.state else {
            return XCTFail("expected failure, got \(migration.state)")
        }
        XCTAssertTrue(message.contains("Parakeet v2 is still active"))
        XCTAssertTrue(harness.applied.isEmpty)
        XCTAssertEqual(harness.stt, SttConfig())

        harness.prepareError = nil
        await migration.retry()?.value
        XCTAssertEqual(migration.state, .completed)
        XCTAssertEqual(harness.stt.model, "phonon-2")
    }

    func testSwitchWaitsForIdleBoundary() async throws {
        let harness = Harness()
        harness.idle = false
        let migration = makeMigration(harness)

        let task = migration.startIfEligible()
        for _ in 0..<200 where migration.state != .waitingForIdle {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(migration.state, .waitingForIdle)
        XCTAssertTrue(harness.applied.isEmpty)

        harness.idle = true
        await task?.value
        XCTAssertEqual(migration.state, .completed)
        XCTAssertEqual(harness.applied.count, 1)
    }

    func testUserChoiceDuringPreparationIsNotOverridden() async {
        let harness = Harness()
        harness.onPrepare = {
            var explicit = harness.stt
            explicit.model = "parakeet-tdt-v3"
            harness.stt = explicit.recordingUserModelChange(from: harness.stt)
        }
        let migration = makeMigration(harness)

        await migration.startIfEligible()?.value

        XCTAssertTrue(harness.applied.isEmpty)
        XCTAssertEqual(harness.stt.model, "parakeet-tdt-v3")
        XCTAssertEqual(harness.stt.phonon_migration, "explicit")
    }

    func testIneligibleUsersAreNeverPreparedOrMigrated() {
        let inactive = Harness()
        XCTAssertNil(makeMigration(inactive, active: false).startIfEligible())

        let sonomaUser = Harness()
        XCTAssertNil(makeMigration(sonomaUser, operatingSystem: sonoma).startIfEligible())

        let v3User = Harness()
        v3User.stt.model = "parakeet-tdt-v3"
        XCTAssertNil(makeMigration(v3User).startIfEligible())

        XCTAssertTrue(inactive.prepared.isEmpty && sonomaUser.prepared.isEmpty && v3User.prepared.isEmpty)
    }

    // MARK: - Next-recording rule

    func testModelSwitchWaitsForCommandCaptureAndNoteOwnership() {
        XCTAssertTrue(AppState.sttModelSwitchIsIdle(
            commandRecording: false, notePhase: .idle, noteStartPending: false, noteRecoveryPending: false
        ))
        XCTAssertFalse(AppState.sttModelSwitchIsIdle(
            commandRecording: true, notePhase: .idle, noteStartPending: false, noteRecoveryPending: false
        ))
        XCTAssertFalse(AppState.sttModelSwitchIsIdle(
            commandRecording: false, notePhase: .recording, noteStartPending: false, noteRecoveryPending: false
        ))
        XCTAssertFalse(AppState.sttModelSwitchIsIdle(
            commandRecording: false, notePhase: .idle, noteStartPending: false, noteRecoveryPending: true
        ))
    }

    func testOnlyAnIdleCachedNoteCoordinatorIsInvalidatedOnModelChange() {
        XCTAssertTrue(AppState.shouldInvalidateMeetingNoteCoordinator(
            oldModel: "parakeet-tdt-v2", newModel: "phonon-2",
            notePhase: .idle, noteStartPending: false, noteRecoveryPending: false
        ))
        XCTAssertTrue(AppState.shouldInvalidateMeetingNoteCoordinator(
            oldModel: "phonon-2", newModel: "parakeet-tdt-v2",
            notePhase: .saved, noteStartPending: false, noteRecoveryPending: false
        ))
        XCTAssertFalse(AppState.shouldInvalidateMeetingNoteCoordinator(
            oldModel: "parakeet-tdt-v2", newModel: "parakeet-tdt-v2",
            notePhase: .idle, noteStartPending: false, noteRecoveryPending: false
        ))
        for phase: MeetingNoteCoordinatorPhase in [.preparing, .recording, .paused, .transcribing, .stopping, .interrupted] {
            XCTAssertFalse(AppState.shouldInvalidateMeetingNoteCoordinator(
                oldModel: "parakeet-tdt-v2", newModel: "phonon-2",
                notePhase: phase, noteStartPending: false, noteRecoveryPending: false
            ), "\(phase)")
        }
        XCTAssertFalse(AppState.shouldInvalidateMeetingNoteCoordinator(
            oldModel: "parakeet-tdt-v2", newModel: "phonon-2",
            notePhase: .idle, noteStartPending: true, noteRecoveryPending: false
        ))
        XCTAssertFalse(AppState.shouldInvalidateMeetingNoteCoordinator(
            oldModel: "parakeet-tdt-v2", newModel: "phonon-2",
            notePhase: .idle, noteStartPending: false, noteRecoveryPending: true
        ))
    }

    func testCommandAndNoteModelIdentityFollowASafeSettingsChange() throws {
        var draft = SttConfig()
        draft.model = "phonon-2"
        let saved = draft.recordingUserModelChange(from: SttConfig())

        // Both the next command engine and the next note resolve the saved ID.
        let model = try STTModel.resolve(saved.model, operatingSystem: sequoia)
        XCTAssertEqual(model, .phonon2)
        let identity = MeetingTranscriptionIdentity.current(for: model)
        XCTAssertEqual(identity.model, "phonon-2")
        XCTAssertEqual(identity.modelRevision, STTModelPreparation.phononRevision)

        // A rollback to Parakeet is never labeled as Phonon.
        var rollback = saved
        rollback.model = "parakeet-tdt-v2"
        let rolledBackModel = try STTModel.resolve(rollback.model, operatingSystem: sequoia)
        let rolledBackIdentity = MeetingTranscriptionIdentity.current(for: rolledBackModel)
        XCTAssertEqual(rolledBackIdentity.model, "parakeet-tdt-v2")
        XCTAssertNil(rolledBackIdentity.modelRevision)
    }
}
