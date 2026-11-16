import AgentBridgeCore
import Foundation

/// The three steps the Autonomous Workflow screen shows. Kept apart from the
/// view so which step a run belongs to can be tested without SwiftUI.
enum WorkflowStep: Int, CaseIterable, Identifiable {
    case goal = 1
    case review
    case run

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .goal: "Goal"
        case .review: "Review plan"
        case .run: "Run"
        }
    }

    /// Step 1 when nothing is selected or the user chose to start a new
    /// workflow; step 2 while a plan waits for approval or for its start;
    /// step 3 once it runs or has ended.
    static func current(for status: AutonomousRunStatus?, startingNewWorkflow: Bool) -> WorkflowStep {
        guard !startingNewWorkflow, let status else { return .goal }
        switch status {
        case .awaitingApproval, .approved:
            return .review
        case .running, .completed, .blocked, .failed, .cancelled, .timedOut, .interrupted:
            return .run
        }
    }
}

/// The main button of the review step.
enum WorkflowApprovalAction: Equatable {
    /// Approve the shown digest, then start it only if that approval succeeded.
    case approveAndStart
    /// Already approved (from the CLI, or the start failed after approval).
    case startApproved
    case none

    static func forStatus(_ status: AutonomousRunStatus) -> WorkflowApprovalAction {
        switch status {
        case .awaitingApproval: .approveAndStart
        case .approved: .startApproved
        default: .none
        }
    }

    /// Approval needs the review acknowledgement, and the frozen memory
    /// acknowledgement when the plan carries a memory snapshot. Approving and
    /// starting share one button, so it needs a workflow to be startable now.
    static func canApproveAndStart(
        reviewAcknowledged: Bool,
        planHasMemorySnapshot: Bool,
        memorySnapshotReviewed: Bool,
        canStartWorkflow: Bool
    ) -> Bool {
        reviewAcknowledged && canStartWorkflow && (!planHasMemorySnapshot || memorySnapshotReviewed)
    }
}

/// Which optional fields of the plan form are shown, and why Generate plan is
/// unavailable. The rules match the form's validation one to one.
enum WorkflowPlanRules {
    /// IDs of imported Mac Control presets in Control mode.
    static func controlModeExtensionIDs(_ configurations: [ActiveExtensionConfigurationSummary]) -> Set<String> {
        Set(configurations.filter { $0.macControlAccessMode == .control }.map(\.id))
    }

    /// The desktop control declaration is needed only when the Implementer has
    /// a Mac Control preset in Control mode selected.
    static func requiresDesktopDeclaration(implementerExtensionIDs: Set<String>, controlModeExtensionIDs: Set<String>) -> Bool {
        !implementerExtensionIDs.isDisjoint(with: controlModeExtensionIDs)
    }

    /// Control mode is refused for every role but the Implementer.
    static func hasControlOutsideImplementer(
        extensionIDsByRole: [AutonomousRole: Set<String>],
        controlModeExtensionIDs: Set<String>
    ) -> Bool {
        extensionIDsByRole.contains { role, selected in
            role != .implementer && !selected.isDisjoint(with: controlModeExtensionIDs)
        }
    }

    static func showsCustomVerificationFields(_ mode: AutonomousVerificationSelection.Mode) -> Bool {
        mode == .custom
    }

    static func showsMemoryDestination(saveRunSummaryToMemory: Bool) -> Bool {
        saveRunSummaryToMemory
    }

    struct Inputs: Equatable {
        var canStartWorkflow = true
        var usesSubscription = true
        var repositoryPath = ""
        var goal = ""
        var shareDiffWithReviewer = false
        var implementerAndReviewerAllowMemory = false
        var shareDependencyOutputs = false
        var allRoleProfilesAllowMemory = false
        var requiresDesktopDeclaration = false
        var desktopControlScope = ""
        var desktopControlSeparateFromGit = false
        var hasControlOutsideImplementer = false
        var saveRunSummaryToMemory = false
        var memoryDestinationIsValid = false
        var allProfilesHaveSubscriptionSignIn = false
    }

    struct Blocker: Equatable {
        let message: String
        /// The setting to change is inside Advanced settings.
        let isInAdvancedSettings: Bool
    }

    /// Every reason Generate plan is unavailable, in the order a user would fix
    /// them. Empty means the plan can be generated.
    static func blockers(_ inputs: Inputs) -> [Blocker] {
        var result: [Blocker] = []
        if !inputs.canStartWorkflow {
            result.append(Blocker(message: "Close or cancel other provider sessions and stop the terminal before planning or running an autonomous workflow.", isInAdvancedSettings: false))
        }
        if !inputs.usesSubscription {
            result.append(Blocker(message: "Autonomous workflows need official CLI subscription mode.", isInAdvancedSettings: false))
        }
        if inputs.repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(Blocker(message: "Choose a Git repository.", isInAdvancedSettings: false))
        }
        if inputs.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(Blocker(message: "Enter a goal.", isInAdvancedSettings: false))
        }
        if !inputs.allProfilesHaveSubscriptionSignIn {
            result.append(Blocker(message: "Check subscription sign-in for every role profile.", isInAdvancedSettings: false))
        }
        if !inputs.implementerAndReviewerAllowMemory {
            result.append(Blocker(message: "The selected implementer or reviewer profile has not consented to shared memory. Change that profile's consent in Account settings before planning.", isInAdvancedSettings: true))
        }
        if !inputs.shareDiffWithReviewer {
            result.append(Blocker(message: "Turn on sharing the exact implementation diff with the reviewer.", isInAdvancedSettings: false))
        }
        if inputs.shareDependencyOutputs && !inputs.allRoleProfilesAllowMemory {
            result.append(Blocker(message: "Passing task outputs to dependent roles needs every execution role profile to allow shared memory.", isInAdvancedSettings: true))
        }
        if inputs.requiresDesktopDeclaration
            && (inputs.desktopControlScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !inputs.desktopControlSeparateFromGit) {
            result.append(Blocker(message: "Describe the desktop actions in scope and confirm desktop control is separate from Git.", isInAdvancedSettings: true))
        }
        if inputs.hasControlOutsideImplementer {
            result.append(Blocker(message: "Only the Implementer role may use Mac Control Control mode. Observe mode remains available to other execution roles.", isInAdvancedSettings: true))
        }
        if inputs.saveRunSummaryToMemory && !inputs.memoryDestinationIsValid {
            result.append(Blocker(message: "Choose a memory destination profile that allows shared memory.", isInAdvancedSettings: true))
        }
        return result
    }
}

/// The three summary lines step 1 shows in place of the full settings.
enum WorkflowSettingsSummary {
    struct RoleChoice: Equatable {
        let role: AutonomousRole
        let provider: AgentProvider
        /// Display name of the bound profile, or nil when none is chosen.
        let profileName: String?
        let extensionCount: Int
    }

    static func rolesLine(_ roles: [RoleChoice], language: AppLanguage) -> String {
        func text(_ source: String) -> String { AppLocalization.display(source, language: language) }
        func binding(_ choice: RoleChoice) -> String {
            "\(text(choice.provider == .codex ? "Codex" : "Claude")) · \(choice.profileName ?? text("no profile"))"
        }
        guard let first = roles.first else { return format("Roles: %@", [text("none")], language: language) }
        var line: String
        if roles.allSatisfy({ binding($0) == binding(first) }) {
            line = format("Roles: all use %@", [binding(first)], language: language)
        } else {
            // Group the roles that share a provider and profile, in role order.
            var groups: [(binding: String, roles: [String])] = []
            for choice in roles {
                let key = binding(choice)
                let name = text(roleTitle(choice.role))
                if let index = groups.firstIndex(where: { $0.binding == key }) {
                    groups[index].roles.append(name)
                } else {
                    groups.append((key, [name]))
                }
            }
            line = format("Roles: %@", [groups.map { "\($0.roles.joined(separator: ", ")) → \($0.binding)" }.joined(separator: "; ")], language: language)
        }
        let extensions = roles.reduce(0) { $0 + $1.extensionCount }
        if extensions > 0 {
            line += " · " + format("%@ Skills / MCP selected", [String(extensions)], language: language)
        }
        return line
    }

    static func verificationLine(
        mode: AutonomousVerificationSelection.Mode,
        customPath: String,
        language: AppLanguage
    ) -> String {
        let value: String
        switch mode {
        case .projectCI:
            value = AppLocalization.display("Project .codex/ci.sh", language: language)
        case .none:
            value = AppLocalization.display("No verification command", language: language)
        case .custom:
            let path = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
            value = path.isEmpty
                ? AppLocalization.display("Custom executable not set", language: language)
                : format("Custom executable %@", [path], language: language)
        }
        return format("Verification: %@", [value], language: language)
    }

    static func limitsLine(
        concurrentAgents: Int,
        reviewRounds: Int,
        durationMinutes: Int,
        providerCalls: Int,
        language: AppLanguage
    ) -> String {
        format(
            "Limits: %@ agents at once · %@ review rounds · %@ · %@ provider calls",
            [String(concurrentAgents), String(reviewRounds), durationText(seconds: durationMinutes * 60, language: language), String(providerCalls)],
            language: language
        )
    }

    /// A run's duration limit: whole minutes when it divides evenly, else seconds.
    static func durationText(seconds: Int, language: AppLanguage) -> String {
        if seconds > 0, seconds % 60 == 0 {
            return format("%@ min", [String(seconds / 60)], language: language)
        }
        return format("%@ sec", [String(seconds)], language: language)
    }

    static func roleTitle(_ role: AutonomousRole) -> String {
        switch role {
        case .planner: "Planner"
        case .researcher: "Researcher"
        case .implementer: "Implementer"
        case .reviewer: "Reviewer"
        }
    }

    private static func format(_ source: String, _ arguments: [String], language: AppLanguage) -> String {
        String(format: AppLocalization.display(source, language: language), locale: language.locale, arguments: arguments)
    }
}

/// The order the task list shows a plan's tasks in. Display only: the plan,
/// its stored order and its digest are unchanged.
enum WorkflowTaskOrder {
    /// Each task after the tasks it depends on, keeping the stored order
    /// between tasks that could go either way. Dependencies on IDs outside the
    /// plan are ignored, and tasks left in a cycle follow in stored order.
    static func dependencyOrder(_ tasks: [AutonomousTaskDefinition]) -> [AutonomousTaskDefinition] {
        let knownIDs = Set(tasks.map(\.id))
        var placedIDs: Set<String> = []
        var placed = [Bool](repeating: false, count: tasks.count)
        var ordered: [AutonomousTaskDefinition] = []
        ordered.reserveCapacity(tasks.count)
        // Each pass places one task, so this ends after at most tasks.count passes.
        while let next = tasks.indices.first(where: { index in
            !placed[index] && tasks[index].dependencies.allSatisfy { !knownIDs.contains($0) || placedIDs.contains($0) }
        }) {
            placed[next] = true
            placedIDs.insert(tasks[next].id)
            ordered.append(tasks[next])
        }
        ordered += tasks.indices.filter { !placed[$0] }.map { tasks[$0] }
        return ordered
    }
}

/// The status line shown when a started workflow returns, by how it ended.
enum WorkflowRunOutcome {
    static func statusMessage(for status: AutonomousRunStatus) -> String {
        switch status {
        case .completed:
            "Autonomous workflow finished. Review the final diff in the existing change review."
        case .failed:
            "Autonomous workflow failed. See the run's final result and events."
        case .cancelled:
            "Autonomous workflow was cancelled. See the run's final result and events."
        case .timedOut:
            "Autonomous workflow reached its time limit. See the run's final result and events."
        case .blocked:
            "Autonomous workflow is blocked. See the run's final result and events."
        case .interrupted:
            "Autonomous workflow was interrupted. See the run's final result and events."
        case .awaitingApproval, .approved, .running:
            "Autonomous workflow ended."
        }
    }
}
