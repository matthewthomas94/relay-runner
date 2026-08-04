import XCTest
@testable import relay_runner

final class OnboardingModelSelectionTests: XCTestCase {
    func testInitialClaudeSelectionPreservesMaxForSupportedModels() {
        for model in ["fable", "opus"] {
            let selection = OnboardingView.normalizedInitialSelection(
                provider: .claude,
                model: model,
                effort: "max"
            )

            XCTAssertEqual(selection.model, model)
            XCTAssertEqual(selection.effort, "max", "Expected max to survive for Claude \(model)")
        }
    }

    func testInitialClaudeSelectionNormalizesEffortForSelectedModel() {
        let selection = OnboardingView.normalizedInitialSelection(
            provider: .claude,
            model: "sonnet",
            effort: "xhigh"
        )

        XCTAssertEqual(selection.model, "sonnet")
        XCTAssertEqual(selection.effort, "high")
    }

    func testGuidedSetupPersistsClaudeProviderModelAndEffort() {
        var persistedProvider: GeneralConfig.AgentProvider?
        var persistedModel: String?
        var persistedEffort: String?

        OnboardingView.persistGuidedSetupSelection(
            provider: .claude,
            model: "fable",
            effort: "max",
            onSetAgentProvider: { persistedProvider = $0 },
            onSetModel: { persistedModel = $0 },
            onSetEffort: { persistedEffort = $0 }
        )

        XCTAssertEqual(persistedProvider, .claude)
        XCTAssertEqual(persistedModel, "fable")
        XCTAssertEqual(persistedEffort, "max")
    }
}
