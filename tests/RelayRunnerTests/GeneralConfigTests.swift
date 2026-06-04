import XCTest
@testable import relay_runner

final class GeneralConfigTests: XCTestCase {

    func testCodexModelOptionsMatchCurrentCatalog() {
        XCTAssertEqual(
            GeneralConfig.codexModelOptions,
            [
                GeneralConfig.ModelOption(label: "Default", value: "default"),
                GeneralConfig.ModelOption(label: "GPT-5.5", value: "gpt-5.5"),
                GeneralConfig.ModelOption(label: "GPT-5.4", value: "gpt-5.4"),
                GeneralConfig.ModelOption(label: "GPT-5.4-Mini", value: "gpt-5.4-mini"),
                GeneralConfig.ModelOption(label: "GPT-5.3-Codex-Spark", value: "gpt-5.3-codex-spark"),
            ]
        )
    }

    func testLegacyCodexModelNormalizesToDefault() {
        var config = GeneralConfig()
        config.provider = .codex
        config.model = "gpt-5.2-codex"

        config.normalize(providerWasExplicit: true)

        XCTAssertEqual(config.model, GeneralConfig.defaultModel)
    }

    func testSelectingProviderUpdatesDefaultCommandAndModelScope() {
        var config = GeneralConfig()
        config.provider = .codex
        config.command = "codex"
        config.model = "gpt-5.5"

        config.selectProvider(.claude)

        XCTAssertEqual(config.provider, .claude)
        XCTAssertEqual(config.command, "claude")
        XCTAssertEqual(config.model, GeneralConfig.defaultModel)
    }
}
