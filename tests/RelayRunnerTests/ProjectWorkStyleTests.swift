@testable import relay_runner
import XCTest

final class ProjectWorkStyleTests: XCTestCase {
    func testWorkspaceChoiceBeatsTheProjectFileWhichBeatsAuto() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let styles = root.appendingPathComponent("work-styles.json")

        XCTAssertEqual(ProjectWorkStyleStore.style(for: project.path, fileURL: styles), .auto)
        try "work_style = \"orchestrated\"\n".write(
            to: project.appendingPathComponent(".relay-runner.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectWorkStyleStore.style(for: project.path, fileURL: styles), .orchestrated)

        ProjectWorkStyleStore.setStyle(.direct, for: project.path, fileURL: styles)
        XCTAssertEqual(ProjectWorkStyleStore.style(for: project.path, fileURL: styles), .direct)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: styles)) as? [String: String]
        XCTAssertEqual(saved?[ProjectWorkStyleStore.key(for: project.path)], "direct")
    }

    func testTheThreeStylesMatchThePythonClassifier() {
        XCTAssertEqual(ProjectWorkStyle.allCases.map(\.rawValue), ["auto", "direct", "orchestrated"])
    }
}
