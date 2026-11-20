import AppKit
import AgentBridgeCore
import Observation

/// How a drafted plan goes into the plan form.
enum ChangePlanDraftFill {
    struct Fields: Equatable {
        var title: String
        var summary: String
        var stepsText: String
    }

    /// Whether filling the form would replace anything the user typed. Blank
    /// fields hold nothing to lose; the shared-memory toggle is never filled.
    static func replacesUserText(title: String, summary: String, stepsText: String) -> Bool {
        [title, summary, stepsText].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A draft fills the form without a second question when the form still holds
    /// what it held when drafting started (already agreed to), or nothing at all.
    static func canFillWithoutAsking(current: Fields, atStart: Fields) -> Bool {
        current == atStart || !replacesUserText(title: current.title, summary: current.summary, stepsText: current.stepsText)
    }

    static func fields(for draft: DraftedChangePlan) -> Fields {
        Fields(title: draft.title, summary: draft.summary, stepsText: draft.steps.joined(separator: "\n"))
    }
}

/// Review of an isolated-change session: the plan draft and its approval,
/// the current diff, per-file restore, patch export, verification results,
/// acceptance and applying to a local branch. Running the approved change
/// and the verifier stays on `AppModel` with the other runs.
@MainActor
@Observable
final class ChangeReviewModel {
    var changePlanTitle = ""
    var changePlanSummary = ""
    var changePlanStepsText = ""
    var changePlanIncludesSharedMemory = false
    var changeDiff: WorkspaceChangeDiff?
    var verificationResult: VerificationResult?
    var localFileCandidates: [LocalChangeFileCandidate] = []
    var localFileCandidatesError: String?
    var isLoadingLocalFileCandidates = false
    var selectedLocalPaths: Set<String> = []
    var localFileSearchText = ""
    var localNewFilePathsText = ""
    var localFixNote = ""
    var localChangePreview: LocalChangeInputPreview?
    var localFixPreview: LocalChangeInputPreview?
    var localChangePreviewError: String?
    var localFixPreviewError: String?
    var localChangeResult: LocalChangeRunResult?
    var isLoadingLocalChangePreview = false
    var isLoadingLocalFixPreview = false
    @ObservationIgnored private var localChangePreviewRevision = 0
    @ObservationIgnored private var localFixPreviewRevision = 0
    /// Preview refreshes wait for a short pause in typing, and a newer refresh,
    /// a run or a fix supersedes one in flight.
    @ObservationIgnored let localPreviewDebouncer = DebouncedTask(delayNanoseconds: 300_000_000)
    @ObservationIgnored private var localFileCandidatesRevision = 0
    @ObservationIgnored private var localFileCandidatesTask: Task<Void, Never>?
    var branchName = ""
    var customVerifierPath = ""
    var customVerifierArgumentsText = ""
    var isVerifying = false
    /// What the user asks the model to plan; it is never saved.
    var changeRequestText = ""
    /// The session a plan is being drafted for, while its read-only run lasts.
    var draftingSessionID: UUID?
    var confirmReplacingPlanFields = false
    /// A finished draft waiting for the user to agree to replace newer text.
    private(set) var pendingDraft: DraftedChangePlan?
    private var partiallyShownFilesConfirmedDigest: String?
    /// The commit, push and pull request sheet. Nothing runs until its confirm button.
    var isShowingPullRequestSheet = false
    var pullRequestPreview: PullRequestPreview?
    var isLoadingPullRequestPreview = false
    var pullRequestRemote = ""
    var pullRequestBase = ""
    var pullRequestCommitMessage = ""
    var pullRequestTitle = ""
    var pullRequestBody = ""
    var pullRequestDraft = true
    var isOpeningPullRequest = false
    var pullRequestRunningStep: PullRequestStep?
    var pullRequestFailedStep: PullRequestStep?
    var pullRequestError: String?

    var isDraftingSelectedPlan: Bool {
        draftingSessionID != nil && draftingSessionID == app.selectedSession?.id
    }

    var selectedChangePlanDraftMatchesSaved: Bool {
        guard let plan = app.selectedSession?.changePlan else { return false }
        return ChangePlanDraft(
            title: changePlanTitle,
            summary: changePlanSummary,
            stepsText: changePlanStepsText,
            includesSharedMemory: changePlanIncludesSharedMemory
        ).matches(plan)
    }

    var selectedChangePlanIsApproved: Bool {
        guard selectedChangePlanDraftMatchesSaved,
              let session = app.selectedSession,
              let plan = session.changePlan else { return false }
        return session.approvedChangePlanDigest == plan.reviewDigest
    }

    var verifiedCurrentDiff: Bool {
        guard let session = app.selectedSession, let diff = changeDiff,
              session.verificationPassed == true,
              session.verificationDiffDigest == diff.digest,
              let verifiedAt = session.verificationCompletedAt,
              let lastChangeAt = session.lastChangeRunAt else { return false }
        return verifiedAt >= lastChangeAt
    }

    /// Bound to the digest, so a confirmation lapses as soon as the diff changes.
    var partiallyShownFilesConfirmed: Bool {
        get { changeDiff != nil && partiallyShownFilesConfirmedDigest == changeDiff?.digest }
        set { partiallyShownFilesConfirmedDigest = newValue ? changeDiff?.digest : nil }
    }

    var awaitingPartiallyShownFilesConfirmation: Bool {
        changeDiff?.partiallyShownFiles.isEmpty == false && !partiallyShownFilesConfirmed
    }

    func loadChangePlanDraftFromSelectedSession() {
        // A draft waiting for an answer belongs to the session that was shown.
        cancelReplacingPlanFields()
        if let plan = app.selectedSession?.changePlan {
            changePlanTitle = plan.title
            changePlanSummary = plan.summary
            changePlanStepsText = plan.steps.joined(separator: "\n")
            changePlanIncludesSharedMemory = plan.includesSharedMemory
        } else {
            changePlanTitle = ""
            changePlanSummary = ""
            changePlanStepsText = ""
            changePlanIncludesSharedMemory = false
        }
        selectedLocalPaths = []
        localNewFilePathsText = ""
        localFixNote = ""
        localChangePreviewRevision += 1
        localFixPreviewRevision += 1
        localChangePreview = nil
        localFixPreview = nil
        localChangePreviewError = nil
        localFixPreviewError = nil
        localChangeResult = nil
        isLoadingLocalChangePreview = false
        isLoadingLocalFixPreview = false
        localFileCandidates = []
        reloadLocalFileCandidates()
    }

    func reloadLocalFileCandidates() {
        localFileCandidatesRevision += 1
        let candidatesRevision = localFileCandidatesRevision
        localFileCandidatesTask?.cancel()
        localFileCandidatesTask = nil
        localFileCandidatesError = nil
        isLoadingLocalFileCandidates = false
        if let session = app.selectedSession, session.provider == .local, session.policy.accessMode == .isolatedChanges {
            isLoadingLocalFileCandidates = true
            localFileCandidatesTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // Selecting an isolated-changes session also starts an initial
                // diff load; let that read finish before fetching the picker's
                // file list so the list matches the diff shown.
                while self.app.changeDiffLoadsInFlight.contains(session.id) {
                    guard !Task.isCancelled,
                          self.localFileCandidatesRevision == candidatesRevision,
                          self.app.selectedSessionID == session.id else { return }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                guard !Task.isCancelled,
                      self.localFileCandidatesRevision == candidatesRevision,
                      self.app.selectedSessionID == session.id,
                      let service = self.app.service else { return }
                do {
                    let candidates = try await service.localChangeFileCandidates(sessionID: session.id)
                    guard !Task.isCancelled,
                          self.localFileCandidatesRevision == candidatesRevision,
                          self.app.selectedSessionID == session.id else { return }
                    self.localFileCandidates = candidates
                    self.localFileCandidatesError = nil
                    self.isLoadingLocalFileCandidates = false
                    self.refreshLocalPreviews()
                } catch {
                    guard !Task.isCancelled,
                          self.localFileCandidatesRevision == candidatesRevision,
                          self.app.selectedSessionID == session.id else { return }
                    self.localFileCandidatesError = error.localizedDescription
                    self.isLoadingLocalFileCandidates = false
                }
            }
        }
    }

    var localNewFilePaths: [String] {
        localNewFilePathsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var filteredLocalFileCandidates: [LocalChangeFileCandidate] {
        let query = localFileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return localFileCandidates }
        return localFileCandidates.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    /// A Local run or fix is in progress for the shown session, so previews wait
    /// for it to finish instead of reporting what the run is changing.
    var localPreviewIsPaused: Bool {
        guard let session = app.selectedSession, session.provider == .local else { return false }
        return app.selectedSessionIsRunning
    }

    func refreshLocalPreviews() {
        localChangePreviewRevision += 1
        localFixPreviewRevision += 1
        let changeRevision = localChangePreviewRevision
        let fixRevision = localFixPreviewRevision
        localChangePreview = nil
        localFixPreview = nil
        localChangePreviewError = nil
        localFixPreviewError = nil
        isLoadingLocalFixPreview = false
        guard !localPreviewIsPaused else {
            localPreviewDebouncer.cancel()
            isLoadingLocalChangePreview = false
            return
        }
        isLoadingLocalChangePreview = true
        localPreviewDebouncer.schedule { [weak self] isCurrent in
            guard let self, isCurrent(),
                  self.localChangePreviewRevision == changeRevision,
                  self.localFixPreviewRevision == fixRevision else { return }
            await self.loadLocalPreview(forFix: false, revision: changeRevision)
            guard isCurrent(),
                  self.localChangePreviewRevision == changeRevision,
                  self.localFixPreviewRevision == fixRevision else { return }
            await self.loadLocalPreview(forFix: true, revision: fixRevision)
        }
    }

    /// Called when a Local run or fix starts: any preview in flight is dropped,
    /// and the previews shown so far stay until the run refreshes them.
    func cancelLocalPreviews() {
        localPreviewDebouncer.cancel()
        localChangePreviewRevision += 1
        localFixPreviewRevision += 1
        isLoadingLocalChangePreview = false
        isLoadingLocalFixPreview = false
    }

    private func loadLocalPreview(forFix: Bool, revision: Int) async {
        guard let service = app.service, let session = app.selectedSession,
              session.provider == .local, let plan = session.changePlan,
              session.approvedChangePlanDigest == plan.reviewDigest else {
            if forFix {
                localFixPreview = nil
                localFixPreviewError = nil
                isLoadingLocalFixPreview = false
            } else {
                localChangePreview = nil
                localChangePreviewError = nil
                isLoadingLocalChangePreview = false
            }
            return
        }
        let failure: LocalHelperVerificationFailure?
        if forFix, session.verificationPassed == false,
           let result = verificationResult, !result.succeeded, !result.wasCancelled, result.skippedReason == nil {
            failure = LocalHelperVerificationFailure(result: result, workspacePath: session.workspacePath)
        } else {
            failure = nil
        }
        guard !forFix || failure != nil else {
            localFixPreview = nil
            localFixPreviewError = nil
            isLoadingLocalFixPreview = false
            return
        }
        if forFix {
            localFixPreview = nil
            localFixPreviewError = nil
            isLoadingLocalFixPreview = true
        } else {
            localChangePreview = nil
            localChangePreviewError = nil
            isLoadingLocalChangePreview = true
        }
        let selected = selectedLocalPaths.sorted()
        while app.changeDiffLoadsInFlight.contains(session.id) {
            let isCurrent = forFix
                ? revision == localFixPreviewRevision
                : revision == localChangePreviewRevision
            guard isCurrent else { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let isCurrent = forFix
            ? revision == localFixPreviewRevision
            : revision == localChangePreviewRevision
        guard isCurrent else { return }
        do {
            // A fix preview lets Core add the changed files exactly as the fix run
            // does, skipping the ones that cannot be sent, so both agree.
            let preview: LocalChangeInputPreview
            if forFix, let failure {
                preview = try await service.previewLocalFixInput(
                    sessionID: session.id,
                    failure: failure,
                    note: localFixNote,
                    filePaths: selected,
                    newFilePaths: localNewFilePaths
                )
            } else {
                preview = try await service.previewLocalChangeInput(
                    sessionID: session.id,
                    planID: plan.id,
                    reviewedDigest: plan.reviewDigest,
                    request: app.prompt,
                    filePaths: selected,
                    newFilePaths: localNewFilePaths
                )
            }
            let isCurrent = forFix
                ? revision == localFixPreviewRevision
                : revision == localChangePreviewRevision
            guard isCurrent else { return }
            if forFix {
                localFixPreview = preview
                isLoadingLocalFixPreview = false
            } else {
                localChangePreview = preview
                isLoadingLocalChangePreview = false
            }
        } catch {
            let isCurrent = forFix
                ? revision == localFixPreviewRevision
                : revision == localChangePreviewRevision
            guard isCurrent else { return }
            // A run that started meanwhile explains any failure; the panel shows
            // the neutral paused note instead of an error.
            let message = localPreviewIsPaused ? nil : error.localizedDescription
            if forFix {
                localFixPreview = nil
                localFixPreviewError = message
                isLoadingLocalFixPreview = false
            } else {
                localChangePreview = nil
                localChangePreviewError = message
                isLoadingLocalChangePreview = false
            }
        }
    }

    /// Drafting fills the title, summary and steps, so text the user already wrote
    /// there is only replaced after they agree to it.
    func requestChangePlanDraft() {
        pendingDraft = nil
        if ChangePlanDraftFill.replacesUserText(title: changePlanTitle, summary: changePlanSummary, stepsText: changePlanStepsText) {
            confirmReplacingPlanFields = true
        } else {
            app.draftChangePlan()
        }
    }

    /// The answer to the replace question: either start drafting, or fill in a
    /// draft that arrived after the form changed.
    func confirmReplacingPlanFieldsWithDraft() {
        confirmReplacingPlanFields = false
        if let draft = pendingDraft {
            pendingDraft = nil
            fillPlanFields(with: draft)
            app.status = "The draft is in the plan form. Edit it, then save it for review."
        } else {
            app.draftChangePlan()
        }
    }

    func cancelReplacingPlanFields() {
        confirmReplacingPlanFields = false
        pendingDraft = nil
    }

    var planFields: ChangePlanDraftFill.Fields {
        ChangePlanDraftFill.Fields(title: changePlanTitle, summary: changePlanSummary, stepsText: changePlanStepsText)
    }

    /// Fills a finished draft into the form when the form still shows what the
    /// user agreed to replace; otherwise asks again before replacing new text.
    func receiveDraft(_ draft: DraftedChangePlan, fieldsAtStart: ChangePlanDraftFill.Fields) {
        if ChangePlanDraftFill.canFillWithoutAsking(current: planFields, atStart: fieldsAtStart) {
            fillPlanFields(with: draft)
            app.status = "The draft is in the plan form. Edit it, then save it for review."
        } else {
            pendingDraft = draft
            confirmReplacingPlanFields = true
            app.status = "The draft is ready. Choose whether it replaces the plan fields."
        }
    }

    /// Fills the form only. The shared-memory choice stays the user's, and nothing is saved.
    func fillPlanFields(with draft: DraftedChangePlan) {
        let fields = ChangePlanDraftFill.fields(for: draft)
        changePlanTitle = fields.title
        changePlanSummary = fields.summary
        changePlanStepsText = fields.stepsText
    }

    func saveChangePlan() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession,
              session.policy.accessMode == .isolatedChanges else {
            app.errorMessage = "Create an isolated-changes session first."
            return
        }
        let steps = changePlanStepsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            let plan = try service.createChangePlan(
                sessionID: session.id,
                title: changePlanTitle,
                summary: changePlanSummary,
                steps: steps,
                includesSharedMemory: changePlanIncludesSharedMemory
            )
            changePlanTitle = plan.title
            changePlanSummary = plan.summary
            changePlanStepsText = plan.steps.joined(separator: "\n")
            app.status = "The plan was saved as awaiting review; writes are not authorized yet."
            app.refresh()
            if session.provider == .local { refreshLocalPreviews() }
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    func approveChangePlan() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession, let plan = session.changePlan else {
            app.errorMessage = "Save a work plan first."
            return
        }
        guard selectedChangePlanDraftMatchesSaved else {
            app.errorMessage = app.localized("Save your plan changes before review or approval.")
            return
        }
        do {
            _ = try service.approveChangePlan(sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest)
            app.status = "Explicitly approved the plan shown; you can now run isolated changes."
            app.refresh()
            if session.provider == .local { refreshLocalPreviews() }
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    func restoreChangeFile(_ path: String) {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession else { return }
        Task { @MainActor [weak self] in
            do {
                try await service.restoreChangeFiles(sessionID: session.id, filePaths: [path])
                self?.app.refreshSelectedEvents()
                self?.app.refresh()
            } catch { self?.app.errorMessage = error.localizedDescription }
        }
    }

    func restoreAllChangeFiles() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession else { return }
        Task { @MainActor [weak self] in
            do {
                try await service.restoreAllChanges(sessionID: session.id)
                self?.app.refreshSelectedEvents()
                self?.app.refresh()
            } catch { self?.app.errorMessage = error.localizedDescription }
        }
    }

    func exportChangePatch() {
        guard let service = app.service, let session = app.selectedSession else { return }
        Task { @MainActor [weak self] in
            do {
                let patch = try await service.exportChangePatch(sessionID: session.id)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "AgentBridge-\(session.id.uuidString.prefix(8)).patch"
                panel.allowedContentTypes = [.plainText]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try patch.write(to: url, options: .atomic)
                self?.app.status = "Exported a \(patch.count)-byte patch."
                self?.app.refreshSelectedEvents()
            } catch { self?.app.errorMessage = error.localizedDescription }
        }
    }

    func chooseCustomVerifier() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Executable"
        if panel.runModal() == .OK, let url = panel.url { customVerifierPath = url.path }
    }

    func acceptChanges() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession else { return }
        let confirmedDigest = partiallyShownFilesConfirmedDigest
        Task { @MainActor [weak self] in
            do {
                _ = try await service.acceptChanges(sessionID: session.id, partiallyShownFilesConfirmedDigest: confirmedDigest)
                self?.app.status = "Accepted the currently verified diff; the source repository is still unchanged."
                self?.app.refresh()
            } catch { self?.app.errorMessage = error.localizedDescription }
        }
    }

    func applyChangesToBranch() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession else { return }
        let requestedBranchName = branchName
        let confirmedDigest = partiallyShownFilesConfirmedDigest
        Task { @MainActor [weak self] in
            do {
                let result = try await service.applyChangesToLocalBranch(
                    sessionID: session.id,
                    branchName: requestedBranchName,
                    partiallyShownFilesConfirmedDigest: confirmedDigest
                )
                self?.app.status = "Created an uncommitted worktree: \(result.worktreePath); no commit, push or merge was made."
                self?.app.refresh()
            } catch { self?.app.errorMessage = error.localizedDescription }
        }
    }

    var pullRequestForm: PullRequestPresentation.Form {
        PullRequestPresentation.Form(remote: pullRequestRemote, base: pullRequestBase, commitMessage: pullRequestCommitMessage, title: pullRequestTitle)
    }

    var canStartPullRequest: Bool {
        PullRequestPresentation.canStart(preview: pullRequestPreview, form: pullRequestForm, isRunning: isOpeningPullRequest || isLoadingPullRequestPreview)
    }

    /// Opens the sheet with the proposed remote, base, message, title and body.
    /// Building the preview runs Git and `gh auth status` only.
    func showPullRequestSheet() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let session = app.selectedSession, session.appliedBranchName != nil else { return }
        pullRequestPreview = nil
        pullRequestRunningStep = nil
        pullRequestFailedStep = nil
        pullRequestError = nil
        pullRequestDraft = true
        isShowingPullRequestSheet = true
        loadPullRequestPreview(sessionID: session.id, remote: nil, fillText: true)
    }

    /// A different remote can have a different default branch, so the base is proposed again.
    func selectPullRequestRemote(_ remote: String) {
        guard remote != pullRequestRemote, let sessionID = pullRequestPreview?.sessionID else { return }
        pullRequestRemote = remote
        loadPullRequestPreview(sessionID: sessionID, remote: remote, fillText: false)
    }

    private func loadPullRequestPreview(sessionID: UUID, remote: String?, fillText: Bool) {
        guard let service = app.service else { return }
        isLoadingPullRequestPreview = true
        Task { @MainActor [weak self] in
            defer { self?.isLoadingPullRequestPreview = false }
            do {
                let preview = try await service.pullRequestPreview(sessionID: sessionID, remote: remote)
                guard let self else { return }
                self.pullRequestPreview = preview
                self.pullRequestRemote = preview.selectedRemote ?? ""
                self.pullRequestBase = preview.proposedBase ?? ""
                if fillText {
                    self.pullRequestCommitMessage = preview.commitMessage
                    self.pullRequestTitle = preview.pullRequestTitle
                    self.pullRequestBody = preview.pullRequestBody
                }
            } catch {
                self?.pullRequestError = error.localizedDescription
            }
        }
    }

    /// Runs the steps that are not done yet; after a failure the same button retries.
    func openPullRequest() {
        guard canStartPullRequest, let service = app.service, let preview = pullRequestPreview else { return }
        let request = PullRequestRequest(
            remote: pullRequestRemote,
            base: pullRequestBase.trimmingCharacters(in: .whitespacesAndNewlines),
            commitMessage: pullRequestCommitMessage,
            title: pullRequestTitle,
            body: pullRequestBody,
            draft: pullRequestDraft
        )
        let sessionID = preview.sessionID
        isOpeningPullRequest = true
        pullRequestFailedStep = nil
        pullRequestError = nil
        pullRequestRunningStep = .commit
        // The model lives as long as the App window, so holding it until a step reports is fine.
        let onStepStarted: @Sendable (PullRequestStep) -> Void = { [self] step in
            Task { @MainActor in
                if self.isOpeningPullRequest { self.pullRequestRunningStep = step }
            }
        }
        Task { @MainActor [weak self] in
            do {
                let outcome = try await service.openPullRequest(sessionID: sessionID, request: request, onStepStarted: onStepStarted)
                self?.app.status = "Opened pull request \(outcome.pullRequestURL). Nothing was merged."
            } catch {
                self?.pullRequestFailedStep = PullRequestPresentation.failedStep(of: error)
                self?.pullRequestError = error.localizedDescription
            }
            guard let self else { return }
            self.isOpeningPullRequest = false
            self.pullRequestRunningStep = nil
            if let refreshed = try? await service.pullRequestPreview(sessionID: sessionID, remote: request.remote, base: request.base) {
                self.pullRequestPreview = refreshed
            }
            self.app.refreshSelectedEvents()
            self.app.refresh()
        }
    }

    func openPullRequestInBrowser(_ text: String?) {
        guard let url = PullRequestPresentation.browserURL(text) else { return }
        NSWorkspace.shared.open(url)
    }

    @ObservationIgnored private weak var owner: AppModel?

    private var app: AppModel {
        guard let owner else { preconditionFailure("ChangeReviewModel outlived its AppModel.") }
        return owner
    }

    /// Connects this model to the `AppModel` that owns it; called once from `AppModel.init`.
    func attach(to app: AppModel) {
        owner = app
    }
}
