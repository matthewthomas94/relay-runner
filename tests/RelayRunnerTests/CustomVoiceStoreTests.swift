import AVFoundation
import Foundation
import XCTest
@testable import relay_runner

final class CustomVoiceStoreTests: XCTestCase {
    private var directory: URL!
    private var store: CustomVoiceStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("custom-voice-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = CustomVoiceStore(supportRoot: directory)
        let asset = directory.appendingPathComponent("asset")
        try Data("test".utf8).write(to: asset)
        let runtime: [String: Any] = [
            "schema_version": 1, "python": "/usr/bin/python3", "kokoclone_root": directory.path,
            "torch_home": directory.path, "kanade_config": asset.path, "kanade_weights": asset.path,
            "vocos_config": asset.path, "vocos_weights": asset.path, "sha256": ["fixture": "test"],
        ]
        try JSONSerialization.data(withJSONObject: runtime).write(to: store.runtimeURL)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func samples(_ seconds: Int = 5) -> [Float] {
        (0..<(seconds * 24_000)).map { Float(sin(Double($0) * 2 * .pi * 220 / 24_000) * 0.2) }
    }

    private func draft() throws -> CustomVoiceProfile {
        try store.createDraft(samples: samples(), name: "My Voice", baseVoice: "bm_george", affirmed: true)
    }

    func testSaveIsAtomicAndOnlyStoresSelectedNormalizedReference() throws {
        let profile = try draft()
        XCTAssertEqual(try store.load(profile.id, draft: true), profile)
        XCTAssertTrue(store.profiles().isEmpty)
        _ = try store.saveDraft(profile.id)
        XCTAssertEqual(store.profiles(), [profile])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.folder(profile.id, draft: true).path))
        let files = try FileManager.default.contentsOfDirectory(atPath: store.folder(profile.id).path)
        XCTAssertEqual(Set(files), Set(["reference.wav", "manifest.json"]))
        let decoded = try CustomVoiceStore.decode(store.reference(profile.id))
        XCTAssertEqual(decoded.count, 120_000)
        XCTAssertEqual(profile.sample_rate, 24_000)
        XCTAssertEqual(profile.duration, 5)
        XCTAssertEqual(profile.base_voice, "bm_george")
    }

    func testPrivatePermissions() throws {
        let profile = try draft()
        for (url, expected) in [(store.root, 0o700), (try store.folder(profile.id, draft: true), 0o700),
                                (try store.reference(profile.id, draft: true), 0o600)] {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, expected)
        }
    }

    func testCancelDeleteAndRenameNeverTouchExternalOriginal() throws {
        let original = directory.appendingPathComponent("external.wav")
        let data = try CustomVoiceStore.pcmWAV(samples())
        try data.write(to: original)
        let first = try draft()
        try store.delete(first.id, draft: true)
        let second = try draft()
        _ = try store.saveDraft(second.id)
        try store.rename(second.id, name: "Renamed")
        XCTAssertEqual(try store.load(second.id).name, "Renamed")
        try store.delete(second.id)
        XCTAssertTrue(store.profiles().isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), data)
    }

    func testReferenceRejectsSilenceNonFiniteAndInvalidDuration() throws {
        XCTAssertThrowsError(try CustomVoiceStore.pcmWAV([Float](repeating: 0, count: 120_000)))
        var nonfinite = samples()
        nonfinite[0] = .nan
        XCTAssertThrowsError(try CustomVoiceStore.pcmWAV(nonfinite))
        XCTAssertThrowsError(try CustomVoiceStore.pcmWAV(samples(4)))
        XCTAssertThrowsError(try CustomVoiceStore.pcmWAV(samples(11)))
    }

    func testAffirmationIsRequiredAndNotImplicit() throws {
        XCTAssertThrowsError(try store.createDraft(samples: samples(), name: "Voice", baseVoice: "bm_george", affirmed: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }

    func testDamagedHashAndOversizedManifestAreRejected() throws {
        let profile = try draft()
        let folder = try store.folder(profile.id, draft: true)
        let reference = folder.appendingPathComponent("reference.wav")
        try Data("damaged".utf8).write(to: reference)
        XCTAssertThrowsError(try store.load(profile.id, draft: true))
        try Data(repeating: 32, count: 16_385).write(to: folder.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try store.load(profile.id, draft: true))
    }

    func testPathTraversalAndEscapingLinksAreRejected() throws {
        for id in ["../outside", "/tmp/a", String(repeating: "A", count: 32), ""] {
            XCTAssertThrowsError(try store.folder(id))
        }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let id = String(repeating: "c", count: 32)
        try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent(id), withDestinationURL: directory)
        XCTAssertThrowsError(try store.delete(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.runtimeURL.path))
    }

    func testMissingRuntimeDoesNotCreateOrSelectVoice() throws {
        try FileManager.default.removeItem(at: store.runtimeURL)
        XCTAssertThrowsError(try draft())
        XCTAssertTrue(store.profiles().isEmpty)
    }

    func testManagedRuntimeIsDiscoveredWithoutImportOrVoiceSelection() throws {
        XCTAssertEqual(store.runtimeURL, directory.appendingPathComponent("custom-voice-runtime.json"))
        let contents = try Data(contentsOf: store.runtimeURL)
        XCTAssertEqual(try store.runtimeFingerprint(), CustomVoiceStore.digest(contents))
        XCTAssertTrue(store.profiles().isEmpty)
        XCTAssertNil(TtsConfig().custom_voice_id)
    }

    func testInvalidManagedRuntimeIsRejectedWithoutChangingItsFiles() throws {
        let invalid = Data("{}".utf8)
        try invalid.write(to: store.runtimeURL)
        XCTAssertThrowsError(try store.runtimeFingerprint())
        XCTAssertEqual(try Data(contentsOf: store.runtimeURL), invalid)
    }

    func testInvalidNameDoesNotCreateOrLeakDraft() throws {
        for name in ["", "\n", String(repeating: "x", count: 81)] {
            XCTAssertThrowsError(try store.createDraft(samples: samples(), name: name, baseVoice: "bm_george", affirmed: true))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }

    func testRuntimeChangeRequiresMatchingPreviewBeforeProfileUpdate() throws {
        let profile = try draft()
        _ = try store.saveDraft(profile.id)
        let previousRuntime = profile.runtime_id
        var runtime = try JSONSerialization.jsonObject(with: Data(contentsOf: store.runtimeURL)) as! [String: Any]
        runtime["revision"] = "second"
        try JSONSerialization.data(withJSONObject: runtime).write(to: store.runtimeURL)
        let currentRuntime = try store.runtimeFingerprint()
        XCTAssertNotEqual(currentRuntime, previousRuntime)
        XCTAssertThrowsError(try store.acceptPreview(profile, runtimeID: previousRuntime, baseVoice: "bf_emma"))
        XCTAssertEqual(try store.load(profile.id).runtime_id, previousRuntime)
        try store.acceptPreview(profile, runtimeID: currentRuntime, baseVoice: "bf_emma")
        XCTAssertEqual(try store.load(profile.id).runtime_id, currentRuntime)
        XCTAssertEqual(try store.load(profile.id).base_voice, "bf_emma")
    }

    func testNativeDecoderAcceptsCompressedM4AAndMP3() throws {
        // The test-only encoder is optional; the app decodes natively and never requires it.
        guard let encoder = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("Optional fixture encoder is not installed.")
        }
        let source = directory.appendingPathComponent("source.wav")
        try CustomVoiceStore.pcmWAV(samples(6)).write(to: source)
        for ext in ["m4a", "mp3"] {
            let output = directory.appendingPathComponent("encoded.\(ext)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: encoder)
            process.arguments = ["-nostdin", "-v", "error", "-i", source.path, output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let decoded = try CustomVoiceStore.decode(output)
            XCTAssertEqual(Double(decoded.count) / 24_000, 6, accuracy: 0.15)
            XCTAssertTrue(decoded.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(decoded.map { abs($0) }.max() ?? 0, 0.1)
        }
    }

    func testConfigRoundTripAndLegacyDecode() throws {
        let manager = ConfigManager(configDir: directory)
        var config = AppConfig()
        XCTAssertNil(config.tts.custom_voice_id)
        config.tts.custom_voice_id = String(repeating: "d", count: 32)
        config.tts.voice = "bf_isabella"
        try manager.save(config)
        XCTAssertEqual(manager.load().tts, config.tts)
        config.tts.custom_voice_id = "../invalid\"\n"
        try manager.save(config)
        XCTAssertNil(manager.load().tts.custom_voice_id)
        let legacy = Data(#"{"engine":"kokoro","voice":"bm_george","rate":1.3,"auto_play":false,"chime":"Tink","show_notification":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TtsConfig.self, from: legacy).custom_voice_id)
    }

    func testAudioLeaseIsExclusiveAndReleaseAllowsNextOwner() throws {
        let first = try SettingsAudioLease(root: directory)
        XCTAssertThrowsError(try SettingsAudioLease(root: directory))
        first.release()
        let second = try SettingsAudioLease(root: directory)
        second.release()
    }

    func testImmediateVoiceDeletionPreservesUnrelatedSettingsDraft() {
        var previous = AppConfig()
        previous.tts.custom_voice_id = String(repeating: "a", count: 32)
        var draft = previous
        draft.tts.rate = 1.8
        draft.stt.vad_sensitivity = "high"
        var saved = previous
        saved.tts.custom_voice_id = nil
        saved.tts.voice = "bm_george"
        let reconciled = draft.mergingCustomVoiceRemoval(from: previous, to: saved)
        XCTAssertNil(reconciled.tts.custom_voice_id)
        XCTAssertEqual(reconciled.tts.rate, 1.8)
        XCTAssertEqual(reconciled.stt.vad_sensitivity, "high")
        draft.tts.custom_voice_id = String(repeating: "b", count: 32)
        XCTAssertEqual(draft.mergingCustomVoiceRemoval(from: previous, to: saved).tts.custom_voice_id,
                       draft.tts.custom_voice_id)
    }

    func testOrdinarySettingsSaveStillReconcilesWholeDraft() {
        let previous = AppConfig()
        var saved = previous
        saved.tts.rate = 1.7
        XCTAssertEqual(previous.mergingCustomVoiceRemoval(from: previous, to: saved), saved)
    }

    func testNativeDecoderAcceptsAIFFAndRejectsCorruptInput() throws {
        let input = directory.appendingPathComponent("input.wav")
        try CustomVoiceStore.pcmWAV(samples()).write(to: input)
        let source = try AVAudioFile(forReading: input)
        let aiff = directory.appendingPathComponent("input.aiff")
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length))!
        try source.read(into: buffer)
        do {
            let destination = try AVAudioFile(forWriting: aiff, settings: source.fileFormat.settings)
            try destination.write(from: buffer)
        }
        XCTAssertEqual(try CustomVoiceStore.decode(aiff).count, 120_000)
        XCTAssertEqual(try CustomVoiceStore.decode(input).count, 120_000)
        let corrupt = directory.appendingPathComponent("bad.mp3")
        try Data("not audio".utf8).write(to: corrupt)
        XCTAssertThrowsError(try CustomVoiceStore.decode(corrupt))
    }
}
