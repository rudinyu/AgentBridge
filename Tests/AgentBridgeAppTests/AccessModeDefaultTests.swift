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
        model.applyAccessModeLimits()
        XCTAssertEqual(model.requestedAccessMode, .readOnly)

        model.settings.defaultProvider = .codex
        model.applyAccessModeLimits()
        XCTAssertEqual(model.requestedAccessMode, .interactiveManualApproval)
    }

    func testLocalIsolatedChangesSelectionSurvivesSettingsPersistenceAndRefresh() throws {
        let model = try makeTestAppModel()
        model.settings.defaultProvider = .local
        model.applyAccessModeLimits()
        model.setRequestedAccessMode(.isolatedChanges)

        try model.persistSettings { $0.defaultProvider = .local }
        model.applyAccessModeLimits()

        XCTAssertEqual(model.requestedAccessMode, .isolatedChanges)
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
        model.setRequestedAccessMode(.readOnly)
        model.applyAccessModeLimits()
        XCTAssertEqual(model.requestedAccessMode, .readOnly)

        model.setRequestedAccessMode(.isolatedChanges)
        model.refresh()
        XCTAssertEqual(model.requestedAccessMode, .isolatedChanges)
    }

    func testAProviderSwitchUsesTheNewSessionModeInsteadOfTheAnchorsMode() throws {
        let model = try makeTestAppModel()
        XCTAssertEqual(model.switchedSessionAccessMode(for: .claude), .interactiveManualApproval)
        XCTAssertEqual(model.switchedSessionAccessMode(for: .local), .readOnly)

        model.requestedAccessMode = .isolatedChanges
        XCTAssertEqual(model.switchedSessionAccessMode(for: .codex), .isolatedChanges)

        model.settings.usageMode = .api
        XCTAssertEqual(model.switchedSessionAccessMode(for: .claude), .readOnly)
    }

    func testAProviderSwitchIgnoresAReadOnlyLimitFromALocalDefaultProvider() throws {
        let model = try makeTestAppModel()
        model.settings.defaultProvider = .local
        model.applyAccessModeLimits()
        XCTAssertEqual(model.requestedAccessMode, .readOnly)
        XCTAssertEqual(model.switchedSessionAccessMode(for: .codex), .interactiveManualApproval)
    }

    func testAChatHandoffDefaultsToTheInteractiveTerminalWhereAllowed() {
        XCTAssertEqual(DiscussionHandoffReviewView.defaultAccessMode(for: .codex, usageMode: .subscription), .interactiveManualApproval)
        XCTAssertEqual(DiscussionHandoffReviewView.defaultAccessMode(for: .claude, usageMode: .api), .readOnly)
        XCTAssertEqual(DiscussionHandoffReviewView.defaultAccessMode(for: .local, usageMode: .subscription), .readOnly)
    }
}
