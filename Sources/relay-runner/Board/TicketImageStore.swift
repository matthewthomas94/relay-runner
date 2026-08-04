import Foundation
import UniformTypeIdentifiers

enum TicketImageStore {
    enum IngestError: LocalizedError {
        case missingFile(String)
        case unsupportedFile(String)

        var errorDescription: String? {
            switch self {
            case .missingFile(let path):
                return "Image attachment was not found at \(path)."
            case .unsupportedFile(let path):
                return "\(path) is not a supported image file."
            }
        }
    }

    static func ingest(
        _ sourceURLs: [URL],
        into ticket: Ticket,
        in project: ProjectResolver.LinkedProject,
        fileManager: FileManager = .default
    ) throws -> Ticket {
        guard !sourceURLs.isEmpty else { return ticket }

        let attachmentDirectory = ProjectResolver.ticketsDirectory(in: project)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(ticket.id, isDirectory: true)
        try fileManager.createDirectory(
            at: attachmentDirectory,
            withIntermediateDirectories: true
        )

        var relativePaths: [String] = []
        for sourceURL in sourceURLs {
            let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
            guard fileManager.fileExists(atPath: source.path),
                  fileManager.isReadableFile(atPath: source.path),
                  (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw IngestError.missingFile(source.path)
            }
            let pathExtension = source.pathExtension.lowercased()
            guard !pathExtension.isEmpty,
                  let contentType = UTType(filenameExtension: pathExtension),
                  contentType.conforms(to: .image) else {
                throw IngestError.unsupportedFile(source.path)
            }

            let baseName = sanitizedBaseName(
                source.deletingPathExtension().lastPathComponent
            )
            let destination = availableDestination(
                for: source,
                baseName: baseName,
                pathExtension: pathExtension,
                in: attachmentDirectory,
                fileManager: fileManager
            )
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: source, to: destination)
            }
            relativePaths.append(
                "attachments/\(ticket.id)/\(destination.lastPathComponent)"
            )
        }

        let body = TicketParser.appendingImageAttachments(
            in: ticket.body,
            paths: relativePaths
        )
        return Ticket(
            id: ticket.id,
            title: ticket.title,
            status: ticket.status,
            priority: ticket.priority,
            executionMode: ticket.executionMode,
            dependsOn: ticket.dependsOn,
            runId: ticket.runId,
            canceled: ticket.canceled,
            workerModel: ticket.workerModel,
            workerEffort: ticket.workerEffort,
            workerSizingRationale: ticket.workerSizingRationale,
            workerProviderNotes: ticket.workerProviderNotes,
            verificationBlocker: ticket.verificationBlocker,
            verificationResume: ticket.verificationResume,
            draft: ticket.draft,
            order: ticket.order,
            modifiedAt: ticket.modifiedAt,
            description: ticket.description,
            body: body
        )
    }

    private static func sanitizedBaseName(_ value: String) -> String {
        let mapped = value.map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "image" : collapsed
    }

    private static func availableDestination(
        for source: URL,
        baseName: String,
        pathExtension: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
            let candidate = directory
                .appendingPathComponent(name)
                .appendingPathExtension(pathExtension)
            guard fileManager.fileExists(atPath: candidate.path) else {
                return candidate
            }
            if fileManager.contentsEqual(atPath: source.path, andPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}
