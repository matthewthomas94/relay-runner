import Foundation
import XCTest
@testable import relay_runner

final class ProjectNoteReferenceTests: XCTestCase {
    func testMigratedGlobalNoteUsesFilesRootWhileLegacyNoteKeepsNotesRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes")
        let cache = root.appendingPathComponent("files/cache/note-version.md")
        let legacy = notes.appendingPathComponent(".orchestrator/notes/N1.md")
        for url in [cache, legacy] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Saved transcript".utf8).write(to: url)
        }
        let personalReference = reference(path: "cache/note-version.md", artifactRef: "personal/files")
        let legacyReference = reference(path: ".orchestrator/notes/N1.md", artifactRef: "refs/heads/relay/artifacts")
        XCTAssertEqual(personalReference.materializedFileURL(repositoryPath: notes.path), cache)
        XCTAssertEqual(legacyReference.materializedFileURL(repositoryPath: notes.path), legacy)
        for ref in [personalReference, legacyReference] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: ref.materializedFileURL(repositoryPath: notes.path).path))
        }
    }

    func testProjectNoteRemainsRelativeToItsSourceRepository() {
        let reference = reference(path: ".orchestrator/notes/APP-N1.md", artifactRef: "refs/heads/relay/artifacts")
        XCTAssertEqual(reference.materializedFileURL(repositoryPath: "/tmp/source-project").path,
                       "/tmp/source-project/.orchestrator/notes/APP-N1.md")
    }

    private func reference(path: String, artifactRef: String) -> RelayProjectNoteReference {
        RelayProjectNoteReference(path: path, artifactRef: artifactRef, commit: "commit", revision: "blob",
                                  historyReference: "history", verified: true, catalogCommit: "catalog")
    }
}
