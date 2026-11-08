import AgentBridgeCore
import SwiftUI

private enum WorkflowRoleSelection: String, CaseIterable, Identifiable, Hashable {
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

    var title: String {
        switch self {
        case .planner: "Planner"
        case .researcher: "Researcher"
        case .implementer: "Implementer"
        case .reviewer: "Reviewer"
        }
    }
}

struct AutonomousWorkflowView: View {
    @Bindable var model: AppModel
    var onOpenWriterSession: (UUID) -> Void

    @State private var goal = ""
    @State private var providers: [WorkflowRoleSelection: AgentProvider] = [
        .planner: .codex,
        .researcher: .codex,
        .implementer: .codex,
        .reviewer: .claude
    ]
    @State private var profileIDs: [WorkflowRoleSelection: UUID] = [:]
    @State private var selectedExtensionIDs: [WorkflowRoleSelection: Set<String>] = [:]
    @State private var maxConcurrentAgents = 3
    @State private var maxReviewRounds = 2
    @State private var maxDurationMinutes = 30
    @State private var maxProviderInvocations = 20
    @State private var shareDependencyOutputs = false
    @State private var shareDiffWithReviewer = false
    @State private var saveRunSummaryToMemory = false
    @State private var memoryDestinationProfileID: UUID?
    @State private var desktopControlScope = ""
    @State private var desktopControlSeparateFromGit = false
    @State private var verificationMode: AutonomousVerificationSelection.Mode = .projectCI
    @State private var customVerificationPath = ""
    @State private var customVerificationArguments = ""
    @State private var reviewAcknowledged = false
    @State private var memorySnapshotReviewed = false
    @State private var memorySnapshotExpanded = false
    @State private var isCheckingProfiles = false
    @State private var localError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heading
                planBuilder
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
                runHistoryPicker
                if let run = model.selectedAutonomousRun {
                    runDetails(run)
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
            reviewAcknowledged = false
            memorySnapshotReviewed = false
            memorySnapshotExpanded = false
        }
        .onChange(of: model.accountProfiles) { _, _ in
            synchronizeProfiles()
            synchronizeMemoryDestination()
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Autonomous Workflow")
                .font(.title2.weight(.semibold))
            Text("Generate a bounded plan, inspect its exact task graph, permissions, memory sharing, and verification, then approve that digest before the agents start.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Planning immediately starts one real read-only provider request. Autonomous workflows use official CLI subscription sign-in only; Claude API fallback is unavailable.", systemImage: "creditcard.and.lock")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var planBuilder: some View {
        GroupBox("Generate a plan") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Git repository path", text: $model.repositoryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { model.chooseRepository() }
                        .disabled(model.hasActiveAutonomousWorkflow || model.isSwitchingTarget)
                }
                Text("Source uncommitted changes are excluded. AgentBridge plans against the repository snapshot and keeps autonomous writes in an isolated workspace.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Goal")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $goal)
                        .font(.body)
                        .frame(minHeight: 90, maxHeight: 150)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text("Keep the request concise. The stored plan will include the exact change scope and each role's task prompt.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
                Text("Role profiles")
                    .font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible(minimum: 240)), GridItem(.flexible(minimum: 240))], alignment: .leading, spacing: 10) {
                    ForEach(WorkflowRoleSelection.allCases) { role in
                        roleCard(role)
                    }
                }
                HStack {
                    Button {
                        checkSelectedProfiles()
                    } label: {
                        if isCheckingProfiles { ProgressView().controlSize(.small) }
                        else { Label("Check subscription sign-in", systemImage: "checkmark.shield") }
                    }
                    .disabled(isCheckingProfiles || !makeRoleBindings().isValid)
                    Spacer()
                    Text("Every planning and execution role is bound to this provider and profile. Global account selection is not changed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                Divider()
                if hasControlExtensionSelected {
                    desktopControlDeclaration
                }
                Text("Limits and verification")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 12) {
                    Stepper("Concurrent agents: \(maxConcurrentAgents)", value: $maxConcurrentAgents, in: 1...3)
                    Stepper("Review rounds: \(maxReviewRounds)", value: $maxReviewRounds, in: 1...3)
                }
                HStack(spacing: 12) {
                    Stepper("Duration: \(maxDurationMinutes) min", value: $maxDurationMinutes, in: 1...60)
                    Stepper("Provider calls: \(maxProviderInvocations)", value: $maxProviderInvocations, in: 1...24)
                }
                Picker("Verification", selection: $verificationMode) {
                    Text("Project .codex/ci.sh").tag(AutonomousVerificationSelection.Mode.projectCI)
                    Text("No verification command").tag(AutonomousVerificationSelection.Mode.none)
                    Text("Approved executable and argv").tag(AutonomousVerificationSelection.Mode.custom)
                }
                if verificationMode == .custom {
                    TextField("Absolute verification executable path", text: $customVerificationPath)
                        .textFieldStyle(.roundedBorder)
                    TextField("Arguments, one per line (no shell)", text: $customVerificationArguments)
                        .textFieldStyle(.roundedBorder)
                    Text("The executable and every separate argument are included in the plan digest.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
                Text("Shared memory consent")
                    .font(.subheadline.weight(.semibold))
                Toggle("Allow task outputs to pass to dependent roles", isOn: $shareDependencyOutputs)
                    .disabled(!allRoleProfilesAllowMemory && !shareDependencyOutputs)
                Text("Off by default. When enabled, every source and recipient profile on each dependency must already allow shared memory.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("Share the exact implementation diff with the reviewer", isOn: $shareDiffWithReviewer)
                    .disabled(!implementerAndReviewerAllowMemory && !shareDiffWithReviewer)
                Text("The reviewer receives the complete, unchanged diff snapshot. Both selected profiles must already allow shared memory, and this consent is required to generate a plan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !implementerAndReviewerAllowMemory {
                    Label("The selected implementer or reviewer profile has not consented to shared memory. Change that profile's consent in Account settings before planning.", systemImage: "hand.raised")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Save the final workflow summary to project memory", isOn: $saveRunSummaryToMemory)
                    .disabled(memoryDestinationProfiles.isEmpty && !saveRunSummaryToMemory)
                if saveRunSummaryToMemory {
                    Picker("Memory destination profile", selection: Binding(
                        get: { memoryDestinationProfileID ?? memoryDestinationProfiles.first?.id ?? UUID() },
                        set: { memoryDestinationProfileID = $0 }
                    )) {
                        ForEach(memoryDestinationProfiles) { profile in
                            Text("\(profile.provider.rawValue) · \(profile.name)").tag(profile.id)
                        }
                    }
                    .disabled(memoryDestinationProfiles.isEmpty)
                    Text("Only a bound profile that already allows shared memory can receive the final summary. This is off by default and part of the reviewed plan.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Generate plan") { generatePlan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canGeneratePlan)
                    if model.isPreparingAutonomousRun { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Text("This button starts the planner request now. It does not approve changes or start the implementation agents.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func roleCard(_ role: WorkflowRoleSelection) -> some View {
        let provider = selectedProvider(for: role)
        let profiles = model.accountProfiles[provider] ?? []
        let selectedProfileID = profileIDs[role] ?? model.selectedProfileIDs[provider]
        let selectedProfile = profiles.first(where: { $0.id == selectedProfileID })
        let authentication = selectedProfile.flatMap { model.authStatus[$0.id] }
        return VStack(alignment: .leading, spacing: 7) {
            Text(role.title)
                .font(.subheadline.weight(.semibold))
            Picker("Provider", selection: Binding(
                get: { providers[role] ?? .codex },
                set: { newProvider in
                    providers[role] = newProvider
                    profileIDs[role] = model.selectedProfileIDs[newProvider]
                    reviewAcknowledged = false
                }
            )) {
                Text("Codex").tag(AgentProvider.codex)
                Text("Claude").tag(AgentProvider.claude)
            }
            .pickerStyle(.segmented)
            Picker("Account profile", selection: Binding(
                get: { selectedProfileID ?? UUID() },
                set: { newID in profileIDs[role] = newID; reviewAcknowledged = false }
            )) {
                ForEach(profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .disabled(profiles.isEmpty)
            HStack(spacing: 5) {
                Image(systemName: authentication?.confirmedSubscription == true ? "checkmark.seal.fill" : "questionmark.circle")
                Text(authentication?.confirmedSubscription == true ? "Subscription sign-in confirmed" : "Subscription sign-in not checked")
                Spacer(minLength: 0)
                Text(selectedProfile?.allowsSharedMemory == true ? "Memory sharing on" : "Memory sharing off")
                    .foregroundStyle(selectedProfile?.allowsSharedMemory == true ? Color.secondary : Color.orange)
            }
            .font(.caption2)
            .foregroundStyle(authentication?.confirmedSubscription == true ? Color.secondary : Color.orange)
            if role == .planner {
                Text("Planner extensions are disabled for the planning request.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !model.extensions.activeExtensionConfigurations.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Approved Skills / MCP for this role")
                        .font(.caption2.weight(.semibold))
                    ForEach(model.extensions.activeExtensionConfigurations) { configuration in
                        Toggle(isOn: extensionBinding(role: role, id: configuration.id)) {
                            Text("\(configuration.kind.rawValue.uppercased()) · \(configuration.name)")
                                .font(.caption2)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(configuration.macControlAccessMode == .control && role != .implementer)
                    }
                    Text("The selected IDs are checked against exact project/provider/profile grants when the plan is prepared.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 8))
    }

    private var runHistoryPicker: some View {
        GroupBox("Autonomous runs") {
            HStack(spacing: 10) {
                if model.autonomousRuns.isEmpty {
                    Text("No autonomous plans yet. Generate one to start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Run", selection: Binding(
                        get: { model.selectedAutonomousRunID ?? model.autonomousRuns.first?.id ?? UUID() },
                        set: {
                            model.selectedAutonomousRunID = $0
                            reviewAcknowledged = false
                            memorySnapshotReviewed = false
                            memorySnapshotExpanded = false
                        }
                    )) {
                        ForEach(model.autonomousRuns) { run in
                        Text("\(model.localized(run.status.rawValue)) · \(run.plan.goal.prefix(68))")
                                .tag(run.id)
                        }
                    }
                    .frame(maxWidth: 460)
                    Button("Refresh") { model.refresh() }
                }
            }
        }
    }

    @ViewBuilder
    private func runDetails(_ run: AutonomousRunRecord) -> some View {
        GroupBox(model.localizedFormat("Plan review · %@", model.localized(run.status.rawValue))) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.localizedFormat("Run %@", run.id.uuidString.lowercased()))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text(model.localizedFormat("Plan SHA-256 · %@", run.planDigest))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text(model.localizedFormat("Base commit %@ · source dirty: %@", run.plan.baseCommit, run.plan.sourceWasDirty ? model.localized("yes; uncommitted changes excluded") : model.localizedYesNo(false)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.localized(run.status.rawValue))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(statusColor(run.status).opacity(0.12), in: Capsule())
                }
                Divider()
                Text("Goal")
                    .font(.caption.weight(.semibold))
                Text(run.plan.goal)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                repositoryFingerprint(run.plan)
                desktopControlSnapshot(run.plan)
                projectMemorySnapshot(run.plan)

                Text("Task graph")
                    .font(.caption.weight(.semibold))
                ForEach(run.plan.tasks) { task in
                    taskRow(task, progress: run.taskProgress.first(where: { $0.id == task.id }))
                }

                Text("Approved change scope")
                    .font(.caption.weight(.semibold))
                Text(run.plan.changeScope.title)
                    .font(.callout.weight(.semibold))
                Text(run.plan.changeScope.summary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(run.plan.changeScope.steps.enumerated()), id: \.offset) { offset, step in
                    Text("\(offset + 1). \(step)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                roleSnapshot(run.plan)
                extensionActivationSnapshot(run.plan)
                verificationSnapshot(run.plan)

                HStack(spacing: 12) {
                    metric("Concurrency", "\(run.plan.limits.maxConcurrentAgents)")
                    metric("Review rounds", "\(run.plan.limits.maxReviewRounds)")
                    metric("Duration", "\(run.plan.limits.maxDurationSeconds) sec")
                    metric("Provider calls", "\(run.providerInvocationsStarted)/\(run.plan.limits.maxProviderInvocations)")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.localizedFormat("Dependency output sharing: %@", model.localized(run.plan.shareOutputsWithDependencies ? "enabled" : "off")))
                    Text(model.localizedFormat("Exact diff sharing with reviewer: %@", model.localized(run.plan.shareDiffWithReviewer ? "approved" : "not approved")))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                approvalControls(run)
                finalResult(run)
                events(run)
            }
            .padding(.vertical, 4)
        }
    }

    private func taskRow(_ task: AutonomousTaskDefinition, progress: AutonomousTaskProgress?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.localizedFormat("%@ · %@", model.localized(task.role.rawValue.capitalized), task.title))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(model.localized(progress?.status.rawValue ?? "queued"))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(model.localizedFormat("Task ID: %@ · dependencies: %@", task.id, task.dependencies.isEmpty ? model.localized("none") : task.dependencies.joined(separator: ", ")))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(task.prompt)
                .font(.caption2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let progress, !progress.summary.isEmpty {
                Text(model.localized(progress.summary))
                    .font(.caption2)
                    .foregroundStyle(progress.status == .failed || progress.status == .blocked ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    private func roleSnapshot(_ plan: AutonomousRunPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Role and account bindings")
                .font(.caption.weight(.semibold))
                Text(model.localizedFormat("Planner · %@ · %@ · extensions disabled during planning", plan.plannerBinding.provider.rawValue, profileName(provider: plan.plannerBinding.provider, id: plan.plannerBinding.accountProfileID)))
                .font(.caption2)
            ForEach(plan.roleProfiles, id: \.binding.role) { snapshot in
                Text(model.localizedFormat("Role %@ · %@ · %@ · shared memory %@ · extension fingerprint %@", model.localized(snapshot.binding.role.rawValue.capitalized), snapshot.binding.provider.rawValue, snapshot.profile.name, model.localized(snapshot.profile.allowsSharedMemory ? "allowed" : "off"), snapshot.extensionFingerprint))
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func extensionActivationSnapshot(_ plan: AutonomousRunPlan) -> some View {
        if !plan.extensionActivations.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("Active Skills / MCP permission review")
                    .font(.caption.weight(.semibold))
                ForEach(plan.extensionActivations) { activation in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(activation.role.rawValue.capitalized) · \(activation.kind.uppercased()) · \(activation.name) · \(activation.extensionID)")
                            .font(.caption.weight(.medium))
                        Text(model.localizedFormat("Task %@ · configuration digest %@", activation.taskID, activation.configurationDigest))
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                        if let digest = activation.reviewedDigest {
                            Text(model.localizedFormat("Extension review digest %@", digest))
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let roundIndex = activation.roundIndex {
                            Text(model.localizedFormat("Review round %@", String(roundIndex)))
                                .font(.system(size: 9, design: .monospaced))
                        }
                        if let command = activation.commandPath {
                            Text(model.localizedFormat("Command: %@", command))
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if !activation.arguments.isEmpty {
                            Text(model.localizedFormat("Arguments: %@", activation.arguments.map(\.debugDescription).joined(separator: " ")))
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        ForEach(activation.entrypointPins, id: \.path) { pin in
                            Text(model.localizedFormat("Pinned entrypoint: %@ · SHA-256 %@", pin.path, pin.digest))
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let digest = activation.executableDigest {
                            Text(model.localizedFormat("Executable SHA-256: %@", digest))
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let targetBundleID = activation.targetBundleID {
                            Text(model.localizedFormat("Target app bundle ID: %@", targetBundleID))
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let accessMode = activation.accessMode {
                            Text(model.localizedFormat("Mac Control access: %@", model.localized(accessMode.capitalized)))
                                .font(.caption2)
                        }
                        if let proxyPath = activation.proxyExecutablePath {
                            Text(model.localizedFormat("AgentBridge proxy executable: %@", proxyPath))
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let proxyDigest = activation.proxyExecutableDigest {
                            Text(model.localizedFormat("Proxy SHA-256: %@", proxyDigest))
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if !activation.permissions.isEmpty {
                            Text("Permissions: \(activation.permissions.joined(separator: ", "))")
                                .font(.caption2)
                        }
                        if !activation.allowedActions.isEmpty {
                            Text("Allowed actions/tools: \(activation.allowedActions.joined(separator: ", "))")
                                .font(.caption2)
                        }
                        if !activation.targetScope.isEmpty {
                            Text("Target scope: \(activation.targetScope.joined(separator: ", "))")
                                .font(.caption2)
                        }
                        if let calls = activation.maximumToolCallsPerRun,
                           let perResponse = activation.maximumToolResponseBytes,
                           let totalResponse = activation.maximumTotalToolResponseBytes {
                            Text(model.localizedFormat("Tool limits: %@ calls, %@ bytes per result, %@ bytes total", String(calls), String(perResponse), String(totalResponse)))
                                .font(.caption2)
                        }
                        if let disclosure = activation.dataDisclosure {
                            Label(disclosure, systemImage: "eye")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func repositoryFingerprint(_ plan: AutonomousRunPlan) -> some View {
        let fingerprint = plan.sourceRepositoryFingerprint
        return VStack(alignment: .leading, spacing: 3) {
            Text("Source repository fingerprint")
                .font(.caption.weight(.semibold))
            Text("Overall SHA-256: \(fingerprint.overallDigest)")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            Text("HEAD: \(fingerprint.headCommit) · status: \(fingerprint.statusDigest)")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            Text("Tracked diff: \(fingerprint.trackedDiffDigest) · untracked paths: \(fingerprint.untrackedPathsDigest) · untracked contents: \(fingerprint.untrackedContentDigest)")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            Text("This source fingerprint is checked before execution and again after desktop control and final work. Agents work in an isolated snapshot; source repository changes are not included in that snapshot.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func desktopControlSnapshot(_ plan: AutonomousRunPlan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Desktop control scope")
                .font(.caption.weight(.semibold))
            if let scope = plan.desktopControlScope {
                Text(scope)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Separate from Git/source repository access: \(model.localized(plan.desktopControlSeparateFromGit ? "value.confirmed" : "value.notConfirmed"))")
                    .font(.caption2)
                    .foregroundStyle(plan.desktopControlSeparateFromGit ? Color.secondary : Color.orange)
            } else {
                Text("No desktop control actions are included in this plan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func projectMemorySnapshot(_ plan: AutonomousRunPlan) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Project memory consent and snapshot")
                .font(.caption.weight(.semibold))
            if let snapshot = plan.projectMemorySnapshot {
                Text("Source: \(snapshot.repositoryPath) @ \(snapshot.snapshotCommit) · revision \(snapshot.revision)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                Text("Frozen memory SHA-256: \(snapshot.digest) · truncated: \(model.localizedYesNo(snapshot.wasTruncated))")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                let receivingProfiles = plan.roleProfiles.filter { $0.profile.allowsSharedMemory }
                Text(receivingProfiles.isEmpty
                    ? model.localized("No execution role profile will receive this memory context.")
                    : model.localizedFormat("Profiles receiving this frozen context: %@", receivingProfiles.map { "\($0.binding.role.rawValue) · \($0.binding.provider.rawValue)/\($0.profile.name)" }.joined(separator: ", ")))
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Inspect exact frozen project memory", isExpanded: $memorySnapshotExpanded) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            if !snapshot.notes.isEmpty {
                                Text("Notes\n\(snapshot.notes)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            ForEach(snapshot.turns, id: \.id) { turn in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(turn.provider.rawValue) · \(turn.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2.weight(.semibold))
                                    Text("User: \(turn.userText)\nAssistant: \(turn.assistantText)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if snapshot.isEmpty {
                                Text("The frozen memory snapshot is empty.")
                                    .font(.caption2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(maxHeight: 240)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.caption2.weight(.semibold))
                Toggle("I reviewed the exact frozen memory shown above.", isOn: $memorySnapshotReviewed)
                    .font(.caption2)
                    .disabled(!memorySnapshotExpanded)
            } else {
                Text("No role profile has shared memory enabled, so no project memory is included in this run.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            let memoryDestination = plan.memoryDestinationProfileID?.uuidString.lowercased() ?? model.localized("value.unknown")
            Text("Save final summary: \(plan.saveRunSummaryToMemory ? model.localizedFormat("value.yesWithProfile %@", memoryDestination) : model.localizedYesNo(false))")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    private func verificationSnapshot(_ plan: AutonomousRunPlan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Verification")
                .font(.caption.weight(.semibold))
            Text(model.localizedFormat("Mode: %@", model.localized(plan.verification.mode.rawValue)))
                .font(.caption2)
            if let executablePath = plan.verification.executablePath {
                Text("Executable: \(executablePath)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
            if !plan.verification.arguments.isEmpty {
                Text("Arguments: \(plan.verification.arguments.map(\.debugDescription).joined(separator: " "))")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let digest = plan.verification.executableDigest {
                Text("Executable SHA-256: \(digest)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let disclosure = plan.verification.executionTrustDisclosure {
                Label(model.localized(disclosure), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if plan.verification.mode == .none {
                Label("No verification command was requested; this exact choice is part of the approved digest.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func approvalControls(_ run: AutonomousRunRecord) -> some View {
        switch run.status {
        case .awaitingApproval:
            Divider()
            Toggle("I reviewed this immutable plan, task dependencies, permissions, extension scopes, memory sharing, limits, exact verification command, and digest.", isOn: $reviewAcknowledged)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if run.plan.projectMemorySnapshot != nil {
                Toggle("I also inspected the exact frozen project memory that will be shared with consenting role profiles.", isOn: $memorySnapshotReviewed)
                    .font(.caption2)
                    .disabled(!memorySnapshotExpanded)
            }
            Text("One approval covers only this digest-bound run, including its displayed bounded repair rounds and verification. Any changed configuration or plan requires a new plan and approval.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Approve this plan") {
                    model.approveAutonomousRun(id: run.id, reviewedDigest: run.planDigest)
                    reviewAcknowledged = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!reviewAcknowledged || model.hasActiveAutonomousWorkflow
                    || (run.plan.projectMemorySnapshot != nil && !memorySnapshotReviewed))
                Button("Cancel plan", role: .destructive) {
                    model.cancelAutonomousRun(id: run.id)
                }
            }
        case .approved:
            Label("Approved for \(run.plan.limits.maxReviewRounds) bounded review rounds and the verification choice shown above.", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Start approved workflow") {
                    model.startAutonomousRun(id: run.id, reviewedDigest: run.planDigest)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStartAutonomousWorkflow)
                Button("Cancel approved plan", role: .destructive) {
                    model.cancelAutonomousRun(id: run.id)
                }
            }
        case .running:
            HStack {
                ProgressView().controlSize(.small)
                Text("Running the approved workflow. Manual provider sessions, profile changes, workspace changes, and writer actions are locked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel all agents", role: .destructive) { model.cancelAutonomousRun(id: run.id) }
            }
        case .interrupted:
            Label("This run was interrupted and will not continue automatically. Create a new plan and review its new digest.", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .completed, .blocked, .failed, .cancelled, .timedOut:
            EmptyView()
        }
    }

    @ViewBuilder
    private func finalResult(_ run: AutonomousRunRecord) -> some View {
        if let summary = run.resultSummary {
            Divider()
            Text("Final result")
                .font(.caption.weight(.semibold))
            Text(model.localized(summary))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text(model.localizedFormat("Review: %@", model.localized(run.reviewVerdict.map { $0 == .pass ? "Pass" : "Changes requested" } ?? "not completed")))
                Text(model.localizedFormat("Verification: %@", model.localized(run.verificationPassed.map { $0 ? "passed" : "failed" } ?? "not run")))
                if let digest = run.diffDigest { Text("Diff SHA-256: \(digest)").textSelection(.enabled) }
            }
            .font(.caption2.monospaced())
            if let fingerprint = run.sourceRepositoryFingerprintAfter {
                Text("Source fingerprint after workflow: \(fingerprint.overallDigest)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
            if run.plan.saveRunSummaryToMemory {
                Text("Project memory summary saved: \(model.localized(run.memorySummarySaved.map { $0 ? "value.yes" : "value.no" } ?? "value.pending"))")
                    .font(.caption2)
            }
            if let writerSessionID = run.writerSessionID {
                Button("Open final diff in Change Review") { onOpenWriterSession(writerSessionID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(run.status == .running || model.hasActiveAutonomousWorkflow)
                Text("The final diff remains isolated. Opening Change Review does not accept, apply, commit, push, or merge it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func events(_ run: AutonomousRunRecord) -> some View {
        if !run.events.isEmpty {
            DisclosureGroup(model.localizedFormat("Run events (%@)", String(run.events.count))) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(run.events.suffix(40)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.kind).font(.caption2.monospaced().weight(.semibold))
                                Spacer()
                                Text(event.occurredAt.formatted(date: .abbreviated, time: .standard))
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            Text(model.localized(event.message))
                                .font(.caption2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption.weight(.semibold))
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusColor(_ status: AutonomousRunStatus) -> Color {
        switch status {
        case .completed: .green
        case .failed, .blocked, .timedOut: .red
        case .running: .blue
        case .awaitingApproval, .approved: .orange
        case .cancelled, .interrupted: .secondary
        }
    }

    private func selectedProvider(for role: WorkflowRoleSelection) -> AgentProvider {
        providers[role] ?? .codex
    }

    private var allRoleProfilesAllowMemory: Bool {
        [WorkflowRoleSelection.researcher, .implementer, .reviewer]
            .allSatisfy { role in selectedProfile(for: role)?.allowsSharedMemory == true }
    }

    private var implementerAndReviewerAllowMemory: Bool {
        selectedProfile(for: .implementer)?.allowsSharedMemory == true
            && selectedProfile(for: .reviewer)?.allowsSharedMemory == true
    }

    private var memoryDestinationProfiles: [AccountProfile] {
        var seen = Set<UUID>()
        return WorkflowRoleSelection.allCases.compactMap { selectedProfile(for: $0) }
            .filter { $0.allowsSharedMemory && seen.insert($0.id).inserted }
    }

    private var selectedProfilesHaveSubscriptionSignIn: Bool {
        WorkflowRoleSelection.allCases.allSatisfy { role in
            guard let profile = selectedProfile(for: role) else { return false }
            return model.authStatus[profile.id]?.confirmedSubscription == true
        }
    }

    private var canGeneratePlan: Bool {
        model.canStartAutonomousWorkflow
            && model.settings.usageMode == .subscription
            && !model.repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && shareDiffWithReviewer
            && implementerAndReviewerAllowMemory
            && (!shareDependencyOutputs || allRoleProfilesAllowMemory)
            && (!hasControlExtensionSelected || (!desktopControlScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && desktopControlSeparateFromGit))
            && !hasControlExtensionSelectedOutsideImplementer
            && (!saveRunSummaryToMemory || memoryDestinationProfiles.contains(where: { $0.id == memoryDestinationProfileID }))
            && selectedProfilesHaveSubscriptionSignIn
    }

    private var hasControlExtensionSelected: Bool {
        let selected = selectedExtensionIDs[.implementer, default: []]
        return model.extensions.activeExtensionConfigurations.contains { selected.contains($0.id) && $0.macControlAccessMode == .control }
    }

    private var hasControlExtensionSelectedOutsideImplementer: Bool {
        [WorkflowRoleSelection.planner, .researcher, .reviewer].contains { role in
            let selected = selectedExtensionIDs[role, default: []]
            return model.extensions.activeExtensionConfigurations.contains { selected.contains($0.id) && $0.macControlAccessMode == .control }
        }
    }

    private var desktopControlDeclaration: some View {
        GroupBox("Desktop control declaration") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Control access is limited to the selected target app by the MCP proxy. It does not limit screenshot pixels: each screenshot contains the whole main display, may show other windows, and is sent to the selected provider.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Describe the exact desktop actions in scope", text: $desktopControlScope, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                Toggle("I confirm desktop control is separate from Git and source repository access.", isOn: $desktopControlSeparateFromGit)
                    .font(.caption)
                Text("Only the Implementer role may use Mac Control Control mode. Observe mode remains available to other execution roles.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }

    private func selectedProfile(for role: WorkflowRoleSelection) -> AccountProfile? {
        let provider = selectedProvider(for: role)
        let profileID = profileIDs[role] ?? model.selectedProfileIDs[provider]
        return (model.accountProfiles[provider] ?? []).first(where: { $0.id == profileID })
    }

    private func roleCardProfileList(role: WorkflowRoleSelection) -> [AccountProfile] {
        model.accountProfiles[selectedProvider(for: role)] ?? []
    }

    private func extensionBinding(role: WorkflowRoleSelection, id: String) -> Binding<Bool> {
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

    private func synchronizeProfiles() {
        for role in WorkflowRoleSelection.allCases {
            let provider = providers[role] ?? .codex
            if profileIDs[role] == nil || !(model.accountProfiles[provider] ?? []).contains(where: { $0.id == profileIDs[role] }) {
                profileIDs[role] = model.selectedProfileIDs[provider]
            }
        }
    }

    private func synchronizeMemoryDestination() {
        if memoryDestinationProfileID == nil || !memoryDestinationProfiles.contains(where: { $0.id == memoryDestinationProfileID }) {
            memoryDestinationProfileID = memoryDestinationProfiles.first?.id
        }
    }

    private func checkSelectedProfiles() {
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

    private func makeRoleBindings() -> (bindings: [AutonomousRoleBinding], isValid: Bool) {
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

    private func generatePlan() {
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
            model.selectedAutonomousRunID = nil
            model.prepareAutonomousRun(request)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func profileName(provider: AgentProvider, id: UUID) -> String {
        model.accountProfiles[provider]?.first(where: { $0.id == id })?.name ?? id.uuidString.lowercased()
    }
}
