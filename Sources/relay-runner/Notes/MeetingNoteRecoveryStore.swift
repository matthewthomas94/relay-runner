import Foundation

enum MeetingNoteRecoveryStoreError: LocalizedError, Equatable {
    case audioBudgetExceeded(limitBytes: Int)
    case missingAudio(String)
    case invalidAudio(String)

    var errorDescription: String? {
        switch self {
        case .audioBudgetExceeded(let limitBytes):
            return "Meeting recovery audio reached its \(limitBytes)-byte local limit."
        case .missingAudio:
            return "Required meeting recovery audio is unavailable."
        case .invalidAudio:
            return "Meeting recovery audio is invalid."
        }
    }
}

/// Recovery data is local working state, never a project artifact. Implementations
/// must not log samples, transcript text, or capability tokens.
protocol MeetingNoteRecoveryStoring: Sendable {
    func save(_ journal: MeetingNoteRecoveryJournal) async throws
    func load(sessionID: String) async throws -> MeetingNoteRecoveryJournal?
    func loadAll() async throws -> [MeetingNoteRecoveryJournal]
    func persistAudio(sessionID: String, audio: MeetingAcceptedAudio) async throws
    func saveProducerCheckpoint(
        sessionID: String,
        checkpoint: MeetingProducerCheckpoint
    ) async throws
    func loadAudio(
        sessionID: String,
        descriptors: [MeetingAcceptedAudioDescriptor]
    ) async throws -> [MeetingAcceptedAudio]
    func retainAudio(sessionID: String, chunkIDs: Set<String>) async throws
    func retainCheckpointAudio(sessionID: String) async throws
    func removeSession(sessionID: String) async throws
}

actor MeetingNoteRecoveryStore: MeetingNoteRecoveryStoring {
    static let defaultAudioBudgetBytes = 256 * 1_024 * 1_024

    private let root: URL
    private let audioBudgetBytes: Int
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        root: URL = MeetingNoteRecoveryStore.defaultRoot(),
        audioBudgetBytes: Int = MeetingNoteRecoveryStore.defaultAudioBudgetBytes,
        fileManager: FileManager = .default
    ) {
        precondition(audioBudgetBytes > 0)
        self.root = root
        self.audioBudgetBytes = audioBudgetBytes
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Relay Runner", isDirectory: true)
            .appendingPathComponent("Note Recovery", isDirectory: true)
    }

    func save(_ journal: MeetingNoteRecoveryJournal) throws {
        let directory = try sessionDirectory(journal.sessionID, create: true)
        let url = directory.appendingPathComponent("journal.json")
        var value = journal
        if fileManager.fileExists(atPath: url.path),
           let current = try? decoder.decode(
            MeetingNoteRecoveryJournal.self,
            from: Data(contentsOf: url)
           ),
           let currentCheckpoint = current.producerCheckpoint,
           currentCheckpoint.metrics.acceptedChunkCount
            > (journal.producerCheckpoint?.metrics.acceptedChunkCount ?? -1) {
            // A capture callback may persist a newer replay cursor while an
            // artifact writer call is in flight. Never let the older caller
            // regress that cursor when it records the writer response.
            value.producerCheckpoint = currentCheckpoint
        }
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func load(sessionID: String) throws -> MeetingNoteRecoveryJournal? {
        let url = try sessionDirectory(sessionID, create: false)
            .appendingPathComponent("journal.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(
            MeetingNoteRecoveryJournal.self,
            from: Data(contentsOf: url)
        )
    }

    func loadAll() throws -> [MeetingNoteRecoveryJournal] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { directory in
            let url = directory.appendingPathComponent("journal.json")
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try decoder.decode(
                MeetingNoteRecoveryJournal.self,
                from: Data(contentsOf: url)
            )
        }.sorted { $0.updatedAt < $1.updatedAt }
    }

    func persistAudio(sessionID: String, audio: MeetingAcceptedAudio) throws {
        let directory = try audioDirectory(sessionID: sessionID, create: true)
        let url = directory.appendingPathComponent(encodedFilename(audio.descriptor.chunkID))
        let expectedBytes = audio.samples.count * MemoryLayout<Float>.size
        if fileManager.fileExists(atPath: url.path) {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.size] as? Int == expectedBytes else {
                throw MeetingNoteRecoveryStoreError.invalidAudio(audio.descriptor.chunkID)
            }
            return
        }

        let usedBytes = try directorySize(directory)
        guard usedBytes + expectedBytes <= audioBudgetBytes else {
            throw MeetingNoteRecoveryStoreError.audioBudgetExceeded(limitBytes: audioBudgetBytes)
        }
        let data = audio.samples.withUnsafeBytes { Data($0) }
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func saveProducerCheckpoint(
        sessionID: String,
        checkpoint: MeetingProducerCheckpoint
    ) throws {
        guard var journal = try load(sessionID: sessionID) else {
            throw MeetingNoteRecoveryStoreError.invalidAudio(sessionID)
        }
        journal.producerCheckpoint = checkpoint
        journal.updatedAt = Date().ISO8601Format(.iso8601)
        try save(journal)
    }

    func loadAudio(
        sessionID: String,
        descriptors: [MeetingAcceptedAudioDescriptor]
    ) throws -> [MeetingAcceptedAudio] {
        let directory = try audioDirectory(sessionID: sessionID, create: false)
        return try descriptors.map { descriptor in
            let url = directory.appendingPathComponent(encodedFilename(descriptor.chunkID))
            guard fileManager.fileExists(atPath: url.path) else {
                throw MeetingNoteRecoveryStoreError.missingAudio(descriptor.chunkID)
            }
            let data = try Data(contentsOf: url)
            let expectedBytes = descriptor.sampleCount * MemoryLayout<Float>.size
            guard data.count == expectedBytes else {
                throw MeetingNoteRecoveryStoreError.invalidAudio(descriptor.chunkID)
            }
            var samples = [Float](repeating: 0, count: descriptor.sampleCount)
            _ = samples.withUnsafeMutableBytes { destination in
                data.copyBytes(to: destination)
            }
            return MeetingAcceptedAudio(descriptor: descriptor, samples: samples)
        }
    }

    func retainAudio(sessionID: String, chunkIDs: Set<String>) throws {
        let directory = try audioDirectory(sessionID: sessionID, create: false)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let retainedFilenames = Set(chunkIDs.map(encodedFilename))
        for url in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) where !retainedFilenames.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
        }
    }

    func retainCheckpointAudio(sessionID: String) throws {
        let retained = Set(
            try load(sessionID: sessionID)?.producerCheckpoint?.pendingAudio.map(\.chunkID) ?? []
        )
        try retainAudio(sessionID: sessionID, chunkIDs: retained)
    }

    func removeSession(sessionID: String) throws {
        let directory = try sessionDirectory(sessionID, create: false)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func sessionDirectory(_ sessionID: String, create: Bool) throws -> URL {
        if create {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let directory = root.appendingPathComponent(encodedDirectoryName(sessionID), isDirectory: true)
        if create {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return directory
    }

    private func audioDirectory(sessionID: String, create: Bool) throws -> URL {
        let directory = try sessionDirectory(sessionID, create: create)
            .appendingPathComponent("audio", isDirectory: true)
        if create {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return directory
    }

    private func directorySize(_ directory: URL) throws -> Int {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).reduce(into: 0) { result, url in
            result += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
    }

    private func encodedDirectoryName(_ value: String) -> String {
        "session-" + Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func encodedFilename(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "") + ".f32"
    }
}
