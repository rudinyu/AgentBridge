import AppKit
import AgentBridgeCore
import SwiftUI

extension MainWindowView {
    func changeWorkflowPanel(_ session: SessionRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox("Isolated changes · review before writing") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.provider == .local
                            ? "This session writes only in its isolated workspace. Local receives the approved plan, your request, and files you select; it has no tools. Review and verify every result."
                            : "This session writes only inside its isolated workspace. Each change run requires an editable plan, an explicit approval, and official CLI subscription mode. The source repository is not changed by the run.")
                            .font(.caption).foregroundStyle(.secondary)
                        changePlanDraftRequest(session)
                        Group {
                            TextField("Plan title", text: Bindable(model.changes).changePlanTitle)
                            TextField("Plan summary", text: Bindable(model.changes).changePlanSummary, axis: .vertical)
                                .lineLimit(2...4)
                            Text("Plan steps · one step per line")
                                .font(.caption.weight(.semibold))
                            TextEditor(text: Bindable(model.changes).changePlanStepsText)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 70, maxHeight: 130)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        }
                        // The draft fills these fields, so they wait until it is done.
                        .disabled(model.changes.isDraftingSelectedPlan)
                        if session.provider != .local {
                            Toggle("Include shared memory in the change run", isOn: Bindable(model.changes).changePlanIncludesSharedMemory)
                                .font(.caption)
                            Text("Off by default. Earlier runs write shared memory, and its folder can be synced, so a run that edits files sees it only when you include it. Approval covers the memory as it is then; if it changes, approve again.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                                    Label(model.localized("value.approved"), systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
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

                if session.provider == .local {
                    localChangeInputPanel(session)
                } else {
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
                }

                verificationPanel(session)
                if session.provider == .local, let result = model.changes.localChangeResult {
                    GroupBox("Local model change summary") {
                        Text(result.summary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                changeDiffPanel(session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Asks the model for a plan that fills the fields below; saving stays the user's step.
    func changePlanDraftRequest(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What should change?", text: Bindable(model.changes).changeRequestText, axis: .vertical)
                .lineLimit(1...3)
                .disabled(model.changes.isDraftingSelectedPlan)
            HStack {
                Button("Draft plan") { model.changes.requestChangePlanDraft() }
                    .disabled(model.isSwitchingTarget || !model.canStartAnotherRun || model.changes.changeRequestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (session.provider != .local && model.settings.usageMode != .subscription))
                if model.changes.isDraftingSelectedPlan {
                    ProgressView().controlSize(.small)
                    Text("Drafting…").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel drafting") { model.cancelSession(session.id) }
                }
                Text("Sends one real read-only request to this session's provider. The draft is not saved, approved or run.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert(
            model.localized("Replace the plan fields with the draft?"),
            isPresented: Bindable(model.changes).confirmReplacingPlanFields
        ) {
            Button(model.localized("Replace"), role: .destructive) { model.changes.confirmReplacingPlanFieldsWithDraft() }
            Button(model.localized("Cancel"), role: .cancel) { model.changes.cancelReplacingPlanFields() }
        } message: {
            Text(model.localized("The title, summary and steps already have text. The draft replaces them; nothing is saved until you save the plan."))
        }
    }

    func localChangeInputPanel(_ session: SessionRecord) -> some View {
        GroupBox("Selected files for Local model") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose regular UTF-8 workspace files to send in full. Tracked and non-ignored untracked paths are listed; no files are sent until you select them.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Search workspace files", text: Bindable(model.changes).localFileSearchText)
                if model.changes.isLoadingLocalFileCandidates {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading workspace files…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let error = model.changes.localFileCandidatesError {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.localized(error)).font(.caption).foregroundStyle(.orange)
                        Button("Retry file list") { model.changes.reloadLocalFileCandidates() }
                            .font(.caption)
                            .disabled(model.selectedSessionIsRunning)
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.changes.filteredLocalFileCandidates) { candidate in
                            Toggle(isOn: Binding(
                                get: { model.changes.selectedLocalPaths.contains(candidate.path) },
                                set: { selected in
                                    if selected { model.changes.selectedLocalPaths.insert(candidate.path) }
                                    else { model.changes.selectedLocalPaths.remove(candidate.path) }
                                }
                            )) {
                                HStack {
                                    Text(candidate.path).font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Text(candidate.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? model.localized("Unavailable"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!candidate.isSelectable || model.selectedSessionIsRunning)
                        }
                    }
                }
                .frame(minHeight: 80, maxHeight: 180)
                Text("New file paths · one relative path per line")
                    .font(.caption.weight(.semibold))
                TextEditor(text: Bindable(model.changes).localNewFilePathsText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 38, maxHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                if let error = model.changes.localChangePreviewError {
                    Text(model.localized(error)).font(.caption).foregroundStyle(.orange)
                } else if model.changes.localChangePreview == nil {
                    Text("Approve the current plan and select files to preview the Local input budget.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let preview = model.changes.localChangePreview {
                    Text(model.localizedFormat("Input: %@ / %@ bytes", String(preview.totalInputBytes), String(preview.budgetBytes)))
                        .font(.caption.monospacedDigit())
                    if preview.overBudgetBytes > 0 {
                        Text(model.localizedFormat("Over budget by %@ bytes", String(preview.overBudgetBytes)))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                TextEditor(text: $model.prompt)
                    .font(.system(.body, design: .rounded))
                    .frame(minHeight: 70, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .onChange(of: model.prompt) { _, _ in model.changes.refreshLocalPreviews() }
                HStack {
                    Button("Generate changes with Local model") { model.runApprovedChanges() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSwitchingTarget || !model.canStartAnotherRun || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.changes.selectedLocalPaths.isEmpty && model.changes.localNewFilePaths.isEmpty) || !model.changes.selectedChangePlanDraftMatchesSaved || !model.changes.selectedChangePlanIsApproved || model.changes.localChangePreview?.fitsBudget != true)
                    if model.selectedSessionIsRunning { Button("Cancel") { model.cancelSession(session.id) } }
                    if model.changes.isLoadingLocalChangePreview { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }
        }
        .onChange(of: model.changes.selectedLocalPaths) { _, _ in model.changes.refreshLocalPreviews() }
        .onChange(of: model.changes.localNewFilePathsText) { _, _ in model.changes.refreshLocalPreviews() }
        .onChange(of: model.changes.localFixNote) { _, _ in model.changes.refreshLocalPreviews() }
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
                        Text("Exit: \(result.exitCode.map(String.init) ?? model.localized("value.notReported"))")
                        Text("Duration: \(String(format: "%.3f", result.durationSeconds))s")
                        Text(model.localized(result.succeeded ? "CLI reported success" : (result.skippedReason ?? (result.wasCancelled ? "Cancelled" : "Not successful"))))
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
                    if session.provider == .local, !result.succeeded, !result.wasCancelled, result.skippedReason == nil {
                        TextField("Optional note for the Local fix", text: Bindable(model.changes).localFixNote, axis: .vertical)
                            .lineLimit(1...3)
                        Button("Fix with Local model") { model.fixLocalChanges() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isSwitchingTarget || !model.canStartAnotherRun || !model.changes.selectedChangePlanIsApproved || model.changes.localFixPreview?.fitsBudget != true)
                        if model.changes.isLoadingLocalFixPreview {
                            ProgressView().controlSize(.small)
                        }
                        if let error = model.changes.localFixPreviewError {
                            Text(model.localized(error)).font(.caption).foregroundStyle(.orange)
                        } else if let preview = model.changes.localFixPreview {
                            Text(model.localizedFormat("Input: %@ / %@ bytes", String(preview.totalInputBytes), String(preview.budgetBytes)))
                                .font(.caption.monospacedDigit())
                            if preview.overBudgetBytes > 0 {
                                Text(model.localizedFormat("Over budget by %@ bytes", String(preview.overBudgetBytes)))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Text("Approve the current plan, choose any additional files above, then review and verify the result again.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !result.succeeded, !result.wasCancelled, result.skippedReason == nil, model.localHelper.allows(.explainFailure) {
                        failureExplanation(session, result: result)
                    }
                }
            }
        }
    }

    /// The local model's explanation of a failed verification, shown here and never saved.
    func failureExplanation(_ session: SessionRecord, result: VerificationResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            LocalHelperRunButton(model: model, task: .explainFailure, title: "Explain this failure") {
                model.localHelper.explainFailure(session: session, result: result)
            }
            LocalHelperPreviewDisclosure(model: model, task: .explainFailure, session: session)
            LocalHelperNotes(model: model, task: .explainFailure)
            if let explanation = model.localHelper.explanation(for: session, result: result) {
                Text(model.localized("The local model's explanation. It may be wrong, and it is not saved."))
                    .font(.caption.weight(.semibold))
                Text(explanation)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                Button(model.localized("Use as change request")) { model.localHelper.useExplanationAsChangeRequest() }
                    .help(model.localized("Copies the explanation into the change request field used by Draft plan. Nothing is sent."))
            }
        }
        .alert(
            model.localized("Replace the change request with the explanation?"),
            isPresented: Bindable(model.localHelper).confirmReplacingChangeRequest
        ) {
            Button(model.localized("Replace"), role: .destructive) { model.localHelper.copyExplanationIntoChangeRequest() }
            Button(model.localized("Cancel"), role: .cancel) { model.localHelper.confirmReplacingChangeRequest = false }
        } message: {
            Text(model.localized("The change request field already has text. Nothing is sent until you choose Draft plan."))
        }
    }

    /// The local model's summary of the diff and things to check: an opinion, never saved.
    func changeSummary(_ session: SessionRecord, diff: WorkspaceChangeDiff) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LocalHelperRunButton(model: model, task: .changeSummary, title: "Summarize with local model") {
                model.localHelper.summarizeChanges(session: session, diff: diff)
            }
            LocalHelperPreviewDisclosure(model: model, task: .changeSummary, session: session)
            LocalHelperNotes(model: model, task: .changeSummary)
            if let summary = model.localHelper.summary(for: session, diff: diff) {
                Label(model.localized("The local model's opinion. It is not a substitute for verification or your own review, and it is not saved."), systemImage: "exclamationmark.bubble")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    func changeDiffPanel(_ session: SessionRecord) -> some View {
        GroupBox("Full file diff") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.localizedFormat("%@ changed files", String(model.changes.changeDiff?.files.count ?? 0)))
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
                if let diff = model.changes.changeDiff, !diff.files.isEmpty, model.localHelper.allows(.changeSummary) {
                    changeSummary(session, diff: diff)
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
                                } else if file.isTooLargeToDisplay {
                                    Text("This file's diff is too long to show here, but it is still part of the change. Export the patch to review it.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    if file.hasUndecodableText {
                                        Text("This file is not UTF-8, so some characters are shown as �. The original bytes are kept in the patch.")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
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
                if let ignoredPaths = model.changes.changeDiff?.ignoredPaths, !ignoredPaths.isEmpty {
                    Text("These Git-ignored paths are in the workspace but not in this diff. Verification does not see them, and they will not reach your branch.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(ignoredPaths.joined(separator: "\n"))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
                if model.changes.changeDiff?.partiallyShownFiles.isEmpty == false {
                    Toggle("I exported the patch and reviewed the files that are not fully shown above.", isOn: Bindable(model.changes).partiallyShownFilesConfirmed)
                        .font(.caption)
                }
                HStack {
                    Button("Accept this verified diff") { model.changes.acceptChanges() }
                        .disabled(!model.changes.verifiedCurrentDiff || model.changes.changeDiff?.files.isEmpty != false || model.changes.awaitingPartiallyShownFilesConfirmation)
                    TextField("Local branch name", text: Bindable(model.changes).branchName)
                        .frame(maxWidth: 240)
                    Button("Apply to branch as an uncommitted worktree") { model.changes.applyChangesToBranch() }
                        .disabled(!model.changes.verifiedCurrentDiff || model.changes.changeDiff?.files.isEmpty != false || model.changes.awaitingPartiallyShownFilesConfirmation || model.changes.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Applying checks the source base commit for conflicts and creates an uncommitted isolated worktree. AgentBridge commits, pushes or opens a pull request only when you confirm it below, and never merges.")
                    .font(.caption2).foregroundStyle(.secondary)
                appliedBranchSection(session)
            }
        }
        .sheet(isPresented: Bindable(model.changes).isShowingPullRequestSheet) {
            PullRequestSheet(model: model)
                .environment(\.locale, model.appLanguage.locale)
                .interactiveDismissDisabled(model.changes.isOpeningPullRequest)
        }
    }

    /// The branch and worktree the verified changes were applied to, and the
    /// explicit way to commit, push and open a pull request from them.
    @ViewBuilder
    func appliedBranchSection(_ session: SessionRecord) -> some View {
        if let branch = session.appliedBranchName, let worktree = session.appliedWorktreePath {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Applied to a local branch").font(.caption.weight(.semibold))
                Text(model.localizedFormat("Branch: %@", branch)).font(.caption.monospaced()).textSelection(.enabled)
                Text(model.localizedFormat("Worktree: %@", worktree)).font(.caption.monospaced()).textSelection(.enabled)
                if let url = session.pullRequestURL {
                    HStack {
                        Text(model.localizedFormat("Pull request: %@", url)).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Open in Browser") { model.changes.openPullRequestInBrowser(url) }
                    }
                } else if session.appliedCommit != nil {
                    Text("Some steps are done. Open the sheet to see them and continue.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Commit, Push and Open PR…") { model.changes.showPullRequestSheet() }
                        .disabled(model.changes.isOpeningPullRequest || model.hasActiveAutonomousWorkflow)
                    Text("Shows everything first; nothing leaves this Mac until you confirm.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
