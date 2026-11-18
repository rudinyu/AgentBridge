import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

final class ModelChoicePresentationTests: XCTestCase {
    func testNothingChosenReadsCLIDefaultInBothLanguages() {
        XCTAssertEqual(ModelChoicePresentation.label(model: nil, reasoningEffort: nil, language: .english), "CLI default")
        XCTAssertEqual(ModelChoicePresentation.label(model: nil, reasoningEffort: nil, language: .traditionalChinese), "CLI 預設")
        XCTAssertEqual(ModelChoicePresentation.label(model: nil, reasoningEffort: "high", language: .traditionalChinese), "CLI 預設 · high")
        // Model names and levels are the CLI's own words and stay as they are.
        XCTAssertEqual(ModelChoicePresentation.label(model: "gpt-x", reasoningEffort: "high", language: .traditionalChinese), "gpt-x · high")
    }

    func testEffortPickerStartsWithCLIDefault() {
        XCTAssertEqual(ModelChoicePresentation.effortChoices(for: .claude), ["", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(ModelChoicePresentation.effortChoices(for: .codex).first, "")
    }

    func testBlankFieldsMeanNoChoice() {
        let start = ProviderModelChoice(model: "opus", reasoningEffort: "max")
        XCTAssertEqual(ModelChoicePresentation.choice(start, model: "  "), ProviderModelChoice(reasoningEffort: "max"))
        XCTAssertEqual(ModelChoicePresentation.choice(start, effort: ""), ProviderModelChoice(model: "opus"))
        XCTAssertEqual(ModelChoicePresentation.choice(.cliDefault, model: "sonnet").model, "sonnet")
    }

    func testCoreValidationMessagesAreTranslated() {
        let message = "Reasoning effort ultra is not available for claude. Choose one of: low, medium, high, xhigh, max."
        XCTAssertEqual(
            AppLocalization.display(message, language: .traditionalChinese),
            "推理強度 ultra 不適用於 claude。請從以下選擇：low, medium, high, xhigh, max。"
        )
        XCTAssertEqual(
            AppLocalization.display("CLI exit code 1. The CLI reported: model not found", language: .traditionalChinese),
            "CLI 結束代碼 1。CLI 回報：model not found"
        )
    }
}
