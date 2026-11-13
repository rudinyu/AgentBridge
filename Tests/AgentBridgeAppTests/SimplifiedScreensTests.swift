import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// The logic behind the three-step Autonomous Workflow screen and the one-list
/// Skills & MCP screen, tested without rendering SwiftUI.
final class WorkflowPresentationTests: XCTestCase {
    func testStepFollowsTheSelectedRunsState() {
        XCTAssertEqual(WorkflowStep.current(for: nil, startingNewWorkflow: false), .goal)
        XCTAssertEqual(WorkflowStep.current(for: .awaitingApproval, startingNewWorkflow: false), .review)
        XCTAssertEqual(WorkflowStep.current(for: .approved, startingNewWorkflow: false), .review)
        for status in [AutonomousRunStatus.running, .completed, .blocked, .failed, .cancelled, .timedOut, .interrupted] {
            XCTAssertEqual(WorkflowStep.current(for: status, startingNewWorkflow: false), .run, "\(status)")
        }
    }

    func testNewWorkflowShowsTheGoalStepWhateverRunIsSelected() {
        for status in [AutonomousRunStatus.awaitingApproval, .approved, .running, .completed] {
            XCTAssertEqual(WorkflowStep.current(for: status, startingNewWorkflow: true), .goal)
        }
    }

    func testAPlanWaitingForApprovalOffersApproveAndStart() {
        XCTAssertEqual(WorkflowApprovalAction.forStatus(.awaitingApproval), .approveAndStart)
    }

    func testAnApprovedRunThatHasNotStartedOffersStart() {
        // Approved from the CLI, or the start failed after approval.
        XCTAssertEqual(WorkflowApprovalAction.forStatus(.approved), .startApproved)
        for status in [AutonomousRunStatus.running, .completed, .failed, .cancelled, .interrupted] {
            XCTAssertEqual(WorkflowApprovalAction.forStatus(status), WorkflowApprovalAction.none)
        }
    }

    func testApproveAndStartNeedsEachAcknowledgementAndAStartableWorkflow() {
        XCTAssertTrue(WorkflowApprovalAction.canApproveAndStart(reviewAcknowledged: true, planHasMemorySnapshot: false, memorySnapshotReviewed: false, canStartWorkflow: true))
        XCTAssertFalse(WorkflowApprovalAction.canApproveAndStart(reviewAcknowledged: false, planHasMemorySnapshot: false, memorySnapshotReviewed: false, canStartWorkflow: true))
        XCTAssertFalse(WorkflowApprovalAction.canApproveAndStart(reviewAcknowledged: true, planHasMemorySnapshot: false, memorySnapshotReviewed: false, canStartWorkflow: false))
        // The frozen-memory acknowledgement matters only when the plan carries memory.
        XCTAssertFalse(WorkflowApprovalAction.canApproveAndStart(reviewAcknowledged: true, planHasMemorySnapshot: true, memorySnapshotReviewed: false, canStartWorkflow: true))
        XCTAssertTrue(WorkflowApprovalAction.canApproveAndStart(reviewAcknowledged: true, planHasMemorySnapshot: true, memorySnapshotReviewed: true, canStartWorkflow: true))
    }

    @MainActor
    func testApproveAndStartDoesNotStartWhenApprovalFails() throws {
        let model = try makeTestAppModel()
        // No run has this ID, so the service refuses the approval.
        model.approveAndStartAutonomousRun(id: UUID(), reviewedDigest: String(repeating: "a", count: 64))
        XCTAssertNotNil(model.autonomousError)
        XCTAssertFalse(model.isRunningAutonomousRun)
        XCTAssertFalse(model.hasActiveAutonomousWorkflow)
        XCTAssertNotEqual(model.autonomousStatus, model.localized("Running the approved bounded workflow…"))
    }

    @MainActor
    func testApproveAndStartDoesNotApproveWhenAWorkflowCannotStart() throws {
        let model = try makeTestAppModel()
        model.isPreparingAutonomousRun = true
        XCTAssertFalse(model.canStartAutonomousWorkflow)
        model.approveAndStartAutonomousRun(id: UUID(), reviewedDigest: String(repeating: "a", count: 64))
        XCTAssertEqual(model.autonomousError, model.localized("Close or cancel other provider sessions and stop the terminal before planning or running an autonomous workflow."))
        XCTAssertFalse(model.isRunningAutonomousRun)
        XCTAssertEqual(model.autonomousStatus, "")
    }

    func testDesktopDeclarationIsRequiredOnlyForControlModeOnTheImplementer() {
        let control: Set<String> = ["mac-control.control"]
        XCTAssertFalse(WorkflowPlanRules.requiresDesktopDeclaration(implementerExtensionIDs: [], controlModeExtensionIDs: control))
        XCTAssertFalse(WorkflowPlanRules.requiresDesktopDeclaration(implementerExtensionIDs: ["mac-control.observe", "skill"], controlModeExtensionIDs: control))
        XCTAssertTrue(WorkflowPlanRules.requiresDesktopDeclaration(implementerExtensionIDs: ["mac-control.control"], controlModeExtensionIDs: control))
        XCTAssertFalse(WorkflowPlanRules.hasControlOutsideImplementer(extensionIDsByRole: [.implementer: control], controlModeExtensionIDs: control))
        XCTAssertTrue(WorkflowPlanRules.hasControlOutsideImplementer(extensionIDsByRole: [.reviewer: control], controlModeExtensionIDs: control))
    }

    func testOptionalFieldsAppearOnlyInTheirMode() {
        XCTAssertTrue(WorkflowPlanRules.showsCustomVerificationFields(.custom))
        XCTAssertFalse(WorkflowPlanRules.showsCustomVerificationFields(.projectCI))
        XCTAssertFalse(WorkflowPlanRules.showsCustomVerificationFields(.none))
        XCTAssertTrue(WorkflowPlanRules.showsMemoryDestination(saveRunSummaryToMemory: true))
        XCTAssertFalse(WorkflowPlanRules.showsMemoryDestination(saveRunSummaryToMemory: false))
    }

    private var readyInputs: WorkflowPlanRules.Inputs {
        WorkflowPlanRules.Inputs(
            repositoryPath: "/repo",
            goal: "Fix the parser",
            shareDiffWithReviewer: true,
            implementerAndReviewerAllowMemory: true,
            allRoleProfilesAllowMemory: true,
            memoryDestinationIsValid: true,
            allProfilesHaveSubscriptionSignIn: true
        )
    }

    func testAReadyFormHasNoBlockers() {
        XCTAssertEqual(WorkflowPlanRules.blockers(readyInputs), [])
    }

    func testTheDiffSharingConsentIsRequiredAndOnTheMainStep() {
        // Off by default and required; its toggle is on step 1, not in Advanced settings.
        var inputs = readyInputs
        inputs.shareDiffWithReviewer = false
        let blockers = WorkflowPlanRules.blockers(inputs)
        XCTAssertEqual(blockers.count, 1)
        XCTAssertFalse(blockers[0].isInAdvancedSettings)
    }

    func testFreshDefaultsNeedNothingFromAdvancedSettings() {
        // The form's own defaults, with built-in profiles that allow shared memory
        // (their default) and signed in: only step-1 items block.
        let fresh = WorkflowPlanRules.Inputs(
            repositoryPath: "",
            goal: "",
            shareDiffWithReviewer: false,
            implementerAndReviewerAllowMemory: true,
            shareDependencyOutputs: false,
            allRoleProfilesAllowMemory: true,
            requiresDesktopDeclaration: false,
            hasControlOutsideImplementer: false,
            saveRunSummaryToMemory: false,
            memoryDestinationIsValid: true,
            allProfilesHaveSubscriptionSignIn: true
        )
        let blockers = WorkflowPlanRules.blockers(fresh)
        XCTAssertEqual(blockers.count, 3)
        XCTAssertFalse(blockers.contains(where: \.isInAdvancedSettings))
    }

    func testEachRuleOfTheOldFormStillBlocks() {
        var cases: [(String, WorkflowPlanRules.Inputs, Bool)] = []
        var inputs = readyInputs; inputs.canStartWorkflow = false; cases.append(("busy", inputs, false))
        inputs = readyInputs; inputs.usesSubscription = false; cases.append(("api mode", inputs, false))
        inputs = readyInputs; inputs.repositoryPath = "  "; cases.append(("repository", inputs, false))
        inputs = readyInputs; inputs.goal = "\n"; cases.append(("goal", inputs, false))
        inputs = readyInputs; inputs.allProfilesHaveSubscriptionSignIn = false; cases.append(("sign-in", inputs, false))
        inputs = readyInputs; inputs.shareDiffWithReviewer = false; cases.append(("diff sharing", inputs, false))
        inputs = readyInputs; inputs.implementerAndReviewerAllowMemory = false; cases.append(("memory consent", inputs, true))
        inputs = readyInputs; inputs.shareDependencyOutputs = true; inputs.allRoleProfilesAllowMemory = false; cases.append(("dependency sharing", inputs, true))
        inputs = readyInputs; inputs.requiresDesktopDeclaration = true; cases.append(("desktop scope", inputs, true))
        inputs = readyInputs; inputs.requiresDesktopDeclaration = true; inputs.desktopControlScope = "Click Save"; cases.append(("desktop separation", inputs, true))
        inputs = readyInputs; inputs.hasControlOutsideImplementer = true; cases.append(("control role", inputs, true))
        inputs = readyInputs; inputs.saveRunSummaryToMemory = true; inputs.memoryDestinationIsValid = false; cases.append(("destination", inputs, true))
        for (name, inputs, inAdvanced) in cases {
            let blockers = WorkflowPlanRules.blockers(inputs)
            XCTAssertEqual(blockers.count, 1, name)
            XCTAssertEqual(blockers.first?.isInAdvancedSettings, inAdvanced, name)
        }
        inputs = readyInputs
        inputs.requiresDesktopDeclaration = true
        inputs.desktopControlScope = "Click Save"
        inputs.desktopControlSeparateFromGit = true
        XCTAssertEqual(WorkflowPlanRules.blockers(inputs), [])
    }

    func testRolesSummaryReflectsTheActualRoles() {
        let same = AutonomousRole.allCases.map {
            WorkflowSettingsSummary.RoleChoice(role: $0, provider: .codex, profileName: "Work", extensionCount: 0)
        }
        XCTAssertEqual(WorkflowSettingsSummary.rolesLine(same, language: .english), "Roles: all use Codex · Work")

        let mixed = [
            WorkflowSettingsSummary.RoleChoice(role: .planner, provider: .codex, profileName: "Work", extensionCount: 0),
            WorkflowSettingsSummary.RoleChoice(role: .researcher, provider: .codex, profileName: "Work", extensionCount: 0),
            WorkflowSettingsSummary.RoleChoice(role: .implementer, provider: .codex, profileName: "Work", extensionCount: 2),
            WorkflowSettingsSummary.RoleChoice(role: .reviewer, provider: .claude, profileName: nil, extensionCount: 0)
        ]
        XCTAssertEqual(
            WorkflowSettingsSummary.rolesLine(mixed, language: .english),
            "Roles: Planner, Researcher, Implementer → Codex · Work; Reviewer → Claude · no profile · 2 Skills / MCP selected"
        )
        XCTAssertEqual(
            WorkflowSettingsSummary.rolesLine(same, language: .traditionalChinese),
            "角色：全部使用 Codex · Work"
        )
    }

    func testVerificationAndLimitsSummaries() {
        XCTAssertEqual(WorkflowSettingsSummary.verificationLine(mode: .projectCI, customPath: "", language: .english), "Verification: Project .codex/ci.sh")
        XCTAssertEqual(WorkflowSettingsSummary.verificationLine(mode: .none, customPath: "", language: .english), "Verification: No verification command")
        XCTAssertEqual(WorkflowSettingsSummary.verificationLine(mode: .custom, customPath: " ", language: .english), "Verification: Custom executable not set")
        XCTAssertEqual(WorkflowSettingsSummary.verificationLine(mode: .custom, customPath: "/usr/bin/true", language: .english), "Verification: Custom executable /usr/bin/true")
        XCTAssertEqual(
            WorkflowSettingsSummary.limitsLine(concurrentAgents: 3, reviewRounds: 2, durationMinutes: 30, providerCalls: 20, language: .english),
            "Limits: 3 agents at once · 2 review rounds · 30 min · 20 provider calls"
        )
    }
}

final class ExtensionRowPresentationTests: XCTestCase {
    func testPrimaryActionFollowsTheRowsState() {
        XCTAssertEqual(ExtensionRowState(kind: .mcp, isTested: false, isEnabled: false).primaryAction, .testConnection)
        XCTAssertEqual(ExtensionRowState(kind: .macControl, isTested: false, isEnabled: false).primaryAction, .testConnection)
        XCTAssertEqual(ExtensionRowState(kind: .mcp, isTested: true, isEnabled: false).primaryAction, .reviewAndEnable)
        // A Skill starts nothing, so it never needs a connection test.
        XCTAssertEqual(ExtensionRowState(kind: .skill, isTested: false, isEnabled: false).primaryAction, .reviewAndEnable)
        XCTAssertEqual(ExtensionRowState(kind: .skill, isTested: false, isEnabled: true).primaryAction, .disable)
        XCTAssertEqual(ExtensionRowState(kind: .mcp, isTested: true, isEnabled: true).primaryAction, .disable)
        XCTAssertEqual(ExtensionRowState(kind: .macControl, isTested: true, isEnabled: true, isControlMode: false).primaryAction, .disable)
        XCTAssertEqual(ExtensionRowState(kind: .macControl, isTested: true, isEnabled: true, isControlMode: true).primaryAction, .stopControl)
    }

    func testStatusLines() {
        XCTAssertEqual(ExtensionRowState(kind: .mcp, isTested: false, isEnabled: false).statusLine(language: .english), "Not tested")
        XCTAssertEqual(ExtensionRowState(kind: .mcp, isTested: true, isEnabled: false).statusLine(language: .english), "Tested · not enabled")
        XCTAssertEqual(ExtensionRowState(kind: .skill, isTested: false, isEnabled: false).statusLine(language: .english), "Imported · not enabled")
        XCTAssertEqual(ExtensionRowState(kind: .skill, isTested: true, isEnabled: true).statusLine(language: .english), "Enabled")
        XCTAssertEqual(ExtensionRowState(kind: .mcp, isTested: true, isEnabled: true, toolCount: 3).statusLine(language: .english), "Enabled · 3 tools")
        XCTAssertEqual(ExtensionRowState(kind: .mcp, isTested: true, isEnabled: true, toolCount: 3).statusLine(language: .traditionalChinese), "已啟用 · 3 個工具")
    }

    private func enableInputs(_ kind: ExtensionRowKind) -> ExtensionEnableRules.Inputs {
        ExtensionEnableRules.Inputs(
            kind: kind,
            executionConsent: true,
            screenCaptureConsent: true,
            reviewedConfigurationDigest: "d1",
            configurationDigest: "d1",
            testedConfigurationDigest: "d1"
        )
    }

    func testEnableNeedsTheExecutionConsentForEveryKind() {
        for kind in [ExtensionRowKind.skill, .mcp, .macControl] {
            XCTAssertTrue(ExtensionEnableRules.canEnable(enableInputs(kind)), "\(kind)")
            var inputs = enableInputs(kind)
            inputs.executionConsent = false
            XCTAssertFalse(ExtensionEnableRules.canEnable(inputs), "\(kind)")
        }
    }

    func testMCPEnableNeedsATestOfTheReviewedDigest() {
        var inputs = enableInputs(.mcp)
        inputs.testedConfigurationDigest = nil
        XCTAssertFalse(ExtensionEnableRules.canEnable(inputs))
        inputs.testedConfigurationDigest = "d0"
        XCTAssertFalse(ExtensionEnableRules.canEnable(inputs))
        inputs = enableInputs(.mcp)
        inputs.hasActiveWorkflow = true
        XCTAssertFalse(ExtensionEnableRules.canEnable(inputs))
    }

    func testMacControlKeepsItsSeparateConsents() {
        var inputs = enableInputs(.macControl)
        inputs.screenCaptureConsent = false
        XCTAssertFalse(ExtensionEnableRules.canEnable(inputs))

        inputs = enableInputs(.macControl)
        inputs.isControlMode = true
        XCTAssertFalse(ExtensionEnableRules.canEnable(inputs), "Control mode needs the input consent too.")
        inputs.inputControlConsent = true
        XCTAssertTrue(ExtensionEnableRules.canEnable(inputs))

        inputs.configurationDigest = "d2"
        XCTAssertFalse(ExtensionEnableRules.canEnable(inputs), "A review of an older digest cannot enable.")
        inputs = enableInputs(.macControl)
        inputs.canStartWorkflow = false
        XCTAssertFalse(ExtensionEnableRules.canEnable(inputs))
    }

    private func session(_ provider: AgentProvider, path: String = "/repos/app", profileID: UUID? = nil) -> SessionRecord {
        SessionRecord(provider: provider, sourceRepositoryPath: path, workspacePath: "/workspaces/\(UUID())", snapshotCommit: "abc", sourceWasDirty: false, accountProfileID: profileID)
    }

    func testScopeDefaultsToTheSelectedProjectSession() {
        let selected = session(.claude)
        let other = session(.codex)
        let sessions = [selected, other]
        XCTAssertEqual(ExtensionScopeResolver.resolve(chosenSessionID: nil, selectedSession: selected, fallback: [other], sessions: sessions)?.id, selected.id)
        // A scope chosen under Change… wins.
        XCTAssertEqual(ExtensionScopeResolver.resolve(chosenSessionID: other.id, selectedSession: selected, fallback: [], sessions: sessions)?.id, other.id)
    }

    func testALocalSessionIsNeverAScope() {
        let local = session(.local)
        let fallback = session(.codex)
        XCTAssertEqual(ExtensionScopeResolver.resolve(chosenSessionID: nil, selectedSession: local, fallback: [fallback], sessions: [local, fallback])?.id, fallback.id)
        XCTAssertNil(ExtensionScopeResolver.resolve(chosenSessionID: local.id, selectedSession: nil, fallback: [], sessions: [local]))
    }

    func testMatchingSessionsUseRepositoryProviderAndProfile() {
        let profile = UUID()
        let match = session(.codex, path: "/repos/app/", profileID: profile)
        let otherProfile = session(.codex, profileID: UUID())
        let otherProvider = session(.claude, profileID: profile)
        let defaultProfile = session(.codex)
        let found = ExtensionScopeResolver.matchingSessions([match, otherProfile, otherProvider, defaultProfile], repositoryPath: "/repos/app", provider: .codex, profileID: profile)
        XCTAssertEqual(found.map(\.id), [match.id])
        let builtIn = ExtensionScopeResolver.matchingSessions([defaultProfile], repositoryPath: "/repos/app", provider: .codex, profileID: AccountProfile.defaultID(for: .codex))
        XCTAssertEqual(builtIn.map(\.id), [defaultProfile.id])
        XCTAssertEqual(ExtensionScopeResolver.matchingSessions([match], repositoryPath: "", provider: .codex, profileID: profile), [])
    }

    func testSkillFieldsArePrefilledFromFrontMatter() {
        let url = URL(fileURLWithPath: "/skills/pdf-tools/SKILL.md")
        let draft = SkillImportDraft.prefill(fileURL: url, contents: """
        ---
        name: "PDF Tools"
        description: Fill and merge PDF forms.
        ---
        # Instructions
        """)
        XCTAssertEqual(draft.skillID, "pdf-tools")
        XCTAssertEqual(draft.name, "PDF Tools")
        XCTAssertEqual(draft.summary, "Fill and merge PDF forms.")
        XCTAssertNoThrow(try ExtensionDescriptor(id: draft.skillID, kind: .skill, name: draft.name, version: "1", summary: draft.summary))
    }

    func testSkillFieldsFallBackToTheFolderName() {
        let url = URL(fileURLWithPath: "/skills/Release Notes_v2/SKILL.md")
        for contents in [nil, "# No front matter", "---\nname: unterminated"] as [String?] {
            let draft = SkillImportDraft.prefill(fileURL: url, contents: contents)
            XCTAssertEqual(draft.name, "Release Notes_v2")
            XCTAssertEqual(draft.skillID, "release-notes-v2")
            XCTAssertEqual(draft.summary, "")
        }
    }

    func testSlugIsAlwaysAValidIDOrEmpty() {
        XCTAssertEqual(SkillImportDraft.slug("  Été / 中文 -- tools!  "), "t-tools")
        XCTAssertEqual(SkillImportDraft.slug("中文"), "")
        let long = SkillImportDraft.slug(String(repeating: "ab ", count: 100))
        XCTAssertLessThanOrEqual(long.utf8.count, 160)
        XCTAssertFalse(long.hasSuffix("-"))
        XCTAssertNoThrow(try ExtensionDescriptor(id: long, kind: .skill, name: "x", version: "1", summary: ""))
    }
}
