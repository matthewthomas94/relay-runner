import XCTest
@testable import relay_runner

final class RelaySkillFilesTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelaySkillFilesTests-\(UUID().uuidString)")
        for path in RelaySkillFiles.paths(home: home.path) {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "ready\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testRequiresAllFourSkillsForBothProviders() {
        let relative = RelaySkillFiles.paths(home: home.path)
            .map { String($0.dropFirst(home.path.count + 1)) }
        XCTAssertEqual(Set(relative), [
            ".claude/skills/relay-bridge/SKILL.md",
            ".claude/skills/relay-stop/SKILL.md",
            ".claude/skills/relay-dispatch/SKILL.md",
            ".claude/skills/relay-workflow/SKILL.md",
            ".codex/skills/relay-bridge/SKILL.md",
            ".codex/skills/relay-stop/SKILL.md",
            ".codex/skills/relay-dispatch/SKILL.md",
            ".codex/skills/relay-workflow/SKILL.md",
        ])
        XCTAssertTrue(RelaySkillFiles.allInstalled(home: home.path))
    }

    func testAnySingleMissingSkillFailsTheGate() throws {
        for path in RelaySkillFiles.paths(home: home.path) {
            let saved = try String(contentsOfFile: path, encoding: .utf8)
            try FileManager.default.removeItem(atPath: path)
            XCTAssertFalse(RelaySkillFiles.allInstalled(home: home.path), "missing \(path) passed")
            try saved.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
