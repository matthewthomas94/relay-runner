@testable import relay_runner
import XCTest

@MainActor
final class ProjectWorkStyleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// RR-522: each agent's work style defaults to Auto, saves as its own
    /// `[agents.<slug>]` table and loads back.
    func testEachAgentDefaultsToAutoAndSavesItsOwnWorkStyle() throws {
        let manager = ConfigManager(configDir: root)
        var config = manager.load()
        for agent in SessionAgent.allCases {
            XCTAssertNil(config.agents[agent].work_style, agent.name)
            XCTAssertEqual(config.agents[agent].workStyle, .auto, agent.name)
        }
        var toml = try String(contentsOf: manager.configPath, encoding: .utf8)
        XCTAssertFalse(toml.contains("[agents."), toml)

        config.agents[.puck].work_style = .direct
        config.agents[.george].work_style = .orchestrated
        try manager.save(config)
        toml = try String(contentsOf: manager.configPath, encoding: .utf8)
        XCTAssertTrue(toml.contains("[agents.puck]\nwork_style = \"direct\"\n"), toml)
        XCTAssertTrue(toml.contains("[agents.george]\nwork_style = \"orchestrated\"\n"), toml)
        // An agent without a choice gets no table, so a project's file still applies to it.
        XCTAssertFalse(toml.contains("[agents.isabella]"), toml)
        XCTAssertEqual(manager.load().agents, config.agents)
        XCTAssertEqual(manager.loadAgents(), config.agents)

        // `relay-work-style set` appends or rewrites one agent's table in place.
        try (toml + "\n[agents.sky]\nwork_style = \"Orchestrated\"\n[agents.isabella]\nwork_style = \"sometimes\"\n")
            .write(to: manager.configPath, atomically: true, encoding: .utf8)
        let agents = try XCTUnwrap(manager.loadAgents())
        XCTAssertEqual(agents.sky.work_style, .orchestrated)
        XCTAssertNil(agents.isabella.work_style)
        XCTAssertEqual(agents.puck.work_style, .direct)
        try "not = = toml".write(to: manager.configPath, atomically: true, encoding: .utf8)
        XCTAssertNil(manager.loadAgents())
    }

    func testAgentSettingsAreKeyedByTheAgentsSlugs() {
        XCTAssertEqual(Mirror(reflecting: AgentsConfig()).children.compactMap(\.label), SessionAgent.allCases.map(\.slug))
        XCTAssertEqual(RelayAppSettings.fields["agents"], SessionAgent.allCases.map(\.slug))
    }

    /// A save keeps an agent's style changed by voice since the app read it,
    /// unless that save changes the same agent.
    func testASaveKeepsAStyleChangedOnDiskByVoice() {
        var previous = AgentsConfig()
        previous.puck.work_style = .orchestrated
        var onDisk = previous
        onDisk.isabella.work_style = .direct
        var saving = previous
        saving.george.work_style = .auto
        let saved = AppState.agentsToSave(saving, previous: previous, onDisk: onDisk)
        XCTAssertEqual(saved.isabella.work_style, .direct)
        XCTAssertEqual(saved.george.work_style, .auto)
        XCTAssertEqual(saved.puck.work_style, .orchestrated)

        saving.isabella.work_style = .orchestrated
        XCTAssertEqual(AppState.agentsToSave(saving, previous: previous, onDisk: onDisk).isabella.work_style, .orchestrated)
    }

    func testTheThreeStylesMatchTheBridgeClassifier() {
        XCTAssertEqual(ProjectWorkStyle.allCases.map(\.rawValue), ["auto", "direct", "orchestrated"])
    }
}
