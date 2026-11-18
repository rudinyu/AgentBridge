import AgentBridgeCore
import SwiftUI

/// Step 2: the generated plan, led by a short summary with the long details in
/// disclosures, then the acknowledgements and one button that approves and starts.
extension AutonomousWorkflowView {
    func reviewStep(_ run: AutonomousRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            runHeader(run)
            planSummary(run)
            Text("Task graph")
                .font(.caption.weight(.semibold))
            ForEach(WorkflowTaskOrder.dependencyOrder(run.plan.tasks)) { task in
                taskRow(task, progress: run.taskProgress.first(where: { $0.id == task.id }))
            }
            planDetails(run.plan)
            projectMemorySnapshot(run.plan)
            approvalControls(run)
        }
    }

    func runHeader(_ run: AutonomousRunRecord) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(run.plan.goal)
                    .font(.headline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
    }

    private func planSummary(_ run: AutonomousRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.plan.changeScope.title)
                .font(.callout.weight(.semibold))
            Text(run.plan.changeScope.summary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(run.plan.changeScope.steps.enumerated()), id: \.offset) { offset, step in
                Text("\(offset + 1). \(step)")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                metric("Tasks", "\(run.plan.tasks.count)")
                metric("Concurrency", "\(run.plan.limits.maxConcurrentAgents)")
                metric("Review rounds", "\(run.plan.limits.maxReviewRounds)")
                metric("Duration", WorkflowSettingsSummary.durationText(seconds: run.plan.limits.maxDurationSeconds, language: model.appLanguage))
                metric("Provider calls", "\(run.providerInvocationsStarted)/\(run.plan.limits.maxProviderInvocations)")
            }
            .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.localizedFormat("Verification: %@", model.localized(run.plan.verification.mode.rawValue)))
                Text(model.localizedFormat("Dependency output sharing: %@", model.localized(run.plan.shareOutputsWithDependencies ? "enabled" : "off")))
                Text(model.localizedFormat("Exact diff sharing with reviewer: %@", model.localized(run.plan.shareDiffWithReviewer ? "approved" : "not approved")))
                if !run.plan.extensionActivations.isEmpty {
                    Text(model.localizedFormat("Skills / MCP activations: %@", String(run.plan.extensionActivations.count)))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 8))
    }

    func taskRow(_ task: AutonomousTaskDefinition, progress: AutonomousTaskProgress?) -> some View {
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
            DisclosureGroup("Prompt") {
                Text(task.prompt)
                    .font(.caption2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2)
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

    /// The parts of the plan most people read once: accounts, extension
    /// permissions, the source fingerprint, desktop scope and verification.
    func planDetails(_ plan: AutonomousRunPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Role and account bindings") {
                roleSnapshot(plan).padding(.top, 4)
            }
            if !plan.extensionActivations.isEmpty {
                DisclosureGroup(model.localizedFormat("Active Skills / MCP permission review (%@)", String(plan.extensionActivations.count))) {
                    extensionActivationSnapshot(plan).padding(.top, 4)
                }
            }
            if plan.desktopControlScope != nil {
                desktopControlSnapshot(plan)
            }
            DisclosureGroup("Verification") {
                verificationSnapshot(plan).padding(.top, 4)
            }
            DisclosureGroup("Source repository fingerprint") {
                repositoryFingerprint(plan).padding(.top, 4)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private func roleSnapshot(_ plan: AutonomousRunPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.localizedFormat("Planner · %@ · %@ · extensions disabled during planning", plan.plannerBinding.provider.rawValue, profileName(provider: plan.plannerBinding.provider, id: plan.plannerBinding.accountProfileID)))
                .font(.caption2)
            ForEach(plan.roleProfiles, id: \.binding.role) { snapshot in
                Text(model.localizedFormat(
                    "Role %@ model · %@",
                    model.localized(snapshot.binding.role.rawValue.capitalized),
                    ModelChoicePresentation.label(model: snapshot.binding.model, reasoningEffort: snapshot.binding.reasoningEffort, language: model.appLanguage)
                ))
                .font(.caption2)
            }
            ForEach(plan.roleProfiles, id: \.binding.role) { snapshot in
                Text(model.localizedFormat("Role %@ · %@ · %@ · shared memory %@ · extension fingerprint %@", model.localized(snapshot.binding.role.rawValue.capitalized), snapshot.binding.provider.rawValue, model.displayName(of: snapshot.profile), model.localized(snapshot.profile.allowsSharedMemory ? "allowed" : "off"), snapshot.extensionFingerprint))
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.body.weight(.regular))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func extensionActivationSnapshot(_ plan: AutonomousRunPlan) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(plan.extensionActivations) { activation in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.localized(activation.role.rawValue.capitalized)) · \(activation.kind.uppercased()) · \(activation.name) · \(activation.extensionID)")
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
                .font(.body.weight(.regular))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func repositoryFingerprint(_ plan: AutonomousRunPlan) -> some View {
        let fingerprint = plan.sourceRepositoryFingerprint
        return VStack(alignment: .leading, spacing: 3) {
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
                .font(.caption2.weight(.regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    private func desktopControlSnapshot(_ plan: AutonomousRunPlan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Desktop control scope")
                .font(.caption.weight(.semibold))
            if let scope = plan.desktopControlScope {
                Text(scope)
                    .font(.caption.weight(.regular))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Separate from Git/source repository access: \(model.localized(plan.desktopControlSeparateFromGit ? "value.confirmed" : "value.notConfirmed"))")
                    .font(.caption2.weight(.regular))
                    .foregroundStyle(plan.desktopControlSeparateFromGit ? Color.secondary : Color.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    func projectMemorySnapshot(_ plan: AutonomousRunPlan) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Project memory consent and snapshot")
                .font(.caption.weight(.semibold))
            if let snapshot = plan.projectMemorySnapshot {
                Text(model.localizedFormat("Source: %@ @ %@ · revision %@", snapshot.repositoryPath, snapshot.snapshotCommit, String(snapshot.revision)))
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                Text("Frozen memory SHA-256: \(snapshot.digest) · truncated: \(model.localizedYesNo(snapshot.wasTruncated))")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                let receivingProfiles = plan.roleProfiles.filter { $0.profile.allowsSharedMemory }
                Text(receivingProfiles.isEmpty
                    ? model.localized("No execution role profile will receive this memory context.")
                    : model.localizedFormat("Profiles receiving this frozen context: %@", receivingProfiles.map { "\(model.localized($0.binding.role.rawValue.capitalized)) · \($0.binding.provider.rawValue)/\(model.displayName(of: $0.profile))" }.joined(separator: ", ")))
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
                                    Text("\(turn.provider.rawValue) · \(model.formattedDate(turn.timestamp, date: .abbreviated, time: .shortened))")
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
        .font(.body.weight(.regular))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func approvalControls(_ run: AutonomousRunRecord) -> some View {
        switch WorkflowApprovalAction.forStatus(run.status) {
        case .approveAndStart:
            Divider()
            Toggle("I reviewed this immutable plan, task dependencies, permissions, extension scopes, memory sharing, limits, exact verification command, and digest.", isOn: $reviewAcknowledged)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            // Shown only when the plan carries frozen memory; it opens once that memory has been expanded.
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
                Button("Approve and start") {
                    model.approveAndStartAutonomousRun(id: run.id, reviewedDigest: run.planDigest)
                    reviewAcknowledged = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!WorkflowApprovalAction.canApproveAndStart(
                    reviewAcknowledged: reviewAcknowledged,
                    planHasMemorySnapshot: run.plan.projectMemorySnapshot != nil,
                    memorySnapshotReviewed: memorySnapshotReviewed,
                    canStartWorkflow: model.canStartAutonomousWorkflow
                ))
                Button("Cancel plan", role: .destructive) {
                    model.cancelAutonomousRun(id: run.id)
                }
            }
            if !model.canStartAutonomousWorkflow {
                Text("Close or cancel other provider sessions and stop the terminal before planning or running an autonomous workflow.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .startApproved:
            Divider()
            Label(model.localizedFormat("Approved for %@ bounded review rounds and the verification choice shown above.", String(run.plan.limits.maxReviewRounds)), systemImage: "checkmark.seal")
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
        case .none:
            EmptyView()
        }
    }
}
