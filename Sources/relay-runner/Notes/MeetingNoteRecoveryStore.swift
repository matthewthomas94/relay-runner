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

    private static let journalFilename = "journal.json"
    /// Capture checkpoints arrive several times a second for the whole meeting.
    /// They live beside the journal so each one costs only its own size, never
    /// a decode and rewrite of the transcript-bearing journal.
    private static let producerCheckpointFilename = "producer-checkpoint.json"

    /// Write-through mirror of one session's files.
    private struct Session {
        var journal: MeetingNoteRecoveryJournal
        private let acknowledgedTextBySegment: [String: String]
        private let persistedFinalRevisionBySegment: [String: Int]

        init(journal: MeetingNoteRecoveryJournal) {
            self.journal = journal
            acknowledgedTextBySegment = Dictionary(
                journal.canonicalSegments.map { ($0.segmentID, $0.text) },
                uniquingKeysWith: { _, latest in latest }
            )
            persistedFinalRevisionBySegment = Dictionary(
                journal.revisions.filter(\.isFinal).map { ($0.segmentID, $0.revision) },
                uniquingKeysWith: max
            )
        }

        /// Transcript the journal already holds leaves the capture checkpoint,
        /// so the checkpoint stays proportional to unsaved work.
        func filtered(_ checkpoint: MeetingProducerCheckpoint) -> MeetingProducerCheckpoint {
            guard let revisions = checkpoint.durableRevisions else { return checkpoint }
            var value = checkpoint
            value.durableRevisions = revisions.filter { revision in
                if acknowledgedTextBySegment[revision.segmentID] == revision.text { return false }
                guard revision.isFinal,
                      let persisted = persistedFinalRevisionBySegment[revision.segmentID] else {
                    return true
                }
                return revision.revision > persisted
            }
            return value
        }
    }

    private let root: URL
    private let audioBudgetBytes: Int
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var sessions: [String: Session] = [:]
    private var audioAwaitingCheckpoint: [String: Set<String>] = [:]
    private var audioBytesBySession: [String: Int] = [:]

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
        var value = journal
        if let currentCheckpoint = try? session(journal.sessionID)?.journal.producerCheckpoint,
           shouldPreserveCheckpoint(currentCheckpoint, over: journal.producerCheckpoint) {
            // A capture callback may persist a newer replay cursor while an
            // artifact writer call is in flight. A completed final window can
            // also remove pending descriptors without accepting another chunk.
            value.producerCheckpoint = currentCheckpoint
        }
        var session = Session(journal: value)
        session.journal.producerCheckpoint = value.producerCheckpoint.map(session.filtered)
        try write(session.journal, to: directory.appendingPathComponent(Self.journalFilename))
        sessions[journal.sessionID] = session
    }

    private func shouldPreserveCheckpoint(
        _ current: MeetingProducerCheckpoint,
        over candidate: MeetingProducerCheckpoint?
    ) -> Bool {
        guard let candidate else { return true }
        let currentCount = current.metrics.acceptedChunkCount
        let candidateCount = candidate.metrics.acceptedChunkCount
        if currentCount != candidateCount { return currentCount > candidateCount }
        if current.metrics.processedWindowCount != candidate.metrics.processedWindowCount {
            return current.metrics.processedWindowCount > candidate.metrics.processedWindowCount
        }
        let currentRevisions = Set((current.durableRevisions ?? []).map(\.segmentID))
        let candidateRevisions = Set((candidate.durableRevisions ?? []).map(\.segmentID))
        if currentRevisions.isStrictSuperset(of: candidateRevisions) { return true }
        let currentPending = Set(current.pendingAudio.map(\.chunkID))
        let candidatePending = Set(candidate.pendingAudio.map(\.chunkID))
        return currentPending.isStrictSubset(of: candidatePending)
    }

    func load(sessionID: String) throws -> MeetingNoteRecoveryJournal? {
        try session(sessionID)?.journal
    }

    func loadAll() throws -> [MeetingNoteRecoveryJournal] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { directory in
            guard let stored = try readSession(in: directory) else { return nil }
            return sessions[stored.journal.sessionID]?.journal ?? stored.journal
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
            audioAwaitingCheckpoint[sessionID, default: []].insert(audio.descriptor.chunkID)
            return
        }

        let usedBytes = try audioBytesBySession[sessionID] ?? directorySize(directory)
        guard usedBytes + expectedBytes <= audioBudgetBytes else {
            throw MeetingNoteRecoveryStoreError.audioBudgetExceeded(limitBytes: audioBudgetBytes)
        }
        let data = audio.samples.withUnsafeBytes { Data($0) }
        do {
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            audioBytesBySession.removeValue(forKey: sessionID)
            throw error
        }
        audioBytesBySession[sessionID] = usedBytes + expectedBytes
        audioAwaitingCheckpoint[sessionID, default: []].insert(audio.descriptor.chunkID)
    }

    func saveProducerCheckpoint(
        sessionID: String,
        checkpoint: MeetingProducerCheckpoint
    ) throws {
        guard var session = try session(sessionID) else {
            throw MeetingNoteRecoveryStoreError.invalidAudio(sessionID)
        }
        let filtered = session.filtered(checkpoint)
        try write(
            filtered,
            to: try sessionDirectory(sessionID, create: false)
                .appendingPathComponent(Self.producerCheckpointFilename)
        )
        session.journal.producerCheckpoint = filtered
        sessions[sessionID] = session
        audioAwaitingCheckpoint[sessionID]?.subtract(checkpoint.pendingAudio.map(\.chunkID))
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
        var usedBytes = try audioBytesBySession[sessionID] ?? directorySize(directory)
        audioBytesBySession.removeValue(forKey: sessionID)
        let retainedFilenames = Set(chunkIDs.map(encodedFilename))
        for url in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) where !retainedFilenames.contains(url.lastPathComponent) {
            usedBytes -= try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try fileManager.removeItem(at: url)
        }
        audioBytesBySession[sessionID] = usedBytes
    }

    func retainCheckpointAudio(sessionID: String) throws {
        let retained = Set(
            try load(sessionID: sessionID)?.producerCheckpoint?.pendingAudio.map(\.chunkID) ?? []
        ).union(audioAwaitingCheckpoint[sessionID] ?? [])
        try retainAudio(sessionID: sessionID, chunkIDs: retained)
    }

    func removeSession(sessionID: String) throws {
        let directory = try sessionDirectory(sessionID, create: false)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
        sessions.removeValue(forKey: sessionID)
        audioAwaitingCheckpoint.removeValue(forKey: sessionID)
        audioBytesBySession.removeValue(forKey: sessionID)
    }

    private func session(_ sessionID: String) throws -> Session? {
        if let session = sessions[sessionID] { return session }
        guard let session = try readSession(in: try sessionDirectory(sessionID, create: false)) else {
            return nil
        }
        sessions[sessionID] = session
        return session
    }

    /// The journal and the capture checkpoint are written independently, so
    /// recovery keeps whichever replay cursor is newer.
    private func readSession(in directory: URL) throws -> Session? {
        let journalURL = directory.appendingPathComponent(Self.journalFilename)
        guard fileManager.fileExists(atPath: journalURL.path) else { return nil }
        var journal = try decoder.decode(
            MeetingNoteRecoveryJournal.self,
            from: Data(contentsOf: journalURL)
        )
        let checkpointURL = directory.appendingPathComponent(Self.producerCheckpointFilename)
        if fileManager.fileExists(atPath: checkpointURL.path) {
            let checkpoint = try decoder.decode(
                MeetingProducerCheckpoint.self,
                from: Data(contentsOf: checkpointURL)
            )
            if shouldPreserveCheckpoint(checkpoint, over: journal.producerCheckpoint) {
                journal.producerCheckpoint = checkpoint
            }
        }
        return Session(journal: journal)
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
