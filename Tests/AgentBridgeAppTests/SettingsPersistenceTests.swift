import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// The App saves only the setting the user changed, on top of the latest saved
/// settings. Before, it wrote its whole in-memory copy, so a Local model set up
/// with `agentbridge local configure` while the App was open was reset to the
/// App's stale copy the next time the user changed the provider.
@MainActor
final class SettingsPersistenceTests: XCTestCase {
    private let externalLocalModel = LocalModelSettings(
        backend: .openAICompatible,
        endpoint: "http://127.0.0.1:8081/v1",
        model: "external-model",
        contextWindowTokens: 32_768,
        maxOutputTokens: 2_048
    )

    func testChangingTheProviderKeepsALocalModelTheCLISavedWhileTheAppWasOpen() throws {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        XCTAssertEqual(model.settings.defaultProvider, .codex)

        // Saved from the CLI; the App has not refreshed.
        try service.updateSettings { $0.localModel = self.externalLocalModel }
        model.selectDefaultProvider(.claude)

        let saved = try service.settings()
        XCTAssertEqual(saved.defaultProvider, .claude)
        XCTAssertEqual(saved.localModel, externalLocalModel)
        XCTAssertEqual(model.settings.localModel, externalLocalModel)
        XCTAssertNil(model.errorMessage)
    }

    func testAnUnsavedLocalModelDraftStaysInTheFormAndIsNotSavedByAnotherChange() throws {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        let saved = try service.settings().localModel
        model.settings.localModel.model = "typed-but-not-saved"

        model.selectDefaultProvider(.claude)

        XCTAssertEqual(try service.settings().localModel, saved)
        XCTAssertEqual(model.settings.localModel.model, "typed-but-not-saved")
        XCTAssertEqual(try service.settings().defaultProvider, .claude)
    }

    func testSavingTheLocalModelKeepsOtherSettingsSavedElsewhere() throws {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        try service.updateSettings {
            $0.claudeBinaryPath = "/opt/example/claude"
            $0.setModelDefaults(ProviderModelChoice(model: "gpt-external", reasoningEffort: nil), for: .codex)
        }

        model.settings.localModel = externalLocalModel
        model.saveLocalModelSettings()

        let saved = try service.settings()
        XCTAssertEqual(saved.localModel, externalLocalModel)
        XCTAssertEqual(saved.claudeBinaryPath, "/opt/example/claude")
        XCTAssertEqual(saved.modelDefaults(for: .codex).model, "gpt-external")
    }

    func testChangingTheProviderSavesOnlyCLIPathsTheUserEdited() throws {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        try service.updateSettings { $0.claudeBinaryPath = "/opt/example/claude" }
        model.codexPath = "/opt/edited/codex"

        model.selectDefaultProvider(.claude)

        let saved = try service.settings()
        XCTAssertEqual(saved.codexBinaryPath, "/opt/edited/codex")
        XCTAssertEqual(saved.claudeBinaryPath, "/opt/example/claude")
    }

    func testSavingCLIPathsKeepsModelDefaultsSavedElsewhere() throws {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        try service.updateSettings {
            $0.setModelDefaults(ProviderModelChoice(model: "gpt-external", reasoningEffort: "low"), for: .codex)
        }

        model.saveSettings()

        XCTAssertEqual(try service.settings().modelDefaults(for: .codex).model, "gpt-external")
    }
}
