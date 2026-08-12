import AppKit
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

final class RelayDiagnostics {
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
    private let queue = DispatchQueue(label: "relay-runner.support-diagnostics")
    private let encoder = JSONEncoder()
    private let logger = Logger(subsystem: "com.relayrunner.app", category: "startup")
    private let signpostLog = OSLog(subsystem: "com.relayrunner.app", category: "startup")

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        appSessionID: String = UUID().uuidString.lowercased()
    ) {
        self.fileManager = fileManager
        self.now = now
        self.appSessionID = appSessionID
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
        try queue.sync {
            try createSupportBundleLocked(at: destination)
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

    private func createSupportBundleLocked(at destination: URL) throws {
        try fileManager.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let snapshot = try withJournalLock { () -> ([RelayDiagnosticEvent], RelaySupportBundlePreview) in
            try pruneLocked()
            let events = loadEventsLocked()
            return (events, RelaySupportBundlePreview(
                eventCount: events.count,
                sourceFileCount: journalURLs().count,
                redactionCount: events.reduce(0) { $0 + $1.redactionCount }
            ))
        }
        let (events, preview) = snapshot
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("Relay-Support-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: staging) }

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
            "incident_ids": Array(Set(events.compactMap(\.incidentID))).sorted(),
            "included": RelaySupportBundlePreview.included,
            "excluded": RelaySupportBundlePreview.excluded,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        var timeline = Data()
        for event in events {
            timeline.append(try encoder.encode(event))
            timeline.append(0x0a)
        }
        try timeline.write(to: staging.appendingPathComponent("events-v1.jsonl"), options: .atomic)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", staging.path, destination.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func loadEventsLocked() -> [RelayDiagnosticEvent] {
        journalURLs().flatMap { url -> [RelayDiagnosticEvent] in
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
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
