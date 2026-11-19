import AppKit
import AgentBridgeCore
import Observation

/// How a local model draft goes into fields the user may already have edited.
/// Kept apart from the views so it can be tested without SwiftUI.
enum LocalHelperFill {
    struct PullRequestFields: Equatable {
        var commitMessage: String
        var title: String
        var body: String
    }

    struct HandoffFields: Equatable {
        var done: String
        var next: String
        var prompt: String
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The sheet's text is replaced without asking while it is still what
    /// AgentBridge proposed, or empty; anything the user edited is asked about first.
    static func pullRequestNeedsConfirmation(current: PullRequestFields, proposed: PullRequestFields) -> Bool {
        current != proposed && !(isBlank(current.commitMessage) && isBlank(current.title) && isBlank(current.body))
    }

    /// The handoff fields start empty, so any text in them was typed by the user.
    static func handoffNeedsConfirmation(current: HandoffFields) -> Bool {
        !(isBlank(current.done) && isBlank(current.next) && isBlank(current.prompt))
    }

    static func fields(for draft: PullRequestDraftText) -> PullRequestFields {
        PullRequestFields(commitMessage: draft.commitMessage, title: draft.title, body: draft.body)
    }

    static func fields(for draft: LocalHelperHandoffDraft) -> HandoffFields {
        HandoffFields(done: draft.done, next: draft.next, prompt: draft.prompt)
    }

    /// The small notes shown after a request, in English for `localized`: why
    /// there is no draft, what was left out, and a long commit subject.
    static func notes<Draft>(for outcome: LocalHelperOutcome<Draft>) -> [String] {
        var notes: [String] = []
        if let reason = outcome.fallbackReason { notes.append(reason) }
        notes += outcome.preview?.truncationNotes ?? []
        if let text = outcome.draft as? PullRequestDraftText, text.commitSubjectIsLong {
            notes.append("The commit subject is longer than 72 characters.")
        }
        return notes
    }

    /// A text answer belongs to what it was asked about: the failure on screen, or the diff.
    struct Answer: Equatable {
        let sessionID: UUID
        let key: String
        let text: String
    }

    static func failureKey(_ result: VerificationResult) -> String {
        "\(result.exitCode.map(String.init) ?? "none"):\(result.durationSeconds):\(result.standardOutput.utf8.count):\(result.standardError.utf8.count)"
    }
}

/// The local model helper in the App: its switches, the guided Ollama setup, and
/// the four drafting tasks. Every result is a draft shown in place or filled into
/// a field after the user agrees; nothing is applied, saved or sent.
@MainActor
@Observable
final class LocalHelperModel {
    var isChangingSwitch = false
    var switchError: String?

    var running: Set<LocalHelperTask> = []
    var notes: [LocalHelperTask: [String]] = [:]
    @ObservationIgnored private var cancellations: [LocalHelperTask: CancellationFlag] = [:]

    var pendingPullRequestDraft: PullRequestDraftText?
    var confirmReplacingPullRequestText = false
    var pendingHandoffDraft: LocalHelperHandoffDraft?
    var confirmReplacingHandoffText = false
    var failureExplanation: LocalHelperFill.Answer?
    var changeSummary: LocalHelperFill.Answer?
    var confirmReplacingChangeRequest = false

    var setupStatus: OllamaSetupStatus?
    var isCheckingSetup = false
    var setupMessage: String?
    var pullModelName = ""
    var isPulling = false
    var pullProgress: OllamaPullProgress?
    @ObservationIgnored private var pullCancellation: CancellationFlag?

    func allows(_ task: LocalHelperTask) -> Bool {
        app.settings.localHelper.allows(task)
    }

    func isRunning(_ task: LocalHelperTask) -> Bool { running.contains(task) }

    func cancel(_ task: LocalHelperTask) {
        cancellations[task]?.cancel()
    }

    // MARK: Switches

    /// Turning the helper on runs the Local connection test on the saved settings first.
    func setEnabled(_ enabled: Bool) {
        guard let service = app.service, !isChangingSwitch else { return }
        isChangingSwitch = true
        switchError = nil
        Task { @MainActor [weak self] in
            defer { self?.isChangingSwitch = false }
            do {
                let saved = try await service.setLocalHelperEnabled(enabled)
                self?.app.settings.localHelper = saved
            } catch {
                self?.switchError = error.localizedDescription
            }
        }
    }

    func setTask(_ task: LocalHelperTask, on: Bool) {
        guard let service = app.service else { return }
        do {
            app.settings.localHelper = try service.setLocalHelperTask(task, on: on)
            switchError = nil
        } catch {
            switchError = error.localizedDescription
        }
    }

    // MARK: Running

    private func run<Draft: Sendable & Equatable>(
        _ task: LocalHelperTask,
        operation: @escaping @Sendable (BridgeService, CancellationFlag) async throws -> LocalHelperOutcome<Draft>,
        onDraft: @escaping @MainActor (Draft) -> Void
    ) {
        guard let service = app.service, !running.contains(task) else { return }
        let cancellation = CancellationFlag()
        cancellations[task] = cancellation
        running.insert(task)
        notes[task] = nil
        Task { @MainActor [weak self] in
            do {
                let outcome = try await operation(service, cancellation)
                guard let self else { return }
                self.notes[task] = LocalHelperFill.notes(for: outcome)
                if let draft = outcome.draft { onDraft(draft) }
            } catch AgentBridgeError.processCancelled {
                self?.notes[task] = ["The local model request was cancelled."]
            } catch {
                self?.notes[task] = [error.localizedDescription]
            }
            self?.running.remove(task)
            self?.cancellations[task] = nil
        }
    }

    // MARK: 1. Commit and pull request text

    private var pullRequestFields: LocalHelperFill.PullRequestFields {
        LocalHelperFill.PullRequestFields(
            commitMessage: app.changes.pullRequestCommitMessage,
            title: app.changes.pullRequestTitle,
            body: app.changes.pullRequestBody
        )
    }

    func rewritePullRequestText() {
        guard let sessionID = app.changes.pullRequestPreview?.sessionID else { return }
        pendingPullRequestDraft = nil
        run(.commitText, operation: { service, cancellation in
            try await service.draftPullRequestTextWithLocalModel(sessionID: sessionID, cancellation: cancellation)
        }, onDraft: { [weak self] draft in
            self?.receivePullRequestDraft(draft, sessionID: sessionID)
        })
    }

    private func receivePullRequestDraft(_ draft: PullRequestDraftText, sessionID: UUID) {
        guard let preview = app.changes.pullRequestPreview, preview.sessionID == sessionID, preview.appliedCommit == nil else { return }
        let proposed = LocalHelperFill.PullRequestFields(commitMessage: preview.commitMessage, title: preview.pullRequestTitle, body: preview.pullRequestBody)
        if LocalHelperFill.pullRequestNeedsConfirmation(current: pullRequestFields, proposed: proposed) {
            pendingPullRequestDraft = draft
            confirmReplacingPullRequestText = true
        } else {
            fillPullRequest(with: draft)
        }
    }

    func confirmReplacingPullRequest() {
        confirmReplacingPullRequestText = false
        if let draft = pendingPullRequestDraft { fillPullRequest(with: draft) }
        pendingPullRequestDraft = nil
    }

    func keepPullRequestText() {
        confirmReplacingPullRequestText = false
        pendingPullRequestDraft = nil
    }

    private func fillPullRequest(with draft: PullRequestDraftText) {
        let fields = LocalHelperFill.fields(for: draft)
        app.changes.pullRequestCommitMessage = fields.commitMessage
        app.changes.pullRequestTitle = fields.title
        app.changes.pullRequestBody = fields.body
        notes[.commitText, default: []].insert("The fields hold the local model's draft. Read and edit them before you confirm.", at: 0)
    }

    // MARK: 2. Explain a failed verification

    func explainFailure(session: SessionRecord, result: VerificationResult) {
        let failure = LocalHelperVerificationFailure(result: result, workspacePath: session.workspacePath)
        let diff = app.changes.changeDiff
        let key = LocalHelperFill.failureKey(result)
        failureExplanation = nil
        run(.explainFailure, operation: { service, cancellation in
            try await service.explainVerificationFailureWithLocalModel(sessionID: session.id, failure: failure, diff: diff, cancellation: cancellation)
        }, onDraft: { [weak self] text in
            self?.failureExplanation = LocalHelperFill.Answer(sessionID: session.id, key: key, text: text)
        })
    }

    func explanation(for session: SessionRecord, result: VerificationResult) -> String? {
        guard let answer = failureExplanation, answer.sessionID == session.id, answer.key == LocalHelperFill.failureKey(result) else { return nil }
        return answer.text
    }

    /// Copies the explanation into the "What should change?" field used by Draft
    /// plan, asking first when the field has text. Nothing is sent.
    func useExplanationAsChangeRequest() {
        if app.changes.changeRequestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copyExplanationIntoChangeRequest()
        } else {
            confirmReplacingChangeRequest = true
        }
    }

    func copyExplanationIntoChangeRequest() {
        confirmReplacingChangeRequest = false
        guard let text = failureExplanation?.text else { return }
        app.changes.changeRequestText = String(text.prefix(BridgeService.maximumChangePlanRequestBytes / 4))
        app.status = app.localized("The explanation is in the change request field. Edit it, then choose Draft plan when you are ready.")
    }

    // MARK: 3. Handoff summary

    private var handoffFields: LocalHelperFill.HandoffFields {
        LocalHelperFill.HandoffFields(done: app.continuationDoneSummary, next: app.continuationNextStep, prompt: app.continuationSuggestedPrompt)
    }

    func draftHandoff(session: SessionRecord) {
        pendingHandoffDraft = nil
        run(.handoffSummary, operation: { service, cancellation in
            try await service.draftHandoffWithLocalModel(sessionID: session.id, cancellation: cancellation)
        }, onDraft: { [weak self] draft in
            guard let self, self.app.selectedSession?.id == session.id else { return }
            if LocalHelperFill.handoffNeedsConfirmation(current: self.handoffFields) {
                self.pendingHandoffDraft = draft
                self.confirmReplacingHandoffText = true
            } else {
                self.fillHandoff(with: draft)
            }
        })
    }

    func confirmReplacingHandoff() {
        confirmReplacingHandoffText = false
        if let draft = pendingHandoffDraft { fillHandoff(with: draft) }
        pendingHandoffDraft = nil
    }

    func keepHandoffText() {
        confirmReplacingHandoffText = false
        pendingHandoffDraft = nil
    }

    private func fillHandoff(with draft: LocalHelperHandoffDraft) {
        let fields = LocalHelperFill.fields(for: draft)
        app.continuationDoneSummary = fields.done
        app.continuationNextStep = fields.next
        app.continuationSuggestedPrompt = fields.prompt
        notes[.handoffSummary, default: []].insert("The fields hold the local model's draft. Read and edit them before you continue.", at: 0)
    }

    // MARK: 4. Summarize changes

    func summarizeChanges(session: SessionRecord, diff: WorkspaceChangeDiff) {
        changeSummary = nil
        run(.changeSummary, operation: { service, cancellation in
            try await service.summarizeChangesWithLocalModel(sessionID: session.id, diff: diff, cancellation: cancellation)
        }, onDraft: { [weak self] text in
            self?.changeSummary = LocalHelperFill.Answer(sessionID: session.id, key: diff.digest, text: text)
        })
    }

    func summary(for session: SessionRecord, diff: WorkspaceChangeDiff) -> String? {
        guard let answer = changeSummary, answer.sessionID == session.id, answer.key == diff.digest else { return nil }
        return answer.text
    }

    // MARK: Previews

    /// What a task would send now, for the "What will be sent" disclosure. Sends nothing.
    func preview(_ task: LocalHelperTask, session: SessionRecord) async throws -> LocalHelperPreview {
        guard let service = app.service else { throw AgentBridgeError.invalidInput(app.localized("Choose a workspace folder before previewing context.")) }
        switch task {
        case .commitText:
            return try await service.localHelperPullRequestPreview(sessionID: session.id)
        case .explainFailure:
            guard let result = app.changes.verificationResult else { throw AgentBridgeError.invalidInput("There is no failed verification to explain.") }
            return try await service.localHelperFailurePreview(
                sessionID: session.id,
                failure: LocalHelperVerificationFailure(result: result, workspacePath: session.workspacePath),
                diff: app.changes.changeDiff
            )
        case .handoffSummary:
            return try await service.localHelperHandoffPreview(sessionID: session.id)
        case .changeSummary:
            return try await service.localHelperChangeSummaryPreview(sessionID: session.id, diff: app.changes.changeDiff)
        }
    }

    // MARK: Guided Ollama setup

    func checkSetup() {
        guard let service = app.service, !isCheckingSetup else { return }
        isCheckingSetup = true
        setupMessage = nil
        Task { @MainActor [weak self] in
            let status = await service.ollamaSetupStatus()
            guard let self else { return }
            self.setupStatus = status
            if self.pullModelName.trimmingCharacters(in: .whitespaces).isEmpty {
                self.pullModelName = status.recommendation.model
            }
            self.isCheckingSetup = false
        }
    }

    /// Opens the official download page in the browser; the user installs Ollama.
    func openDownloadPage() {
        NSWorkspace.shared.open(OllamaSetup.downloadPageURL)
    }

    func startOllama() {
        guard let service = app.service else { return }
        setupMessage = nil
        Task { @MainActor [weak self] in
            do {
                try await service.startOllamaApp()
                self?.setupMessage = "Opened the Ollama app. Check again once it has started."
            } catch {
                self?.setupMessage = error.localizedDescription
            }
        }
    }

    /// Runs `ollama pull` for the typed name, only from this click; afterwards the
    /// Local settings use the model and the connection test runs.
    func pullModel() {
        let name = pullModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let service = app.service, !isPulling else { return }
        do { _ = try OllamaSetup.pullArguments(model: name) } catch {
            setupMessage = error.localizedDescription
            return
        }
        let cancellation = CancellationFlag()
        pullCancellation = cancellation
        isPulling = true
        pullProgress = nil
        setupMessage = nil
        let report: @Sendable (OllamaPullProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.pullProgress = progress }
        }
        Task { @MainActor [weak self] in
            do {
                try await service.pullOllamaModel(name, cancellation: cancellation, onProgress: report)
                guard let self else { return }
                self.isPulling = false
                self.useDownloadedModel(name)
            } catch AgentBridgeError.processCancelled {
                self?.isPulling = false
                self?.setupMessage = "The download was cancelled."
            } catch {
                self?.isPulling = false
                self?.setupMessage = error.localizedDescription
            }
            self?.pullCancellation = nil
        }
    }

    func cancelPull() {
        pullCancellation?.cancel()
    }

    private func useDownloadedModel(_ name: String) {
        if app.settings.localModel.backend != .ollama {
            app.settings.localModel.backend = .ollama
            app.settings.localModel.endpoint = setupStatus?.endpoint ?? LocalModelSettings().endpoint
        }
        app.settings.localModel.model = name
        app.saveLocalModelSettings()
        app.testLocalModelConnectionFromUI()
        setupMessage = "The model was downloaded and saved as the Local model. Testing the connection…"
        checkSetup()
    }

    @ObservationIgnored private weak var owner: AppModel?

    private var app: AppModel {
        guard let owner else { preconditionFailure("LocalHelperModel outlived its AppModel.") }
        return owner
    }

    /// Connects this model to the `AppModel` that owns it; called once from `AppModel.init`.
    func attach(to app: AppModel) {
        owner = app
    }
}
