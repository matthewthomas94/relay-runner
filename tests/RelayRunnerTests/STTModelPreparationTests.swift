import CryptoKit
import FluidAudio
import XCTest
@testable import relay_runner

/// Synthetic coverage for RR-412 model selection and preparation. No network,
/// Core ML or real model files: downloads are fakes that write small fixtures
/// checked against an injected SHA-256 manifest.
final class STTModelPreparationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rr412-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Resolver

    func testResolverMapsExactIdentifiers() throws {
        let macOS15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(try STTModel.resolve("phonon-2", operatingSystem: macOS15).asrVersion, .phonon2)
        XCTAssertEqual(try STTModel.resolve("parakeet-tdt-v2", operatingSystem: macOS15).asrVersion, .v2)
        XCTAssertEqual(try STTModel.resolve("parakeet-tdt-v3", operatingSystem: macOS15).asrVersion, .v3)
        XCTAssertEqual(try STTModel.resolve("  parakeet-tdt-v3\n", operatingSystem: macOS15), .parakeetV3)
    }

    func testResolverRejectsUnknownNamesWithoutSubstringFallback() {
        for name in ["", "v3", "parakeet-v3", "parakeet-tdt-v3-large", "PHONON-2", "whisper-small", "phonon"] {
            XCTAssertThrowsError(try STTModel.resolve(name), name) { error in
                XCTAssertEqual(error as? STTModelSelectionError, .unknownModel(name))
                let message = error.localizedDescription
                for choice in ["phonon-2", "parakeet-tdt-v2", "parakeet-tdt-v3"] {
                    XCTAssertTrue(message.contains(choice), "\(name): \(message)")
                }
            }
        }
    }

    func testResolverGatesPhononOnMacOS15() throws {
        let macOS14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0)
        XCTAssertThrowsError(try STTModel.resolve("phonon-2", operatingSystem: macOS14)) { error in
            XCTAssertEqual(
                error as? STTModelSelectionError,
                .unsupportedOperatingSystem(model: .phonon2, requiredMajorVersion: 15))
            XCTAssertTrue(error.localizedDescription.contains("macOS 15"))
        }
        XCTAssertEqual(try STTModel.resolve("parakeet-tdt-v2", operatingSystem: macOS14), .parakeetV2)
        XCTAssertEqual(try STTModel.resolve("parakeet-tdt-v3", operatingSystem: macOS14), .parakeetV3)
        for major in [15, 26] {
            let os = OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0)
            XCTAssertEqual(try STTModel.resolve("phonon-2", operatingSystem: os), .phonon2)
        }
    }

    func testNoteTranscriberRejectsUnknownModelBeforeLoading() async {
        let loads = Counter()
        let transcriber = FluidAudioMeetingTranscriber(modelName: "parakeet-v3") { _, _ in
            loads.increment()
            return AsrManager()
        }
        do {
            try await transcriber.prepare { _ in }
            XCTFail("unknown model must not prepare")
        } catch {
            XCTAssertEqual(error as? STTModelSelectionError, .unknownModel("parakeet-v3"))
        }
        XCTAssertEqual(loads.value, 0)
    }

    func testRevisionPinCoversPhononOnly() {
        STTModelPreparation.applyRevisionPins()
        XCTAssertEqual(
            ModelRegistry.revisionOverrides[STTModelPreparation.phononRepository],
            "a812a0dfef205660787ef6234317ab79acf4d5d6")
        XCTAssertNil(ModelRegistry.revisionOverrides[STTModel.parakeetV2.repository])
        XCTAssertNil(ModelRegistry.revisionOverrides[STTModel.parakeetV3.repository])
    }

    func testShippedManifestMatchesValidationRecord() throws {
        XCTAssertEqual(PhononManifest.files.count, 20)
        XCTAssertEqual(PhononManifest.totalBytes(PhononManifest.files), 357_726_026)
    }

    func testProgressTextOnlyReportsRealDownloadPercent() {
        XCTAssertEqual(
            STTPreparationPhase.downloading(completed: 2, total: 5, fraction: 0.42).statusText(for: .phonon2),
            "Downloading Phonon 2 2/5 (42%)")
        XCTAssertFalse(STTPreparationPhase.compiling("Encoder").statusText(for: .phonon2).contains("%"))
        XCTAssertFalse(STTPreparationPhase.verifying.statusText(for: .phonon2).contains("%"))
    }

    // MARK: - Preparation outcomes

    func testColdStartDownloadsVerifiesAndRecordsIdentity() async throws {
        let fake = FakeHub(root: root)
        let phases = PhaseLog()
        let identity = try await fake.coordinator().ensureAssets(for: .phonon2, progress: phases.append)

        XCTAssertEqual(fake.downloads, [Download(model: .phonon2, force: false)])
        XCTAssertEqual(identity.modelRevision, STTModelPreparation.phononRevision)
        XCTAssertEqual(identity.repository, "FluidInference/phonon-2-coreml")
        XCTAssertEqual(identity.runtime, STTModelPreparation.runtime)
        XCTAssertEqual(identity.verifiedFiles, fake.manifest.count)
        XCTAssertEqual(phases.values.first, .checking)
        XCTAssertTrue(phases.values.contains(.downloading(completed: 1, total: 1, fraction: 1)))
        XCTAssertEqual(phases.values.last, .verifying)
    }

    func testWarmReuseVerifiesCachedFilesWithoutRemoving() async throws {
        let fake = FakeHub(root: root)
        fake.writeGood()
        _ = try await fake.coordinator().ensureAssets(for: .phonon2) { _ in }
        XCTAssertTrue(fake.removed.isEmpty)
        XCTAssertEqual(fake.downloads, [Download(model: .phonon2, force: false)])
    }

    func testOfflineUsesVerifiedCacheAndFailsClearlyWithoutOne() async throws {
        let cached = FakeHub(root: root)
        cached.offline = true
        cached.writeGood()
        let identity = try await cached.coordinator().ensureAssets(for: .phonon2) { _ in }
        XCTAssertEqual(identity.verifiedFiles, cached.manifest.count)

        let empty = FakeHub(root: root.appendingPathComponent("empty"))
        empty.offline = true
        await assertThrows(.offline(.phonon2)) {
            try await empty.coordinator().ensureAssets(for: .phonon2) { _ in }
        }
        XCTAssertTrue(
            ErrorTranslator.translate(STTPreparationError.offline(.phonon2).localizedDescription).action != nil)
    }

    func testNoNetworkIsClassifiedAndRetryRunsAFreshAttempt() async throws {
        let fake = FakeHub(root: root)
        fake.failures = [URLError(.notConnectedToInternet)]
        let coordinator = fake.coordinator()
        await assertThrows(.offline(.phonon2)) {
            try await coordinator.ensureAssets(for: .phonon2) { _ in }
        }
        let identity = try await coordinator.ensureAssets(for: .phonon2) { _ in }
        XCTAssertEqual(identity.verifiedFiles, fake.manifest.count)
        XCTAssertEqual(fake.downloads.count, 2)
    }

    func testInsufficientDiskFailsBeforeDownloadAndOnWriteError() async throws {
        let full = FakeHub(root: root)
        full.capacity = 1
        await assertThrows(.insufficientDisk(.phonon2, requiredBytes: full.totalBytes)) {
            try await full.coordinator().ensureAssets(for: .phonon2) { _ in }
        }
        XCTAssertTrue(full.downloads.isEmpty)

        let enospc = FakeHub(root: root.appendingPathComponent("enospc"))
        enospc.failures = [
            DownloadError.downloadFailed(path: "Encoder", underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
        ]
        do {
            _ = try await enospc.coordinator().ensureAssets(for: .phonon2) { _ in }
            XCTFail("expected disk failure")
        } catch {
            guard case .insufficientDisk = error as? STTPreparationError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(error.localizedDescription.lowercased().contains("no space left on device"))
        }
    }

    func testCorruptCacheIsPurgedAndRedownloadedWithoutTouchingParakeet() async throws {
        let fake = FakeHub(root: root)
        fake.writeGood()
        try Data("tampered!".utf8).write(to: fake.phononDirectory.appendingPathComponent("weights.bin"))
        let parakeetFile = fake.writeParakeetCache()

        let identity = try await fake.coordinator().ensureAssets(for: .phonon2) { _ in }

        XCTAssertEqual(identity.verifiedFiles, fake.manifest.count)
        XCTAssertEqual(fake.removed.map(\.path), [fake.phononDirectory.path])
        XCTAssertEqual(
            fake.downloads, [Download(model: .phonon2, force: false), Download(model: .phonon2, force: true)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: parakeetFile.path))
    }

    func testPersistentCorruptionFailsClosedAndKeepsParakeet() async throws {
        let fake = FakeHub(root: root)
        fake.corruptDownloads = true
        let parakeetFile = fake.writeParakeetCache()
        await assertThrows(.integrity(.phonon2, files: ["weights.bin"])) {
            try await fake.coordinator().ensureAssets(for: .phonon2) { _ in }
        }
        XCTAssertEqual(fake.removed.map(\.path), [fake.phononDirectory.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: parakeetFile.path))
    }

    func testInterruptedDownloadPropagatesCancellationAndRetries() async throws {
        let fake = FakeHub(root: root)
        fake.failures = [URLError(.cancelled)]
        let coordinator = fake.coordinator()
        do {
            _ = try await coordinator.ensureAssets(for: .phonon2) { _ in }
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        _ = try await coordinator.ensureAssets(for: .phonon2) { _ in }
        XCTAssertEqual(fake.downloads.count, 2)
    }

    func testConcurrentPreparationSharesOneAttemptAndFansOutProgress() async throws {
        let fake = FakeHub(root: root)
        let gate = AsyncGate()
        fake.gate = gate
        let coordinator = fake.coordinator()
        let first = PhaseLog()
        let second = PhaseLog()

        async let a = coordinator.ensureAssets(for: .phonon2, progress: first.append)
        async let b = coordinator.ensureAssets(for: .phonon2, progress: second.append)
        await gate.waitUntilEntered()
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()
        let (ia, ib) = try await (a, b)

        XCTAssertEqual(ia, ib)
        XCTAssertEqual(fake.downloads.count, 1)
        XCTAssertTrue(first.values.contains(.verifying))
        XCTAssertTrue(second.values.contains(.verifying))
    }

    func testCancelledSoleWaiterCancelsSharedAttempt() async throws {
        let fake = FakeHub(root: root)
        let gate = AsyncGate()
        fake.gate = gate
        let coordinator = fake.coordinator()
        let task = Task { try await coordinator.ensureAssets(for: .phonon2) { _ in } }
        await gate.waitUntilEntered()
        task.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("cancelled preparation must not report ready")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testParakeetKeepsLegacyUnpinnedUnverifiedCache() async throws {
        let fake = FakeHub(root: root)
        let identity = try await fake.coordinator().ensureAssets(for: .parakeetV3) { _ in }
        XCTAssertNil(identity.modelRevision)
        XCTAssertEqual(identity.verifiedFiles, 0)
        XCTAssertTrue(fake.removed.isEmpty)
        XCTAssertEqual(fake.downloads, [Download(model: .parakeetV3, force: false)])
    }

    // MARK: - Install-time model set

    /// Prepares exactly what a fresh install's engine and migration would.
    private func freshInstallDownloads(_ operatingSystem: OperatingSystemVersion) async throws -> [Download] {
        let fake = FakeHub(root: root)
        let stt = SttConfig.freshInstall(operatingSystem: operatingSystem, phononDefaultActive: true)
        XCTAssertNil(STTModelPolicy.migrationTarget(
            for: stt, operatingSystem: operatingSystem, phononDefaultActive: true))
        let model = try STTModel.resolve(stt.model, operatingSystem: operatingSystem)
        _ = try await fake.coordinator().ensureAssets(for: model) { _ in }
        return fake.downloads
    }

    func testMacOS15FreshInstallPreparesOnlyPhonon() async throws {
        let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let downloads = try await freshInstallDownloads(sequoia)
        XCTAssertEqual(downloads, [Download(model: .phonon2, force: false)])
    }

    func testMacOS14FreshInstallFallsBackToParakeetV2() async throws {
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)
        let downloads = try await freshInstallDownloads(sonoma)
        XCTAssertEqual(downloads, [Download(model: .parakeetV2, force: false)])
    }

    func testSupersededParakeetCacheIsRemovedButPhononNeverIs() async throws {
        let fake = FakeHub(root: root)
        fake.writeGood()
        let parakeetFile = fake.writeParakeetCache()
        let coordinator = fake.coordinator()

        await coordinator.removeCachedAssets(for: .phonon2)
        XCTAssertTrue(fake.removed.isEmpty)

        await coordinator.removeCachedAssets(for: .parakeetV2)
        XCTAssertEqual(fake.removed, [parakeetFile.deletingLastPathComponent()])
        XCTAssertFalse(FileManager.default.fileExists(atPath: parakeetFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fake.phononDirectory.appendingPathComponent("config.json").path))
    }

    // MARK: - Stale note preparation

    func testReleaseDuringPrepareDiscardsManagerAndNeverPublishesReady() async throws {
        let gate = AsyncGate()
        let transcriber = FluidAudioMeetingTranscriber(modelName: "parakeet-tdt-v2") { _, _ in
            await gate.enterAndWait()
            return AsrManager()
        }
        let states = StateLog()
        let prepare = Task { try await transcriber.prepare(onState: states.append) }
        await gate.waitUntilEntered()
        await transcriber.release()
        await gate.open()

        do {
            try await prepare.value
            XCTFail("superseded prepare must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(states.values.contains(.ready(model: "parakeet-tdt-v2")))
        let request = MeetingTranscriptionRequest(
            segmentID: "s", sourceID: .microphone, timingEpochID: "e", windowSequence: 0, revision: 0,
            contextStartMilliseconds: 0, ownedStartMilliseconds: 0, ownedEndMilliseconds: 1_000,
            ownedEndSample: 16_000, isFinal: true, samples: [Float](repeating: 0, count: 16_000))
        do {
            _ = try await transcriber.transcribe(request)
            XCTFail("stale manager must not be installed")
        } catch {}
    }

    func testPreparePublishesReadyAfterLoaderSucceeds() async throws {
        let transcriber = FluidAudioMeetingTranscriber(modelName: "parakeet-tdt-v3") { model, progress in
            XCTAssertEqual(model, .parakeetV3)
            progress(.verifying)
            return AsrManager()
        }
        let states = StateLog()
        try await transcriber.prepare(onState: states.append)
        XCTAssertEqual(states.values, [.checking, .verifying, .ready(model: "parakeet-tdt-v3")])
        await transcriber.release()
    }

    // MARK: - Helpers

    private func assertThrows<T>(
        _ expected: STTPreparationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? STTPreparationError, expected, file: file, line: line)
        }
    }
}

private struct Download: Equatable {
    let model: STTModel
    let force: Bool
}

/// Fake FluidAudio transport: writes two small fixture files per model.
private final class FakeHub: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var _downloads: [Download] = []
    private var _removed: [URL] = []
    var failures: [Error] = []
    var offline = false
    var corruptDownloads = false
    var capacity: Int64?
    var gate: AsyncGate?

    let contents: [String: Data] = [
        "config.json": Data("{\"model\":\"phonon\"}".utf8),
        "weights.bin": Data(repeating: 7, count: 4096),
    ]

    init(root: URL) { self.root = root }

    var phononDirectory: URL { root.appendingPathComponent("phonon-2") }
    var downloads: [Download] { lock.withLock { _downloads } }
    var removed: [URL] { lock.withLock { _removed } }

    var manifest: [PhononManifest.File] {
        contents.keys.sorted().map { path in
            let data = contents[path]!
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return PhononManifest.File(path: path, size: Int64(data.count), sha256: digest)
        }
    }

    var totalBytes: Int64 { PhononManifest.totalBytes(manifest) }

    func writeGood(corrupt: Bool = false) {
        try? FileManager.default.createDirectory(at: phononDirectory, withIntermediateDirectories: true)
        for (path, data) in contents {
            let bytes = corrupt && path == "weights.bin" ? Data(repeating: 9, count: data.count) : data
            try? bytes.write(to: phononDirectory.appendingPathComponent(path))
        }
    }

    func writeParakeetCache() -> URL {
        let dir = root.appendingPathComponent(STTModel.parakeetV2.rawValue)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Encoder.mlmodelc")
        try? Data("working".utf8).write(to: file)
        return file
    }

    func coordinator() -> STTModelPreparation {
        STTModelPreparation(
            environment: .init(
                modelDirectory: { [root] in root.appendingPathComponent($0.rawValue) },
                download: { [self] model, directory, force, progress in
                    lock.withLock { _downloads.append(Download(model: model, force: force)) }
                    if let gate { await gate.enterAndWait() }
                    try Task.checkCancellation()
                    if let failure = lock.withLock({ failures.isEmpty ? nil : failures.removeFirst() }) {
                        throw failure
                    }
                    guard model == .phonon2 else { return }
                    let present = FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("config.json").path)
                    if present && !force { return }
                    if offline { throw DownloadError.networkDisabled(operation: "download(phonon-2)") }
                    progress(.downloading(completed: 1, total: 1, fraction: 1))
                    writeGood(corrupt: corruptDownloads)
                },
                availableCapacity: { [self] _ in capacity },
                removeDirectory: { [self] url in
                    lock.withLock { _removed.append(url) }
                    try? FileManager.default.removeItem(at: url)
                },
                phononManifest: manifest
            ))
    }
}

private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [STTPreparationPhase] = []
    var values: [STTPreparationPhase] { lock.withLock { _values } }
    @Sendable func append(_ phase: STTPreparationPhase) { lock.withLock { _values.append(phase) } }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [MeetingLocalModelState] = []
    var values: [MeetingLocalModelState] { lock.withLock { _values } }
    @Sendable func append(_ state: MeetingLocalModelState) { lock.withLock { _values.append(state) } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private actor AsyncGate {
    private var entered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
    }
}

/// Real-model evidence, skipped unless `RR412_REAL_MODEL_ROOT` points at a
/// FluidAudio models directory holding the pinned Phonon cache (for example
/// the RR-411 evaluation cache). Runs fully offline; prints no transcript text.
final class STTModelPreparationRealModelTests: XCTestCase {
    func testCachedPhononPreparesVerifiesSmokesAndTranscribesOffline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["RR412_REAL_MODEL_ROOT"] else {
            throw XCTSkip("set RR412_REAL_MODEL_ROOT to run real cached inference")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let wasOffline = ModelHub.offlineMode
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = wasOffline }

        var environment = STTModelPreparation.Environment.live
        environment.modelDirectory = { root.appendingPathComponent($0 == .phonon2 ? "phonon-2" : "unused-\($0.rawValue)") }
        environment.removeDirectory = { url in XCTFail("verified cache must not be removed: \(url.lastPathComponent)") }
        let coordinator = STTModelPreparation(environment: environment)
        let phases = RealPhaseLog()

        let started = Date()
        let identity = try await coordinator.ensureAssets(for: .phonon2, progress: phases.append)
        XCTAssertEqual(identity.modelRevision, "a812a0dfef205660787ef6234317ab79acf4d5d6")
        XCTAssertEqual(identity.verifiedFiles, 20)

        let manager = try await coordinator.prepareManager(for: .phonon2, progress: phases.append)
        let prepareSeconds = Date().timeIntervalSince(started)
        XCTAssertTrue(phases.values.contains(.verifying))
        XCTAssertFalse(phases.values.contains { if case .downloading = $0 { return true } else { return false } })

        if let fixture = env["RR412_REAL_FIXTURE"] {
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(URL(fileURLWithPath: fixture), decoderState: &state)
            XCTAssertFalse(result.text.trimmingCharacters(in: .whitespaces).isEmpty)
            print("RR412-REAL: fixture chars=\(result.text.count) processing=\(result.processingTime)s")
        }
        print("RR412-REAL: prepared+verified+smoke in \(String(format: "%.2f", prepareSeconds))s offline")
        await manager.cleanup()
    }
}

private final class RealPhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [STTPreparationPhase] = []
    var values: [STTPreparationPhase] { lock.withLock { _values } }
    @Sendable func append(_ phase: STTPreparationPhase) { lock.withLock { _values.append(phase) } }
}
