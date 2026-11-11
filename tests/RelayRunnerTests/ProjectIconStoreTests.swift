import XCTest
@testable import relay_runner

final class ProjectIconStoreTests: XCTestCase {
    func testIconsDefaultThenPersistPerProject() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-icons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("project-icons.json")

        let store = ProjectIconStore(fileURL: fileURL)
        XCTAssertEqual(store.icon(for: "/tmp/alpha"), ProjectIconStore.defaultIcon)
        store.setIcon(.zap, for: "/tmp/alpha")
        XCTAssertEqual(store.icon(for: "/tmp/alpha"), .zap)
        XCTAssertEqual(store.icon(for: "/tmp/alpha/"), .zap, "The same folder, however its path is written")
        XCTAssertEqual(store.icon(for: "/tmp/beta"), ProjectIconStore.defaultIcon)

        XCTAssertEqual(ProjectIconStore(fileURL: fileURL).icon(for: "/tmp/alpha"), .zap)
    }
}
