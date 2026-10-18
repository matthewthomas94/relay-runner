import CryptoKit
import FluidAudio
import Foundation
import os

/// Named preparation phases. Only `downloading` carries a percentage, taken
/// from FluidAudio's byte progress; compile and verify never report one.
enum STTPreparationPhase: Equatable, Sendable {
    case checking
    case downloading(completed: Int, total: Int, fraction: Double)
    case compiling(String)
    case verifying

    func statusText(for model: STTModel) -> String {
        switch self {
        case .checking:
            return "Checking \(model.displayName) model..."
        case .downloading(let completed, let total, let fraction):
            return "Downloading \(model.displayName) \(completed)/\(total) (\(Int(fraction * 100))%)"
        case .compiling(let name):
            return "Compiling \(name)..."
        case .verifying:
            return "Verifying \(model.displayName)..."
        }
    }
}

/// What was actually verified for a prepared model. Parakeet keeps its legacy
/// unpinned cache, so it records no model revision and no verified files.
struct STTPreparedModelIdentity: Equatable, Sendable {
    let model: STTModel
    let repository: String
    let modelRevision: String?
    let runtime: String
    let verifiedFiles: Int
}

enum STTPreparationError: LocalizedError, Equatable {
    case offline(STTModel)
    case insufficientDisk(STTModel, requiredBytes: Int64)
    case integrity(STTModel, files: [String])
    case smokeFailed(STTModel, String)
    case downloadFailed(STTModel, String)

    // Phrasing deliberately matches ErrorTranslator's network/disk heuristics.
    var errorDescription: String? {
        switch self {
        case .offline(let model):
            return "Could not reach Hugging Face to download \(model.displayName). "
                + "Connect to the internet and retry; cached models are used when present."
        case .insufficientDisk(let model, let bytes):
            return "No space left on device for \(model.displayName) "
                + "(needs about \(bytes / 1_000_000) MB). Free disk space and retry."
        case .integrity(let model, let files):
            return "\(model.displayName) model files failed verification after a fresh download "
                + "(\(files.prefix(3).joined(separator: ", "))). Retry, or choose a Parakeet model."
        case .smokeFailed(let model, let reason):
            return "\(model.displayName) failed its local readiness check: \(reason)"
        case .downloadFailed(let model, let reason):
            return "Failed to download \(model.displayName): \(reason)"
        }
    }
}

/// Process-wide preparation for STT models. Download and verification are
/// deduplicated per model; each caller still gets its own `AsrManager`, so no
/// inference state is shared between ordinary STT and Note Taker.
actor STTModelPreparation {
    struct Environment: Sendable {
        /// The model's FluidAudio repo directory (outside the app bundle).
        var modelDirectory: @Sendable (STTModel) -> URL
        var download: @Sendable (
            _ model: STTModel, _ directory: URL, _ force: Bool,
            _ progress: @escaping @Sendable (STTPreparationPhase) -> Void
        ) async throws -> Void
        var availableCapacity: @Sendable (URL) -> Int64?
        var removeDirectory: @Sendable (URL) throws -> Void
        var phononManifest: [PhononManifest.File] = PhononManifest.files
    }

    static let shared = STTModelPreparation()

    static let runtime = "FluidAudio 0.17.5 (0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7)"
    static let phononRepository = "FluidInference/phonon-2-coreml"
    static let phononRevision = "a812a0dfef205660787ef6234317ab79acf4d5d6"

    private static let logger = Logger(subsystem: "com.relay-runner", category: "STTModelPreparation")

    private let environment: Environment
    private var inFlight: [STTModel: InFlight] = [:]
    private var loadBusy = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    private final class InFlight: @unchecked Sendable {
        let task: Task<STTPreparedModelIdentity, Error>
        let fanout: ProgressFanout
        var waiters = 0
        init(task: Task<STTPreparedModelIdentity, Error>, fanout: ProgressFanout) {
            self.task = task
            self.fanout = fanout
        }
    }

    init(environment: Environment = .live) {
        self.environment = environment
    }

    // MARK: - Assets

    /// Ensures the model's files are present (and, for Phonon, digest-verified).
    /// Concurrent callers share one attempt; a failed attempt is forgotten so
    /// the next call retries.
    func ensureAssets(
        for model: STTModel,
        progress: @escaping @Sendable (STTPreparationPhase) -> Void
    ) async throws -> STTPreparedModelIdentity {
        let entry: InFlight
        if let existing = inFlight[model] {
            entry = existing
        } else {
            let fanout = ProgressFanout()
            let environment = environment
            let task = Task {
                try await Self.prepareAssets(model, environment: environment, progress: fanout.emit)
            }
            entry = InFlight(task: task, fanout: fanout)
            inFlight[model] = entry
            Task { [weak self] in
                _ = try? await task.value
                await self?.finish(model, entry)
            }
        }
        let observer = entry.fanout.add(progress)
        entry.waiters += 1
        defer {
            entry.fanout.remove(observer)
            entry.waiters -= 1
        }
        let identity = try await withTaskCancellationHandler {
            try await entry.task.value
        } onCancel: {
            Task { await self.cancelIfAbandoned(model, entry) }
        }
        try Task.checkCancellation()
        return identity
    }

    private func finish(_ model: STTModel, _ entry: InFlight) {
        if inFlight[model] === entry { inFlight[model] = nil }
    }

    private func cancelIfAbandoned(_ model: STTModel, _ entry: InFlight) {
        if entry.waiters <= 1 { entry.task.cancel() }
    }

    private static func prepareAssets(
        _ model: STTModel,
        environment: Environment,
        progress: @escaping @Sendable (STTPreparationPhase) -> Void
    ) async throws -> STTPreparedModelIdentity {
        progress(.checking)
        let directory = environment.modelDirectory(model)
        guard model == .phonon2 else {
            try await classify(model) {
                try await environment.download(model, directory, false, progress)
            }
            return STTPreparedModelIdentity(
                model: model, repository: model.repository, modelRevision: nil,
                runtime: runtime, verifiedFiles: 0)
        }

        let manifest = environment.phononManifest
        let requiredBytes = PhononManifest.totalBytes(manifest)
        if PhononManifest.missingFiles(manifest, in: directory).isEmpty == false,
            let capacity = environment.availableCapacity(directory),
            capacity < requiredBytes
        {
            throw STTPreparationError.insufficientDisk(model, requiredBytes: requiredBytes)
        }
        try await classify(model) {
            try await environment.download(model, directory, false, progress)
        }
        progress(.verifying)
        if try PhononManifest.mismatchedFiles(manifest, in: directory).isEmpty == false {
            // Only the pinned Phonon repo directory is ever removed; Parakeet
            // caches live in their own directories and are never touched.
            logger.warning("Phonon cache failed digest verification; re-downloading pinned revision")
            try environment.removeDirectory(directory)
            try await classify(model) {
                try await environment.download(model, directory, true, progress)
            }
            progress(.verifying)
            let stillBad = try PhononManifest.mismatchedFiles(manifest, in: directory)
            guard stillBad.isEmpty else {
                throw STTPreparationError.integrity(model, files: stillBad)
            }
        }
        let identity = STTPreparedModelIdentity(
            model: model, repository: phononRepository, modelRevision: phononRevision,
            runtime: runtime, verifiedFiles: manifest.count)
        logger.info(
            "Prepared \(model.rawValue, privacy: .public) \(phononRevision, privacy: .public) on \(runtime, privacy: .public); \(identity.verifiedFiles) files verified"
        )
        return identity
    }

    private static func classify(_ model: STTModel, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as STTPreparationError {
            throw error
        } catch {
            throw classifyFailure(error, model: model)
        }
    }

    static func classifyFailure(_ error: Error, model: STTModel) -> Error {
        if let download = error as? DownloadError {
            switch download {
            case .networkDisabled: return STTPreparationError.offline(model)
            case .downloadFailed(_, let underlying): return classifyFailure(underlying, model: model)
            default: break
            }
        }
        if let url = error as? URLError {
            if url.code == .cancelled { return CancellationError() }
            return STTPreparationError.offline(model)
        }
        let ns = error as NSError
        if (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
            || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
        {
            return STTPreparationError.insufficientDisk(model, requiredBytes: PhononManifest.totalBytes(PhononManifest.files))
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            let classified = classifyFailure(underlying, model: model)
            if classified is STTPreparationError || classified is CancellationError { return classified }
        }
        return STTPreparationError.downloadFailed(model, error.localizedDescription)
    }

    // MARK: - Managers

    /// Prepares assets, loads a caller-owned manager and runs a local smoke
    /// transcription before returning. Loads are serialized process-wide; a
    /// cancelled caller's manager is cleaned up and never returned.
    func prepareManager(
        for model: STTModel,
        progress: @escaping @Sendable (STTPreparationPhase) -> Void
    ) async throws -> AsrManager {
        let identity = try await ensureAssets(for: model, progress: progress)
        await acquireLoadTurn()
        defer { releaseLoadTurn() }
        try Task.checkCancellation()

        let directory = environment.modelDirectory(model)
        let models: AsrModels
        do {
            if model == .phonon2 {
                // Load exactly the verified bytes: no network, no purge.
                models = try AsrModels.loadLocal(from: directory, version: model.asrVersion)
            } else {
                models = try await AsrModels.load(from: directory, version: model.asrVersion) { update in
                    if case .compiling(let name) = update.phase { progress(.compiling(name)) }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw STTPreparationError.smokeFailed(model, error.localizedDescription)
        }
        let manager = AsrManager()
        do {
            try await manager.loadModels(models)
            progress(.verifying)
            try await Self.smoke(manager)
            try Task.checkCancellation()
        } catch {
            await manager.cleanup()
            if error is CancellationError { throw error }
            throw STTPreparationError.smokeFailed(model, error.localizedDescription)
        }
        Self.logger.info(
            "\(model.rawValue, privacy: .public) passed local smoke; revision \(identity.modelRevision ?? "legacy", privacy: .public)"
        )
        return manager
    }

    /// One second of silence through the full pipeline with a fresh decoder state.
    static func smoke(_ manager: AsrManager) async throws {
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
    }

    private func acquireLoadTurn() async {
        if loadBusy {
            await withCheckedContinuation { loadWaiters.append($0) }
        } else {
            loadBusy = true
        }
    }

    private func releaseLoadTurn() {
        if loadWaiters.isEmpty {
            loadBusy = false
        } else {
            loadWaiters.removeFirst().resume()
        }
    }
}

extension STTModel {
    var repository: String {
        switch self {
        case .phonon2: return STTModelPreparation.phononRepository
        case .parakeetV2: return "FluidInference/parakeet-tdt-0.6b-v2-coreml"
        case .parakeetV3: return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        }
    }
}

extension STTModelPreparation.Environment {
    static let live = STTModelPreparation.Environment(
        modelDirectory: { AsrModels.defaultCacheDirectory(for: $0.asrVersion) },
        download: { model, directory, force, progress in
            STTModelPreparation.applyRevisionPins()
            try await AsrModels.download(to: directory, force: force, version: model.asrVersion) { update in
                switch update.phase {
                case .listing:
                    progress(.checking)
                case .downloading(let completed, let total):
                    progress(.downloading(completed: completed, total: total, fraction: update.fractionCompleted))
                case .compiling(let name):
                    progress(.compiling(name))
                }
            }
        },
        availableCapacity: { directory in
            var url = directory
            while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
                url.deleteLastPathComponent()
            }
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        },
        removeDirectory: { directory in
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    )
}

extension STTModelPreparation {
    private static let pinLock = NSLock()

    /// Pins Phonon only. Pinning Parakeet would make FluidAudio purge the
    /// existing unmarked `main` caches users already depend on.
    static func applyRevisionPins() {
        pinLock.lock()
        defer { pinLock.unlock() }
        if ModelRegistry.revisionOverrides[phononRepository] != phononRevision {
            ModelRegistry.revisionOverrides[phononRepository] = phononRevision
        }
    }
}

/// Broadcasts one shared attempt's progress to every waiting caller.
private final class ProgressFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable (STTPreparationPhase) -> Void] = [:]

    func add(_ observer: @escaping @Sendable (STTPreparationPhase) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return id
    }

    func remove(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }

    @Sendable func emit(_ phase: STTPreparationPhase) {
        lock.lock()
        let current = Array(observers.values)
        lock.unlock()
        current.forEach { $0(phase) }
    }
}

/// SHA-256 manifest for the pinned Phonon revision (docs/validation/rr-411/model-files.json).
enum PhononManifest {
    struct File {
        let path: String
        let size: Int64
        let sha256: String
    }

    static let files: [File] = [
        File(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "3d1a9cd4d7b7956d20c48d9a8041717f9f02c6db72dfeda565080e1cff1db3a3"),
        File(path: "Decoder.mlmodelc/coremldata.bin", size: 554, sha256: "2590e4588972f8d3d1ddb10ce603decffd2e9bb79a88c6096a58c5732f6369fd"),
        File(path: "Decoder.mlmodelc/model.mil", size: 13110, sha256: "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955"),
        File(path: "Decoder.mlmodelc/weights/weight.bin", size: 23604992, sha256: "05181616ed1af70b2aad0463d08d1d73a245af4ccb6159df79994f28c135d9d6"),
        File(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c81b869306f38dce16359c8594ef2b4026cb60d91089aa758998b5d43357754b"),
        File(path: "Encoder.mlmodelc/coremldata.bin", size: 542, sha256: "f8cef401c9d1d05e11fc2749245df86a38b9f81f8404e94fa054700d6a4394d9"),
        File(path: "Encoder.mlmodelc/model.mil", size: 1012823, sha256: "03eba2ef3abae8a90a3d525d60c1aff3ecbbcbf815389df20738e793be3579ad"),
        File(path: "Encoder.mlmodelc/weights/weight.bin", size: 319611456, sha256: "d76b3604417342bf06dc39c01cdb8a6f5d129c835c4442cf8ff92c08d51b8889"),
        File(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "7b53f663c4400205f8bc00243076de50f95d8a1a64978dee7232eb0ddc7d683c"),
        File(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 586, sha256: "8d2170f28b28466476f62484a0c8b07c2d31713ac254d1b7cf80eba8070e9554"),
        File(path: "JointDecisionv3.mlmodelc/model.mil", size: 11777, sha256: "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0"),
        File(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12642764, sha256: "5f922e335bc57174645fd6ede581395f1ae846f7227898301b5a1a7585f4ab45"),
        File(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        File(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        File(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        File(path: "Preprocessor.mlmodelc/model.mil", size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        File(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        File(path: "config.json", size: 1626, sha256: "cca35a1f8312b7fa099a41089185815773366190b4287690a193ae649b4ee0f8"),
        File(path: "parakeet_v3_vocab.json", size: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        File(path: "parakeet_vocab.json", size: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
    ]

    static func totalBytes(_ files: [File]) -> Int64 { files.reduce(0) { $0 + $1.size } }

    static func missingFiles(_ files: [File], in directory: URL) -> [String] {
        files.map(\.path).filter {
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Paths that are missing, the wrong size, or fail the SHA-256 check.
    static func mismatchedFiles(_ files: [File], in directory: URL) throws -> [String] {
        try files.compactMap { file in
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(file.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
            guard size == file.size, let digest = sha256(of: url), digest == file.sha256 else {
                return file.path
            }
            return nil
        }
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
