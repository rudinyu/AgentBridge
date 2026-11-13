import AgentBridgeCore
import SwiftUI

/// Step 3: task progress while the workflow runs, then its result and events.
/// The approved plan stays available in a disclosure.
extension AutonomousWorkflowView {
    func runStep(_ run: AutonomousRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            runHeader(run)
            runStatus(run)
            Text("Task progress")
                .font(.caption.weight(.semibold))
            ForEach(run.plan.tasks) { task in
                taskRow(task, progress: run.taskProgress.first(where: { $0.id == task.id }))
            }
            HStack(spacing: 12) {
                metric("Provider calls", "\(run.providerInvocationsStarted)/\(run.plan.limits.maxProviderInvocations)")
                metric("Review rounds", "\(run.plan.limits.maxReviewRounds)")
                metric("Duration", "\(run.plan.limits.maxDurationSeconds) sec")
            }
            finalResult(run)
            events(run)
            DisclosureGroup("Approved plan details") {
                VStack(alignment: .leading, spacing: 8) {
                    planDetails(run.plan)
                    projectMemorySnapshot(run.plan)
                }
                .padding(.top, 6)
            }
            .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private func runStatus(_ run: AutonomousRunRecord) -> some View {
        switch run.status {
        case .running:
            HStack {
                ProgressView().controlSize(.small)
                Text("Running the approved workflow. Manual provider sessions, profile changes, workspace changes, and writer actions are locked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel all agents", role: .destructive) { model.cancelAutonomousRun(id: run.id) }
            }
        case .interrupted:
            Label("This run was interrupted and will not continue automatically. Create a new plan and review its new digest.", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        default:
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
                                Text(model.formattedDate(event.occurredAt, date: .abbreviated, time: .standard))
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
}
