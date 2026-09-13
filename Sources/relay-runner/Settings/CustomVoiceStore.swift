import AVFoundation
import CryptoKit
import Darwin
import Foundation

enum CustomVoiceFailure: LocalizedError {
    case invalidAudio, duration, silent, unsafeStorage, invalidProfile, runtimeMissing, permission, affirmation, busy

    var errorDescription: String? {
        switch self {
        case .invalidAudio: return "Use a readable WAV, AIFF, M4A or MP3 under 25 MiB (up to 30 seconds)."
        case .duration: return "Choose between 5 and 10 seconds of speech."
        case .silent: return "This sample is too quiet. Choose a clear recording of one speaker."
        case .unsafeStorage: return "The private voice folder is unavailable or contains an unsafe link."
        case .invalidProfile: return "This voice is missing or damaged. Import and preview it again."
        case .runtimeMissing: return "The local cloning engine is missing or damaged. Repair the custom-voice installation; standard voices are still available."
        case .permission: return "Microphone permission is required to record a reference."
        case .affirmation: return "Confirm that you own the recording or have permission to use it for voice conversion."
        case .busy: return "Finish response playback or voice recording before previewing or recording a sample."
        }
    }
}

struct CustomVoiceProfile: Codable, Identifiable, Equatable, Sendable {
    var schema_version = 1
    let id: String
    var name: String
    let content_hash: String
    let sample_rate: Int
    let duration: Double
    let created_at: String
    let affirmation_version: Int
    let affirmation_at: String
    var runtime_id: String
    var base_voice: String
}

/// Owns only normalized references and manifests; external originals are never changed.
final class CustomVoiceStore: @unchecked Sendable {
    static let didRenameNotification = Notification.Name("RelayCustomVoiceDidRename")
    static let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("relay-runner", isDirectory: true)
    let supportRoot: URL
    var root: URL { supportRoot.appendingPathComponent("voices", isDirectory: true) }
    var runtimeURL: URL { supportRoot.appendingPathComponent("custom-voice-runtime.json") }

    init(supportRoot: URL = CustomVoiceStore.supportRoot) { self.supportRoot = supportRoot }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func privateDirectory(_ url: URL) throws {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw CustomVoiceFailure.unsafeStorage
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func folder(_ id: String, draft: Bool = false) throws -> URL {
        guard Self.validID(id) else { throw CustomVoiceFailure.invalidProfile }
        let parent = draft ? root.appendingPathComponent(".drafts", isDirectory: true) : root
        let result = parent.appendingPathComponent(id, isDirectory: true)
        for url in [root, parent, result] {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CustomVoiceFailure.unsafeStorage
            }
        }
        guard result.resolvingSymlinksInPath().deletingLastPathComponent() == parent.resolvingSymlinksInPath() else {
            throw CustomVoiceFailure.unsafeStorage
        }
        return result
    }

    func reference(_ id: String, draft: Bool = false) throws -> URL {
        let result = try folder(id, draft: draft).appendingPathComponent("reference.wav")
        _ = try boundedData(result, maximum: 500_000)
        return result
    }

    func boundedData(_ url: URL, maximum: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CustomVoiceFailure.invalidProfile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximum else { throw CustomVoiceFailure.invalidProfile }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw CustomVoiceFailure.invalidProfile }
        return data
    }

    func load(_ id: String, draft: Bool = false) throws -> CustomVoiceProfile {
        let url = try folder(id, draft: draft)
        let manifest = try JSONDecoder().decode(CustomVoiceProfile.self,
                                               from: boundedData(url.appendingPathComponent("manifest.json"), maximum: 16_384))
        let audio = try boundedData(url.appendingPathComponent("reference.wav"), maximum: 500_000)
        guard manifest.schema_version == 1, manifest.id == id,
              manifest.sample_rate == 24_000, (5...10).contains(manifest.duration),
              manifest.content_hash == Self.digest(audio), manifest.affirmation_version == 1 else {
            throw CustomVoiceFailure.invalidProfile
        }
        return manifest
    }

    func profiles() -> [CustomVoiceProfile] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { try? load($0.lastPathComponent) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func runtimeFingerprint() throws -> String {
        let data = try boundedData(runtimeURL, maximum: 16_384)
        try validateRuntime(data)
        return Self.digest(data)
    }

    private func validateRuntime(_ data: Data) throws {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["schema_version"] as? Int == 1, value["sha256"] is [String: String] else {
            throw CustomVoiceFailure.runtimeMissing
        }
        for key in ["python", "kokoclone_root", "kanade_config", "kanade_weights", "vocos_config", "vocos_weights", "torch_home"] {
            guard let path = value[key] as? String, path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: path) else { throw CustomVoiceFailure.runtimeMissing }
        }
    }

    /// Native decoding is bounded before allocation, then resampled once to 24 kHz mono.
    static func decode(_ url: URL) throws -> [Float] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 25 * 1024 * 1024,
              ["wav", "aif", "aiff", "m4a", "mp3"].contains(url.pathExtension.lowercased()) else {
            throw CustomVoiceFailure.invalidAudio
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard duration.isFinite, duration >= 5, duration <= 30, format.channelCount > 0,
              format.channelCount <= 8, format.sampleRate > 0,
              Double(file.length) * Double(format.channelCount) * 4 <= 64 * 1024 * 1024,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(duration * 24_000)) + 256) else {
            throw CustomVoiceFailure.invalidAudio
        }
        try file.read(into: input)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, result in
            if supplied { result.pointee = .endOfStream; return nil }
            supplied = true
            result.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, let channel = output.floatChannelData?[0] else { throw CustomVoiceFailure.invalidAudio }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        guard samples.allSatisfy(\.isFinite) else { throw CustomVoiceFailure.invalidAudio }
        return samples
    }

    static func pcmWAV(_ samples: [Float]) throws -> Data {
        guard (120_000...240_000).contains(samples.count), samples.allSatisfy(\.isFinite) else { throw CustomVoiceFailure.duration }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        guard rms >= 0.001 else { throw CustomVoiceFailure.silent }
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(samples.count * 2 + 36)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16); ascii("data"); u32(UInt32(samples.count * 2))
        for sample in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32767))) }
        return data
    }

    func createDraft(samples: [Float], name: String, baseVoice: String, affirmed: Bool) throws -> CustomVoiceProfile {
        guard affirmed else { throw CustomVoiceFailure.affirmation }
        let normalizedName = try validatedName(name)
        let audio = try Self.pcmWAV(samples)
        let runtime = try runtimeFingerprint()
        try privateDirectory(root)
        try privateDirectory(root.appendingPathComponent(".drafts", isDirectory: true))
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let directory = try folder(id, draft: true)
        try privateDirectory(directory)
        let now = ISO8601DateFormatter().string(from: Date())
        let profile = CustomVoiceProfile(id: id, name: normalizedName, content_hash: Self.digest(audio),
                                         sample_rate: 24_000, duration: Double(samples.count) / 24_000,
                                         created_at: now, affirmation_version: 1, affirmation_at: now,
                                         runtime_id: runtime, base_voice: baseVoice)
        do {
            try writePrivate(audio, to: directory.appendingPathComponent("reference.wav"))
            try writePrivate(JSONEncoder().encode(profile), to: directory.appendingPathComponent("manifest.json"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return profile
    }

    func saveDraft(_ id: String) throws -> CustomVoiceProfile {
        let profile = try load(id, draft: true)
        try FileManager.default.moveItem(at: folder(id, draft: true), to: folder(id))
        return profile
    }

    func rename(_ id: String, name: String) throws {
        var profile = try load(id)
        profile.name = try validatedName(name)
        try writePrivate(JSONEncoder().encode(profile), to: folder(id).appendingPathComponent("manifest.json"))
        NotificationCenter.default.post(name: Self.didRenameNotification, object: nil)
    }

    func acceptPreview(_ profile: CustomVoiceProfile, runtimeID: String, baseVoice: String) throws {
        var current = try load(profile.id)
        guard current.content_hash == profile.content_hash,
              try runtimeFingerprint() == runtimeID else { throw CustomVoiceFailure.invalidProfile }
        current.runtime_id = runtimeID
        current.base_voice = baseVoice
        try writePrivate(JSONEncoder().encode(current), to: folder(profile.id).appendingPathComponent("manifest.json"))
    }

    func delete(_ id: String, draft: Bool = false) throws {
        // Only an exact validated managed directory, never a caller-supplied path.
        let directory = try folder(id, draft: draft)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CustomVoiceFailure.invalidProfile
        }
        return name
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CustomVoiceFailure.unsafeStorage }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
