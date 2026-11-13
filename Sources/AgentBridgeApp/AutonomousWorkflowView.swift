import AgentBridgeCore
import SwiftUI

enum WorkflowRoleSelection: String, CaseIterable, Identifiable, Hashable {
    case planner
    case researcher
    case implementer
    case reviewer

    var id: String { rawValue }

    var coreRole: AutonomousRole {
        switch self {
        case .planner: .planner
        case .researcher: .researcher
        case .implementer: .implementer
        case .reviewer: .reviewer
        }
    }

    var title: String { WorkflowSettingsSummary.roleTitle(coreRole) }
}

/// Autonomous Workflow in three steps: write the goal, review the generated
/// plan, then follow the run. The step shown follows the selected run's state
/// (see `WorkflowStep`); the setup, review and run steps live in the
/// `AutonomousWorkflowView+*.swift` files.
struct AutonomousWorkflowView: View {
    @Bindable var model: AppModel
    var onOpenWriterSession: (UUID) -> Void

    @State var goal = ""
    @State var providers: [WorkflowRoleSelection: AgentProvider] = [
        .planner: .codex,
        .researcher: .codex,
        .implementer: .codex,
        .reviewer: .claude
    ]
    @State var profileIDs: [WorkflowRoleSelection: UUID] = [:]
    @State var selectedExtensionIDs: [WorkflowRoleSelection: Set<String>] = [:]
    @State var maxConcurrentAgents = 3
    @State var maxReviewRounds = 2
    @State var maxDurationMinutes = 30
    @State var maxProviderInvocations = 20
    @State var shareDependencyOutputs = false
    @State var shareDiffWithReviewer = false
    @State var saveRunSummaryToMemory = false
    @State var memoryDestinationProfileID: UUID?
    @State var desktopControlScope = ""
    @State var desktopControlSeparateFromGit = false
    @State var verificationMode: AutonomousVerificationSelection.Mode = .projectCI
    @State var customVerificationPath = ""
    @State var customVerificationArguments = ""
    @State var reviewAcknowledged = false
    @State var memorySnapshotReviewed = false
    @State var memorySnapshotExpanded = false
    @State var isCheckingProfiles = false
    @State var isAdvancedExpanded = false
    /// Set by New workflow: show step 1 even though a run is selected. Cleared
    /// when a new plan has been generated or another run is picked.
    @State var startingNewWorkflow = false
    @State var localError: String?

    var currentStep: WorkflowStep {
        WorkflowStep.current(for: model.selectedAutonomousRun?.status, startingNewWorkflow: startingNewWorkflow)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heading
                stepIndicator
                messages
                switch currentStep {
                case .goal:
                    goalStep
                case .review:
                    if let run = model.selectedAutonomousRun { reviewStep(run) }
                case .run:
                    if let run = model.selectedAutonomousRun { runStep(run) }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            synchronizeProfiles()
            synchronizeMemoryDestination()
        }
        .onChange(of: model.selectedAutonomousRunID) { _, _ in
            resetReviewAcknowledgements()
        }
        .onChange(of: model.isPreparingAutonomousRun) { wasPreparing, isPreparing in
            // A finished plan generation selects the new run; show its review.
            if wasPreparing && !isPreparing && model.autonomousError == nil && model.selectedAutonomousRun != nil {
                startingNewWorkflow = false
            }
        }
        .onChange(of: model.accountProfiles) { _, _ in
            synchronizeProfiles()
            synchronizeMemoryDestination()
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Autonomous Workflow")
                    .font(.title2.weight(.semibold))
                Text("Plan, review, and run a bounded multi-agent change in an isolated workspace.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if currentStep != .goal {
                Button {
                    startNewWorkflow()
                } label: {
                    Label("New workflow", systemImage: "plus")
                }
                .disabled(model.isPreparingAutonomousRun)
            }
            runMenu
        }
    }

    /// Picks an earlier run, or refreshes the list. Replaces the old run box.
    private var runMenu: some View {
        Menu {
            if model.autonomousRuns.isEmpty {
                Text("No autonomous plans yet")
            } else {
                ForEach(model.autonomousRuns) { run in
                    Button {
                        model.selectedAutonomousRunID = run.id
                        startingNewWorkflow = false
                        resetReviewAcknowledgements()
                    } label: {
                        if run.id == model.selectedAutonomousRunID && !startingNewWorkflow {
                            Label("\(model.localized(run.status.rawValue)) · \(run.plan.goal.prefix(68))", systemImage: "checkmark")
                        } else {
                            Text("\(model.localized(run.status.rawValue)) · \(run.plan.goal.prefix(68))")
                        }
                    }
                }
            }
            Divider()
            Button("Refresh") { model.refresh() }
        } label: {
            Label(model.localizedFormat("Runs (%@)", String(model.autonomousRuns.count)), systemImage: "clock.arrow.circlepath")
        }
        .fixedSize()
        .help(model.localized("Open an earlier autonomous run or refresh the list."))
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(WorkflowStep.allCases) { step in
                let isCurrent = step == currentStep
                HStack(spacing: 5) {
                    Text("\(step.rawValue)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .frame(width: 18, height: 18)
                        .background(isCurrent ? Color.accentColor : Color.secondary.opacity(0.25), in: Circle())
                        .foregroundStyle(isCurrent ? Color.white : Color.primary)
                    Text(model.localized(step.title))
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                if step != WorkflowStep.allCases.last {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let error = localError ?? model.autonomousError {
            Label(model.localized(error), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        if !model.autonomousStatus.isEmpty {
            Label(model.localized(model.autonomousStatus), systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startNewWorkflow() {
        startingNewWorkflow = true
        localError = nil
        model.autonomousError = nil
        resetReviewAcknowledgements()
    }

    func resetReviewAcknowledgements() {
        reviewAcknowledged = false
        memorySnapshotReviewed = false
        memorySnapshotExpanded = false
    }

    // MARK: Role profiles

    func selectedProvider(for role: WorkflowRoleSelection) -> AgentProvider {
        providers[role] ?? .codex
    }

    func selectedProfile(for role: WorkflowRoleSelection) -> AccountProfile? {
        let provider = selectedProvider(for: role)
        let profileID = profileIDs[role] ?? model.selectedProfileIDs[provider]
        return (model.accountProfiles[provider] ?? []).first(where: { $0.id == profileID })
    }

    var allRoleProfilesAllowMemory: Bool {
        [WorkflowRoleSelection.researcher, .implementer, .reviewer]
            .allSatisfy { role in selectedProfile(for: role)?.allowsSharedMemory == true }
    }

    var implementerAndReviewerAllowMemory: Bool {
        selectedProfile(for: .implementer)?.allowsSharedMemory == true
            && selectedProfile(for: .reviewer)?.allowsSharedMemory == true
    }

    var memoryDestinationProfiles: [AccountProfile] {
        var seen = Set<UUID>()
        return WorkflowRoleSelection.allCases.compactMap { selectedProfile(for: $0) }
            .filter { $0.allowsSharedMemory && seen.insert($0.id).inserted }
    }

    var selectedProfilesHaveSubscriptionSignIn: Bool {
        WorkflowRoleSelection.allCases.allSatisfy { role in
            guard let profile = selectedProfile(for: role) else { return false }
            return model.authStatus[profile.id]?.confirmedSubscription == true
        }
    }

    var hasControlExtensionSelected: Bool {
        WorkflowPlanRules.requiresDesktopDeclaration(
            implementerExtensionIDs: selectedExtensionIDs[.implementer, default: []],
            controlModeExtensionIDs: WorkflowPlanRules.controlModeExtensionIDs(model.extensions.activeExtensionConfigurations)
        )
    }

    var hasControlExtensionSelectedOutsideImplementer: Bool {
        WorkflowPlanRules.hasControlOutsideImplementer(
            extensionIDsByRole: Dictionary(uniqueKeysWithValues: selectedExtensionIDs.map { ($0.key.coreRole, $0.value) }),
            controlModeExtensionIDs: WorkflowPlanRules.controlModeExtensionIDs(model.extensions.activeExtensionConfigurations)
        )
    }

    var planBlockers: [WorkflowPlanRules.Blocker] {
        WorkflowPlanRules.blockers(WorkflowPlanRules.Inputs(
            canStartWorkflow: model.canStartAutonomousWorkflow,
            usesSubscription: model.settings.usageMode == .subscription,
            repositoryPath: model.repositoryPath,
            goal: goal,
            shareDiffWithReviewer: shareDiffWithReviewer,
            implementerAndReviewerAllowMemory: implementerAndReviewerAllowMemory,
            shareDependencyOutputs: shareDependencyOutputs,
            allRoleProfilesAllowMemory: allRoleProfilesAllowMemory,
            requiresDesktopDeclaration: hasControlExtensionSelected,
            desktopControlScope: desktopControlScope,
            desktopControlSeparateFromGit: desktopControlSeparateFromGit,
            hasControlOutsideImplementer: hasControlExtensionSelectedOutsideImplementer,
            saveRunSummaryToMemory: saveRunSummaryToMemory,
            memoryDestinationIsValid: memoryDestinationProfiles.contains(where: { $0.id == memoryDestinationProfileID }),
            allProfilesHaveSubscriptionSignIn: selectedProfilesHaveSubscriptionSignIn
        ))
    }

    var canGeneratePlan: Bool { planBlockers.isEmpty }

    func extensionBinding(role: WorkflowRoleSelection, id: String) -> Binding<Bool> {
        Binding(
            get: { selectedExtensionIDs[role, default: []].contains(id) },
            set: { enabled in
                var selected = selectedExtensionIDs[role, default: []]
                if enabled { selected.insert(id) } else { selected.remove(id) }
                selectedExtensionIDs[role] = selected
                reviewAcknowledged = false
            }
        )
    }

    func synchronizeProfiles() {
        for role in WorkflowRoleSelection.allCases {
            let provider = providers[role] ?? .codex
            if profileIDs[role] == nil || !(model.accountProfiles[provider] ?? []).contains(where: { $0.id == profileIDs[role] }) {
                profileIDs[role] = model.selectedProfileIDs[provider]
            }
        }
    }

    func synchronizeMemoryDestination() {
        if memoryDestinationProfileID == nil || !memoryDestinationProfiles.contains(where: { $0.id == memoryDestinationProfileID }) {
            memoryDestinationProfileID = memoryDestinationProfiles.first?.id
        }
    }

    func checkSelectedProfiles() {
        let roles = makeRoleBindings()
        guard roles.isValid else { return }
        isCheckingProfiles = true
        model.autonomousError = nil
        Task { @MainActor in
            for binding in roles.bindings {
                _ = await model.checkProfileAuthentication(provider: binding.provider, profileID: binding.accountProfileID)
            }
            isCheckingProfiles = false
        }
    }

    func makeRoleBindings() -> (bindings: [AutonomousRoleBinding], isValid: Bool) {
        var bindings: [AutonomousRoleBinding] = []
        do {
            for role in WorkflowRoleSelection.allCases {
                guard let profile = selectedProfile(for: role) else { return ([], false) }
                let ids = role == .planner ? [] : Array(selectedExtensionIDs[role, default: []]).sorted()
                bindings.append(try AutonomousRoleBinding(
                    role: role.coreRole,
                    provider: profile.provider,
                    accountProfileID: profile.id,
                    extensionIDs: ids
                ))
            }
            return (bindings, true)
        } catch {
            return ([], false)
        }
    }

    func generatePlan() {
        localError = nil
        let roles = makeRoleBindings()
        guard roles.isValid,
              let planner = roles.bindings.first(where: { $0.role == .planner }) else {
            localError = model.localized("Choose an account profile for the planner and every execution role.")
            return
        }
        do {
            let limits = try AutonomousRunLimits(
                maxConcurrentAgents: maxConcurrentAgents,
                maxReviewRounds: maxReviewRounds,
                maxDurationSeconds: maxDurationMinutes * 60,
                maxProviderInvocations: maxProviderInvocations
            )
            let verification: AutonomousVerificationSelection
            switch verificationMode {
            case .none:
                verification = .none
            case .projectCI:
                verification = .projectCI
            case .custom:
                verification = try .custom(
                    executablePath: customVerificationPath,
                    arguments: customVerificationArguments.split(whereSeparator: \.isNewline).map(String.init)
                )
            }
            let request = try AutonomousRunRequest(
                goal: goal,
                sourceRepositoryPath: model.repositoryPath,
                planner: planner,
                roleBindings: roles.bindings.filter { $0.role != .planner },
                limits: limits,
                shareOutputsWithDependencies: shareDependencyOutputs,
                shareDiffWithReviewer: shareDiffWithReviewer,
                desktopControlScope: hasControlExtensionSelected ? desktopControlScope : nil,
                desktopControlSeparateFromGit: hasControlExtensionSelected && desktopControlSeparateFromGit,
                saveRunSummaryToMemory: saveRunSummaryToMemory,
                memoryDestinationProfileID: saveRunSummaryToMemory ? memoryDestinationProfileID : nil,
                verification: verification
            )
            // Stay on step 1 while the planner works; the finished plan's
            // selection moves the screen to the review step.
            startingNewWorkflow = true
            model.selectedAutonomousRunID = nil
            model.prepareAutonomousRun(request)
        } catch {
            localError = error.localizedDescription
        }
    }

    func profileName(provider: AgentProvider, id: UUID) -> String {
        model.accountProfiles[provider]?.first(where: { $0.id == id }).map { model.displayName(of: $0) } ?? id.uuidString.lowercased()
    }

    func statusColor(_ status: AutonomousRunStatus) -> Color {
        switch status {
        case .completed: .green
        case .failed, .blocked, .timedOut: .red
        case .running: .blue
        case .awaitingApproval, .approved: .orange
        case .cancelled, .interrupted: .secondary
        }
    }

    func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.localized(title)).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
