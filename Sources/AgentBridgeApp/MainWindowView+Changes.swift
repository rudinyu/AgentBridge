import AppKit
import AgentBridgeCore
import SwiftUI

extension MainWindowView {
    func changeWorkflowPanel(_ session: SessionRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox("Isolated changes · review before writing") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This session writes only inside its isolated workspace. Each change run requires an editable plan, an explicit approval, and official CLI subscription mode. The source repository is not changed by the run.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Plan title", text: Bindable(model.changes).changePlanTitle)
                        TextField("Plan summary", text: Bindable(model.changes).changePlanSummary, axis: .vertical)
                            .lineLimit(2...4)
                        Text("Plan steps · one step per line")
                            .font(.caption.weight(.semibold))
                        TextEditor(text: Bindable(model.changes).changePlanStepsText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 70, maxHeight: 130)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        HStack {
                            Button("Save plan for review") { model.changes.saveChangePlan() }
                            if let plan = session.changePlan {
                                Text("Plan digest · \(plan.reviewDigest.prefix(16))")
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                if !model.changes.selectedChangePlanDraftMatchesSaved {
                                    Label("Unsaved plan edits. Save changes before review or approval.", systemImage: "pencil.line")
                                        .font(.caption).foregroundStyle(.orange)
                                } else if model.changes.selectedChangePlanIsApproved {
                                    Label("Approved", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                                } else {
                                    Button("Approve this displayed plan") { model.changes.approveChangePlan() }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                        if session.changePlan != nil,
                           model.changes.selectedChangePlanDraftMatchesSaved,
                           !model.changes.selectedChangePlanIsApproved {
                            Text("The saved plan is pending approval. Editing and saving it again clears any earlier approval.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }

                GroupBox("Run request") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $model.prompt)
                            .font(.system(.body, design: .rounded))
                            .frame(minHeight: 70, maxHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        HStack {
                            Button("Run approved changes") { model.runApprovedChanges() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isSwitchingTarget || !model.canStartAnotherRun || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.changePlan == nil || !model.changes.selectedChangePlanDraftMatchesSaved || !model.changes.selectedChangePlanIsApproved || model.settings.usageMode != .subscription)
                            if model.selectedSessionIsRunning { Button("Cancel this session") { model.cancelSession(session.id) } }
                            Spacer()
                        }
                    }
                }

                verificationPanel(session)
                changeDiffPanel(session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func verificationPanel(_ session: SessionRecord) -> some View {
        GroupBox("Verification") {
            VStack(alignment: .leading, spacing: 8) {
                Text("The default runs the workspace’s .codex/ci.sh only after you select the button. A custom executable and its separate argv entries run only after you select the explicit approval button; no shell command string is constructed.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Run .codex/ci.sh") { model.runVerification() }
                        .disabled(!model.canStartAnotherRun || model.isSwitchingTarget || model.changes.changeDiff?.files.isEmpty != false)
                    if model.selectedSessionIsRunning { Button("Cancel verification") { model.cancelSession(session.id) } }
                    if model.changes.verifiedCurrentDiff {
                        Label("Current diff verified", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                    } else {
                        Label("Verification must pass for this exact diff", systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                    }
                }
                DisclosureGroup("Use an approved custom verifier") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Absolute executable path", text: Bindable(model.changes).customVerifierPath)
                            Button("Choose…") { model.changes.chooseCustomVerifier() }
                        }
                        Text("Arguments · one argv item per line; spaces stay inside that argument")
                            .font(.caption2).foregroundStyle(.secondary)
                        TextEditor(text: Bindable(model.changes).customVerifierArgumentsText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 45, maxHeight: 85)
                        Button("Approve and run this executable with these arguments") { model.runVerification(custom: true) }
                            .disabled(model.changes.customVerifierPath.isEmpty || !model.canStartAnotherRun || model.changes.changeDiff?.files.isEmpty != false)
                    }
                    .padding(.top, 4)
                }
                if let result = model.changes.verificationResult {
                    HStack(spacing: 10) {
                        Text("Exit: \(result.exitCode.map(String.init) ?? "not reported")")
                        Text("Duration: \(String(format: "%.3f", result.durationSeconds))s")
                        Text(result.succeeded ? "CLI reported success" : (result.skippedReason ?? (result.wasCancelled ? "Cancelled" : "Not successful")))
                    }
                    .font(.caption.monospacedDigit())
                    if !result.standardOutput.isEmpty {
                        Text("Standard output").font(.caption.weight(.semibold))
                        Text(result.standardOutput).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !result.standardError.isEmpty {
                        Text("Standard error").font(.caption.weight(.semibold))
                        Text(result.standardError).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    func changeDiffPanel(_ session: SessionRecord) -> some View {
        GroupBox("Full file diff") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(model.changes.changeDiff?.files.count ?? 0) changed files")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Refresh diff") { model.refreshSelectedEvents() }
                    Button("Export patch…") { model.changes.exportChangePatch() }
                        .disabled(model.changes.changeDiff?.files.isEmpty != false)
                    Button("Restore all", role: .destructive) {
                        model.changes.restoreAllChangeFiles()
                    }
                    .disabled(model.changes.changeDiff?.files.isEmpty != false)
                }
                if let diff = model.changes.changeDiff, !diff.files.isEmpty {
                    ForEach(diff.files, id: \.path) { file in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(file.path).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(file.status.rawValue).font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Reject / restore file", role: .destructive) { model.changes.restoreChangeFile(file.path) }
                                }
                                if file.isBinary {
                                    Text("Binary diff; file content is represented as binary.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    ScrollView([.horizontal, .vertical]) {
                                        Text(file.patch).font(.system(.caption2, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(minHeight: 90, maxHeight: 260)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No changes in the isolated workspace", systemImage: "doc.text.magnifyingglass")
                        .frame(minHeight: 90)
                }
                HStack {
                    Button("Accept this verified diff") { model.changes.acceptChanges() }
                        .disabled(!model.changes.verifiedCurrentDiff || model.changes.changeDiff?.files.isEmpty != false)
                    TextField("Local branch name", text: Bindable(model.changes).branchName)
                        .frame(maxWidth: 240)
                    Button("Apply to branch as an uncommitted worktree") { model.changes.applyChangesToBranch() }
                        .disabled(!model.changes.verifiedCurrentDiff || model.changes.changeDiff?.files.isEmpty != false || model.changes.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Applying checks the source base commit for conflicts and creates an uncommitted isolated worktree. AgentBridge never commits, pushes, or merges.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
