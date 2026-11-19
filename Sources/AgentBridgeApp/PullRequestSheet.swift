import AgentBridgeCore
import SwiftUI

/// Confirms, then runs, the commit in the apply worktree, the push and the pull
/// request. Every field can be edited first; nothing runs until the confirm button.
struct PullRequestSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var changes: ChangeReviewModel { model.changes }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit, Push and Open Pull Request")
                .font(.title3.weight(.semibold))
            if let preview = changes.pullRequestPreview {
                content(preview)
            } else if changes.isLoadingPullRequestPreview {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading the branch, remotes and GitHub CLI sign-in…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = changes.pullRequestError {
                VStack(alignment: .leading, spacing: 4) {
                    if let step = changes.pullRequestFailedStep {
                        Text(model.localizedFormat("Failed at: %@", model.localized(PullRequestPresentation.title(of: step))))
                            .font(.caption.weight(.semibold))
                    }
                    Text(model.localized(error))
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(changes.pullRequestPreview?.pullRequestURL == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(changes.isOpeningPullRequest)
                if changes.pullRequestPreview?.pullRequestURL == nil {
                    Button(changes.pullRequestFailedStep == nil ? "Commit, Push and Open PR" : "Retry") { changes.openPullRequest() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!changes.canStartPullRequest)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560)
    }

    @ViewBuilder
    private func content(_ preview: PullRequestPreview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.localizedFormat("Branch: %@", preview.branchName)).font(.caption.monospaced()).textSelection(.enabled)
                Text(model.localizedFormat("Worktree: %@", preview.worktreePath)).font(.caption.monospaced()).textSelection(.enabled)
                if let message = PullRequestPresentation.blockingMessage(for: preview.gitHubCLI) {
                    Label(model.localized(message), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !preview.worktreeMatchesVerifiedDiff && preview.appliedCommit == nil {
                    Label("The apply worktree no longer matches the verified changes, so it cannot be committed. Apply the verified changes to a new branch.", systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if preview.remotes.isEmpty {
                    Label("The source repository has no remote. Add one with `git remote add` in Terminal, then try again.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Picker("Remote", selection: Binding(get: { changes.pullRequestRemote }, set: { changes.selectPullRequestRemote($0) })) {
                        ForEach(preview.remotes, id: \.name) { remote in
                            Text(verbatim: "\(remote.name) · \(remote.pushURL)").tag(remote.name)
                        }
                    }
                    .disabled(changes.isOpeningPullRequest || preview.pushedRemote != nil)
                }
                TextField("Base branch", text: Bindable(changes).pullRequestBase)
                    .disabled(changes.isOpeningPullRequest)
                if preview.proposedBase == nil {
                    Text("The remote's default branch could not be found. Type the base branch.")
                        .font(.caption2).foregroundStyle(.orange)
                } else if preview.baseSource == .existingBranch {
                    Text("This branch exists, but it may not be the remote's default branch. Check it before you continue.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("Commit message").font(.caption.weight(.semibold))
                TextEditor(text: Bindable(changes).pullRequestCommitMessage)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 70, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .disabled(changes.isOpeningPullRequest || preview.appliedCommit != nil)
                TextField("Pull request title", text: Bindable(changes).pullRequestTitle)
                    .disabled(changes.isOpeningPullRequest)
                Text("Pull request description").font(.caption.weight(.semibold))
                TextEditor(text: Bindable(changes).pullRequestBody)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 90, maxHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .disabled(changes.isOpeningPullRequest)
                localModelRewrite(preview)
                Toggle("Draft pull request", isOn: Bindable(changes).pullRequestDraft)
                    .disabled(changes.isOpeningPullRequest)
                Text(model.localizedFormat(
                    "This commits in the apply worktree, pushes the branch to %@ and opens a pull request on GitHub. Your code leaves this Mac. Nothing is merged.",
                    preview.remotes.first(where: { $0.name == changes.pullRequestRemote })?.pushURL ?? changes.pullRequestRemote
                ))
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                stepList(preview)
                if let url = preview.pullRequestURL {
                    HStack {
                        Text(verbatim: url).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Open in Browser") { changes.openPullRequestInBrowser(url) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Asks the local model helper for the text above. Its draft replaces text
    /// the user edited only after they agree; nothing runs until the confirm button.
    @ViewBuilder
    private func localModelRewrite(_ preview: PullRequestPreview) -> some View {
        if model.localHelper.allows(.commitText), preview.appliedCommit == nil, preview.pullRequestURL == nil,
           let session = model.sessions.first(where: { $0.id == preview.sessionID }) {
            VStack(alignment: .leading, spacing: 4) {
                LocalHelperRunButton(model: model, task: .commitText, title: "Rewrite with local model", disabled: changes.isOpeningPullRequest) {
                    model.localHelper.rewritePullRequestText()
                }
                Text(model.localized("Sends the plan, the file list, the recorded verification and the verified diff to the local model. Its draft fills the fields above for you to edit."))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LocalHelperPreviewDisclosure(model: model, task: .commitText, session: session)
                LocalHelperNotes(model: model, task: .commitText)
            }
            .alert(
                model.localized("Replace the commit and pull request text with the local model's draft?"),
                isPresented: Bindable(model.localHelper).confirmReplacingPullRequestText
            ) {
                Button(model.localized("Replace"), role: .destructive) { model.localHelper.confirmReplacingPullRequest() }
                Button(model.localized("Keep my text"), role: .cancel) { model.localHelper.keepPullRequestText() }
            } message: {
                Text(model.localized("You edited the commit message, title or description. The draft replaces all three; nothing is committed until you confirm."))
            }
        }
    }

    private func stepList(_ preview: PullRequestPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(
                PullRequestPresentation.stepStates(
                    completed: preview.completedSteps,
                    running: changes.pullRequestRunningStep,
                    failed: changes.pullRequestFailedStep
                ),
                id: \.step
            ) { item in
                HStack(spacing: 6) {
                    switch item.state {
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .running: ProgressView().controlSize(.small)
                    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                    }
                    Text(model.localized(PullRequestPresentation.title(of: item.step))).font(.caption)
                }
            }
        }
    }
}
