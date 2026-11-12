import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// New sessions default to the native interactive terminal, within what the
/// provider and usage mode allow.
@MainActor
final class AccessModeDefaultTests: XCTestCase {
    func testNewSessionsDefaultToTheInteractiveTerminal() throws {
        let model = try makeTestAppModel()
        XCTAssertEqual(model.settings.defaultProvider, .codex)
        XCTAssertEqual(model.requestedAccessMode, .interactiveManualApproval)
    }

    func testALocalModelLimitsItToReadOnlyUntilAnotherProviderIsChosen() throws {
        let model = try makeTestAppModel()
        model.settings.defaultProvider = .local
        model.applyAccessModeLimits()
        XCTAssertEqual(model.requestedAccessMode, .readOnly)

        model.settings.defaultProvider = .codex
        model.applyAccessModeLimits()
        XCTAssertEqual(model.requestedAccessMode, .interactiveManualApproval)
    }

    func testClaudeAPIModeLimitsItToReadOnlyUntilSubscriptionModeIsBack() throws {
        let model = try makeTestAppModel()
        model.settings.defaultProvider = .claude
        model.settings.usageMode = .api
        model.applyAccessModeLimits()
        XCTAssertEqual(model.requestedAccessMode, .readOnly)

        model.settings.usageMode = .subscription
        model.applyAccessModeLimits()
        XCTAssertEqual(model.requestedAccessMode, .interactiveManualApproval)
    }

    func testAModeTheUserChoseIsKept() throws {
        let model = try makeTestAppModel()
        model.requestedAccessMode = .readOnly
        model.applyAccessModeLimits()
        XCTAssertEqual(model.requestedAccessMode, .readOnly)

        model.requestedAccessMode = .isolatedChanges
        model.refresh()
        XCTAssertEqual(model.requestedAccessMode, .isolatedChanges)
    }
}
