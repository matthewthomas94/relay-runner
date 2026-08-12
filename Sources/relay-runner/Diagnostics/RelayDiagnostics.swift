import AppKit
import Darwin
import Foundation
import MetricKit
import OSLog

struct RelayDiagnosticRedaction: Equatable {
    let text: String
    let count: Int
}

enum RelayDiagnosticRedactor {
    private static let patterns: [(String, String)] = [
        (#"(?i)\b(authorization|token|secret|password|api[_-]?key)\s*[:=]\s*[^\s,;]+"#, "$1=[REDACTED]"),
        (#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]+"#, "$1 [REDACTED]"),
        (#"(?:file://)?/(?:Users|Volumes|private/tmp|tmp)/[^\s,;]+"#, "[PATH]"),
        (#"(?<!:)(?<![A-Za-z0-9])/(?:Applications|Library|System|opt|usr|var|etc|bin|sbin|dev|private)/[^\s,;]+"#, "[PATH]"),
        (#"\b(?:sk|ghp|github_pat|xox[baprs])-[-A-Za-z0-9_]{8,}\b"#, "[TOKEN]"),
    ]

    static func redact(_ value: String, limit: Int = 300) -> RelayDiagnosticRedaction {
        var output = String(value.prefix(limit))
        var count = value.count > limit ? 1 : 0
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            count += regex.numberOfMatches(in: output, range: range)
            output = regex.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: replacement
            )
        }
        return RelayDiagnosticRedaction(text: output, count: count)
    }
}

struct RelayDiagnosticEvent: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let timestamp: String
    let appSessionID: String
    let incidentID: String?
    let retryAttempt: Int?
    let correlationID: String
    let process: String
    let phase: String
    let outcome: String
    let provider: String?
    let summary: String?
    let attributes: [String: String]
    let redactionCount: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case timestamp
        case appSessionID = "app_session_id"
        case incidentID = "incident_id"
        case retryAttempt = "retry_attempt"
        case correlationID = "correlation_id"
        case process
        case phase
        case outcome
        case provider
        case summary
        case attributes
        case redactionCount = "redaction_count"
    }
}

struct RelaySupportBundlePreview: Equatable {
    let eventCount: Int
    let sourceFileCount: Int
    let redactionCount: Int

    static let included = [
        "allowlisted Relay event timeline",
        "Relay Runner version and macOS version",
        "retention and redaction policy",
    ]

    static let excluded = [
        "raw commands, transcripts, prompts, provider output, audio, and screenshots",
        "repository paths and repository contents",
        "credentials, worker logs, crash reports, and full temporary directories",
    ]

    var summary: String {
        "Includes \(eventCount) allowlisted local events from \(sourceFileCount) files; "
            + "excludes transcripts, repositories, credentials, provider output, audio, screenshots, "
            + "worker logs, crash reports, and temporary-directory contents. "
            + "Redactions: \(redactionCount)."
    }
}

struct RelayDiagnosticsExportAttempt: Equatable {
    let id: String
    let incidentID: String?
    let retryAttempt: Int?
}

enum RelayDiagnosticsExportError: LocalizedError {
    case exportInProgress
    case invalidAttempt
    case archiveFailed(Int32)
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .exportInProgress:
            return "A diagnostics export is already in progress."
        case .invalidAttempt:
            return "The diagnostics export attempt is no longer active."
        case let .archiveFailed(status):
            return "The diagnostics archiver exited with status \(status)."
        case .invalidArchive:
            return "The diagnostics archiver did not produce a valid archive."
        }
    }
}

final class RelayDiagnostics: @unchecked Sendable {
    static let shared = RelayDiagnostics()
    static let retentionDays = 7
    static let maximumBytes = 5 * 1_024 * 1_024
    static let lockWaitSeconds = 5.0
    static let lockStaleSeconds = 30.0
    static let allowedProcesses = Set(["app", "setup", "shell", "orchestrator", "provider"])
    static let allowedProviders = Set(["codex", "claude"])
    static let allowedAttributeKeys = Set([
        "build", "error_code", "exit_code", "launch_mode", "payload_count", "transport", "version",
    ])

    static func makeIncidentID() -> String {
        let compact = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "inc-\(compact.prefix(12))"
    }

    let appSessionID: String
    let journalDirectory: URL

    private let fileManager: FileManager
    private let now: () -> Date
    private let archiveCreator: (URL, URL) throws -> Void
    private let queue = DispatchQueue(label: "relay-runner.support-diagnostics")
    private let exportLock = NSLock()
    private var activeExportAttemptID: String?
    private let encoder = JSONEncoder()
    private let logger = Logger(subsystem: "com.relayrunner.app", category: "startup")
    private let signpostLog = OSLog(subsystem: "com.relayrunner.app", category: "startup")

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        appSessionID: String = UUID().uuidString.lowercased(),
        archiveCreator: ((URL, URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.now = now
        self.appSessionID = appSessionID
        self.archiveCreator = archiveCreator ?? Self.createArchive
        if let directory {
            journalDirectory = directory
        } else if let override = ProcessInfo.processInfo.environment["RELAY_DIAGNOSTICS_DIR"],
                  !override.isEmpty {
            journalDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            journalDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("relay-runner-support-tests-\(getpid())", isDirectory: true)
        } else {
            journalDirectory = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("relay-runner/support-diagnostics/v1", isDirectory: true)
        }
        encoder.outputFormatting = [.sortedKeys]
    }

    @discardableResult
    func record(
        process: String,
        phase: String,
        outcome: String,
        incidentID: String? = nil,
        retryAttempt: Int? = nil,
        correlationID: String = UUID().uuidString.lowercased(),
        provider: String? = nil,
        summary: String? = nil,
        attributes: [String: String] = [:]
    ) -> RelayDiagnosticEvent? {
        guard Self.allowedProcesses.contains(process),
              Self.isIdentifier(phase),
              Self.isIdentifier(outcome),
              provider.map(Self.allowedProviders.contains) ?? true,
              retryAttempt.map({ $0 > 0 }) ?? true,
              Set(attributes.keys).isSubset(of: Self.allowedAttributeKeys) else {
            return nil
        }

        var redactionCount = 0
        let safeAppSessionID = Self.safeID(appSessionID)
        redactionCount += safeAppSessionID.count
        let safeIncidentID = incidentID.map(Self.safeID)
        redactionCount += safeIncidentID?.count ?? 0
        let safeCorrelationID = Self.safeID(correlationID)
        redactionCount += safeCorrelationID.count
        let safeSummary = summary.map {
            let result = RelayDiagnosticRedactor.redact($0)
            redactionCount += result.count
            return result.text
        }
        var safeAttributes: [String: String] = [:]
        for (key, value) in attributes {
            let result = RelayDiagnosticRedactor.redact(value, limit: 120)
            redactionCount += result.count
            safeAttributes[key] = result.text
        }
        let event = RelayDiagnosticEvent(
            schemaVersion: RelayDiagnosticEvent.schemaVersion,
            timestamp: Self.timestamp(now()),
            appSessionID: safeAppSessionID.value,
            incidentID: safeIncidentID?.value,
            retryAttempt: retryAttempt,
            correlationID: safeCorrelationID.value,
            process: process,
            phase: phase,
            outcome: outcome,
            provider: provider,
            summary: safeSummary,
            attributes: safeAttributes,
            redactionCount: redactionCount
        )

        logger.notice("phase=\(phase, privacy: .public) outcome=\(outcome, privacy: .public) correlation=\(event.correlationID, privacy: .public)")
        os_signpost(.event, log: signpostLog, name: "RelayDiagnosticEvent", "%{public}s", phase)
        queue.sync { append(event) }
        return event
    }

    func preview() -> RelaySupportBundlePreview {
        queue.sync { previewLocked() }
    }

    func createSupportBundle(at destination: URL) throws {
        let attempt = try beginSupportBundleExport()
        try createSupportBundle(at: destination, attempt: attempt)
    }

    func beginSupportBundleExport(
        incidentID: String? = nil,
        retryAttempt: Int? = nil
    ) throws -> RelayDiagnosticsExportAttempt {
        let attempt = RelayDiagnosticsExportAttempt(
            id: UUID().uuidString.lowercased(),
            incidentID: incidentID,
            retryAttempt: retryAttempt
        )
        exportLock.lock()
        guard activeExportAttemptID == nil else {
            exportLock.unlock()
            throw RelayDiagnosticsExportError.exportInProgress
        }
        activeExportAttemptID = attempt.id
        exportLock.unlock()
        recordExportLifecycle(attempt, outcome: "started")
        return attempt
    }

    func cancelSupportBundleExport(_ attempt: RelayDiagnosticsExportAttempt) {
        finishSupportBundleExport(attempt, outcome: "canceled")
    }

    func createSupportBundle(
        at destination: URL,
        attempt: RelayDiagnosticsExportAttempt
    ) throws {
        guard isActive(attempt) else {
            throw RelayDiagnosticsExportError.invalidAttempt
        }
        do {
            try createSupportBundleContents(at: destination, attempt: attempt)
            finishSupportBundleExport(attempt, outcome: "ready")
        } catch is CancellationError {
            finishSupportBundleExport(attempt, outcome: "canceled")
            throw CancellationError()
        } catch {
            finishSupportBundleExport(attempt, outcome: "failed", summary: error.localizedDescription)
            throw error
        }
    }

    private func append(_ event: RelayDiagnosticEvent) {
        do {
            try fileManager.createDirectory(
                at: journalDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try withJournalLock {
                let url = journalURL(process: event.process)
                let data = try encoder.encode(event) + Data([0x0a])
                if !fileManager.fileExists(atPath: url.path) {
                    fileManager.createFile(
                        atPath: url.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try pruneLocked()
            }
        } catch {
            logger.error("local journal write failed error=\(error.localizedDescription, privacy: .private(mask: .hash))")
        }
    }

    private func previewLocked() -> RelaySupportBundlePreview {
        (try? fileManager.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        ))
        return (try? withJournalLock {
            try pruneLocked()
            let events = loadEventsLocked()
            return RelaySupportBundlePreview(
                eventCount: events.count,
                sourceFileCount: journalURLs().count,
                redactionCount: events.reduce(0) { $0 + $1.redactionCount }
            )
        }) ?? RelaySupportBundlePreview(eventCount: 0, sourceFileCount: 0, redactionCount: 0)
    }

    private func createSupportBundleContents(
        at destination: URL,
        attempt: RelayDiagnosticsExportAttempt
    ) throws {
        try fileManager.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let journalSnapshot = try queue.sync { () -> (files: [Data], sourceFileCount: Int) in
            try withJournalLock {
                try pruneLocked()
                let urls = journalURLs()
                return (try urls.map { try Data(contentsOf: $0) }, urls.count)
            }
        }
        let events = loadEvents(from: journalSnapshot.files)
        let preview = RelaySupportBundlePreview(
            eventCount: events.count,
            sourceFileCount: journalSnapshot.sourceFileCount,
            redactionCount: events.reduce(0) { $0 + $1.redactionCount }
        )
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("Relay-Support-\(UUID().uuidString)", isDirectory: true)
        let stagingArchive = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).relay-staging-\(UUID().uuidString)"
        )
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: stagingArchive)
        }

        let readme = """
        Relay Runner local diagnostics bundle

        Included:
        - \(RelaySupportBundlePreview.included.joined(separator: "\n- "))

        Excluded:
        - \(RelaySupportBundlePreview.excluded.joined(separator: "\n- "))

        Redactions reported by writers: \(preview.redactionCount)
        Retention: \(Self.retentionDays) days and \(Self.maximumBytes) bytes across journal files.
        Apple Unified Logging, MetricKit, and native crash reports remain on this Mac and are not copied here.
        """
        try readme.write(
            to: staging.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )
        let manifest: [String: Any] = [
            "bundle_schema_version": 1,
            "created_at": Self.timestamp(now()),
            "event_count": preview.eventCount,
            "source_file_count": preview.sourceFileCount,
            "redaction_count": preview.redactionCount,
            "diagnostics_export_attempt_id": attempt.id,
            "diagnostics_export_status_at_snapshot": "started",
            "interrupted_diagnostics_export_attempt_ids": interruptedExportAttemptIDs(
                in: events,
                excluding: attempt.id
            ),
            "incident_ids": Array(Set(events.compactMap(\.incidentID))).sorted(),
            "included": RelaySupportBundlePreview.included,
            "excluded": RelaySupportBundlePreview.excluded,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        let timelineEncoder = JSONEncoder()
        timelineEncoder.outputFormatting = [.sortedKeys]
        var timeline = Data()
        for event in events {
            timeline.append(try timelineEncoder.encode(event))
            timeline.append(0x0a)
        }
        try timeline.write(to: staging.appendingPathComponent("events-v1.jsonl"), options: .atomic)

        try archiveCreator(staging, stagingArchive)
        let archiveValues = try stagingArchive.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard archiveValues.isRegularFile == true, (archiveValues.fileSize ?? 0) > 0 else {
            throw RelayDiagnosticsExportError.invalidArchive
        }
        try Self.atomicPublish(from: stagingArchive, to: destination)
    }

    private static func createArchive(staging: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", staging.path, destination.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RelayDiagnosticsExportError.archiveFailed(process.terminationStatus)
        }
    }

    private static func atomicPublish(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func loadEventsLocked() -> [RelayDiagnosticEvent] {
        loadEvents(from: journalURLs().compactMap { try? Data(contentsOf: $0) })
    }

    private func loadEvents(from files: [Data]) -> [RelayDiagnosticEvent] {
        files.flatMap { data -> [RelayDiagnosticEvent] in
            guard let contents = String(data: data, encoding: .utf8) else { return [] }
            return contents.split(separator: "\n").compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let event = try? JSONDecoder().decode(RelayDiagnosticEvent.self, from: data),
                      event.schemaVersion == RelayDiagnosticEvent.schemaVersion,
                      Self.allowedProcesses.contains(event.process),
                      Self.isIdentifier(event.phase),
                      Self.isIdentifier(event.outcome),
                      Set(event.attributes.keys).isSubset(of: Self.allowedAttributeKeys),
                      event.provider.map(Self.allowedProviders.contains) ?? true,
                      event.retryAttempt.map({ $0 > 0 }) ?? true else {
                    return nil
                }
                var redactionCount = event.redactionCount
                let appSessionID = Self.safeStoredID(event.appSessionID)
                redactionCount += appSessionID.count
                let incidentID = event.incidentID.map(Self.safeStoredID)
                redactionCount += incidentID?.count ?? 0
                let correlationID = Self.safeStoredID(event.correlationID)
                redactionCount += correlationID.count
                let summary = event.summary.map {
                    let result = RelayDiagnosticRedactor.redact($0)
                    redactionCount += result.count
                    return result.text
                }
                var attributes: [String: String] = [:]
                for (key, value) in event.attributes {
                    let result = RelayDiagnosticRedactor.redact(value, limit: 120)
                    redactionCount += result.count
                    attributes[key] = result.text
                }
                return RelayDiagnosticEvent(
                    schemaVersion: event.schemaVersion,
                    timestamp: event.timestamp,
                    appSessionID: appSessionID.value,
                    incidentID: incidentID?.value,
                    retryAttempt: event.retryAttempt,
                    correlationID: correlationID.value,
                    process: event.process,
                    phase: event.phase,
                    outcome: event.outcome,
                    provider: event.provider,
                    summary: summary,
                    attributes: attributes,
                    redactionCount: redactionCount
                )
            }
        }.sorted { $0.timestamp < $1.timestamp }
    }

    private func isActive(_ attempt: RelayDiagnosticsExportAttempt) -> Bool {
        exportLock.lock()
        defer { exportLock.unlock() }
        return activeExportAttemptID == attempt.id
    }

    private func finishSupportBundleExport(
        _ attempt: RelayDiagnosticsExportAttempt,
        outcome: String,
        summary: String? = nil
    ) {
        guard isActive(attempt) else { return }
        recordExportLifecycle(attempt, outcome: outcome, summary: summary)
        exportLock.lock()
        if activeExportAttemptID == attempt.id {
            activeExportAttemptID = nil
        }
        exportLock.unlock()
    }

    private func recordExportLifecycle(
        _ attempt: RelayDiagnosticsExportAttempt,
        outcome: String,
        summary: String? = nil
    ) {
        record(
            process: "app",
            phase: "diagnostics_export",
            outcome: outcome,
            incidentID: attempt.incidentID,
            retryAttempt: attempt.retryAttempt,
            correlationID: attempt.id,
            summary: summary
        )
    }

    private func interruptedExportAttemptIDs(
        in events: [RelayDiagnosticEvent],
        excluding currentAttemptID: String
    ) -> [String] {
        let lifecycle = events.filter { $0.phase == "diagnostics_export" }
        let started = Set(lifecycle.filter { $0.outcome == "started" }.map(\.correlationID))
        let terminal = Set(lifecycle.filter {
            ["ready", "failed", "canceled"].contains($0.outcome)
        }.map(\.correlationID))
        return started.subtracting(terminal)
            .filter { $0 != currentAttemptID }
            .sorted()
    }

    private func pruneLocked() throws {
        let urls = journalURLs().sorted {
            modificationDate($0) < modificationDate($1)
        }
        let cutoff = now().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        for url in urls where modificationDate(url) < cutoff {
            try? fileManager.removeItem(at: url)
        }
        var retained = journalURLs().sorted { modificationDate($0) < modificationDate($1) }
        var total = retained.reduce(0) { $0 + fileSize($1) }
        while total > Self.maximumBytes, let oldest = retained.first {
            let size = fileSize(oldest)
            try? fileManager.removeItem(at: oldest)
            retained.removeFirst()
            total -= size
        }
    }

    private func journalURLs() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.lastPathComponent.hasPrefix("events-v1-") && $0.pathExtension == "jsonl" } ?? []
    }

    private func journalURL(process: String) -> URL {
        journalDirectory.appendingPathComponent("events-v1-\(process)-\(getpid()).jsonl")
    }

    private func withJournalLock<T>(_ body: () throws -> T) throws -> T {
        let lock = journalDirectory.appendingPathComponent(".journal.lock", isDirectory: true)
        let deadline = Date().addingTimeInterval(Self.lockWaitSeconds)
        while true {
            do {
                try fileManager.createDirectory(
                    at: lock,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                break
            } catch {
                if let lockDate = try? lock.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate,
                   Date().timeIntervalSince(lockDate) >= Self.lockStaleSeconds {
                    let stale = journalDirectory.appendingPathComponent(
                        ".journal.lock.stale-\(getpid())-\(UUID().uuidString)",
                        isDirectory: true
                    )
                    if (try? fileManager.moveItem(at: lock, to: stale)) != nil {
                        try? fileManager.removeItem(at: stale)
                        continue
                    }
                }
                guard Date() < deadline else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        defer { try? fileManager.removeItem(at: lock) }
        return try body()
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9_]{1,64}$"#, options: .regularExpression) != nil
    }

    private static func safeID(_ value: String) -> (value: String, count: Int) {
        isSafeID(value) ? (value, 0) : ("redacted-id", 1)
    }

    private static func safeStoredID(_ value: String) -> (value: String, count: Int) {
        value == "redacted-id" ? (value, 0) : safeID(value)
    }

    private static func isSafeID(_ value: String) -> Bool {
        guard value.utf8.count <= 64 else { return false }
        let patterns = [
            #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            #"^inc-[0-9a-f]{12}$"#,
            #"^(shell|orchestrator)-[0-9]{10,}-[0-9]+$"#,
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

final class RelayMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = RelayMetricKitSubscriber()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        RelayDiagnostics.shared.record(
            process: "app",
            phase: "metrickit_delivery",
            outcome: "diagnostics_received",
            attributes: ["payload_count": String(payloads.count)]
        )
    }
}
