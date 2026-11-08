@testable import relay_runner
import XCTest

@MainActor
final class ProjectWorkStyleTests: XCTestCase {
    func testSessionStyleDefaultsToAutoAndPersistsTheStartMenuChoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session-work-style.json")

        let store = SessionWorkStyleStore(fileURL: file)
        XCTAssertEqual(store.style, .auto)

        store.select(.direct)
        XCTAssertEqual(store.style, .direct)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String]
        XCTAssertEqual(saved, ["work_style": "direct"])
        XCTAssertEqual(SessionWorkStyleStore(fileURL: file).style, .direct)

        // Voice or relay-work-style can change it while the Workspace is open.
        SessionWorkStyleStore.save(.orchestrated, to: file)
        store.reload()
        XCTAssertEqual(store.style, .orchestrated)

        try Data("{\"work_style\": \"sometimes\"}".utf8).write(to: file)
        XCTAssertEqual(SessionWorkStyleStore.load(from: file), .auto)
    }

    func testTheThreeStylesMatchThePythonClassifier() {
        XCTAssertEqual(ProjectWorkStyle.allCases.map(\.rawValue), ["auto", "direct", "orchestrated"])
    }
}
