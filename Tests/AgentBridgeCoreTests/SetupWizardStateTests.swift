import XCTest
@testable import AgentBridgeCore

final class SetupWizardStateTests: XCTestCase {
    func testAutomaticPresentationResumesIncompleteSetupButSkipsExistingInstallations() {
        XCTAssertTrue(SetupWizardFlow.shouldPresentAutomatically(
            workspaceRootConfigured: false,
            hasStarted: false,
            hasCompleted: false
        ))
        XCTAssertFalse(SetupWizardFlow.shouldPresentAutomatically(
            workspaceRootConfigured: true,
            hasStarted: false,
            hasCompleted: false
        ))
        XCTAssertTrue(SetupWizardFlow.shouldPresentAutomatically(
            workspaceRootConfigured: true,
            hasStarted: true,
            hasCompleted: false
        ))
        XCTAssertFalse(SetupWizardFlow.shouldPresentAutomatically(
            workspaceRootConfigured: true,
            hasStarted: true,
            hasCompleted: true
        ))
    }

    func testWorkspaceIsTheOnlyRequiredNavigationAndDismissalGate() {
        XCTAssertFalse(SetupWizardFlow.canAdvance(from: .workspace, workspaceRootConfigured: false))
        XCTAssertTrue(SetupWizardFlow.canAdvance(from: .workspace, workspaceRootConfigured: true))
        XCTAssertTrue(SetupWizardFlow.canAdvance(from: .commandLine, workspaceRootConfigured: false))
        XCTAssertFalse(SetupWizardFlow.canDismiss(workspaceRootConfigured: false))
        XCTAssertTrue(SetupWizardFlow.canDismiss(workspaceRootConfigured: true))
    }

    func testResumeKeepsDraftStepAndCompletionReopensAtWelcome() {
        XCTAssertEqual(SetupWizardFlow.startingStep(savedStep: .account, workspaceRootConfigured: true), .account)
        XCTAssertEqual(SetupWizardFlow.startingStep(savedStep: .review, workspaceRootConfigured: false), .workspace)
        XCTAssertEqual(SetupWizardFlow.startingStep(savedStep: nil, workspaceRootConfigured: true), .welcome)
        XCTAssertEqual(SetupWizardFlow.reopeningStep(savedStep: .review, hasCompleted: true, workspaceRootConfigured: true), .welcome)
        XCTAssertEqual(SetupWizardFlow.reopeningStep(savedStep: .account, hasCompleted: false, workspaceRootConfigured: true), .account)
    }

    func testOptionalMissingCLIAndSignInAppearInReadinessSummary() {
        let readiness = SetupWizardReadiness(
            workspaceConfigured: true,
            commandLineAvailable: false,
            commandLineSettingSaved: true,
            subscriptionLoginConfirmed: false
        )

        XCTAssertFalse(readiness.subscriptionSetupReady)
        XCTAssertEqual(readiness.unresolvedRequirements, [.commandLine, .subscriptionLogin])
        XCTAssertEqual(SetupWizardReadiness(
            workspaceConfigured: true,
            commandLineAvailable: true,
            commandLineSettingSaved: false,
            subscriptionLoginConfirmed: true
        ).unresolvedRequirements, [.commandLine])
        XCTAssertTrue(SetupWizardReadiness(
            workspaceConfigured: true,
            commandLineAvailable: true,
            subscriptionLoginConfirmed: true
        ).subscriptionSetupReady)
    }
}
