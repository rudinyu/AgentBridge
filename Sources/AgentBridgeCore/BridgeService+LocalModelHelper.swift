import Foundation

/// The local model helper: the configured loopback model drafts text for small
/// tasks in Codex and Claude workflows. It reuses the Local settings and limits,
/// never calls Codex or Claude, and never applies, saves or sends what it drafts.
///
/// Consent: the helper's master switch and a task's switch are the consent for
/// that task. Unlike Local conversations, helper requests do not need the shared
/// memory consent of the source or Local profile, because they go only to the
/// loopback endpoint and their inputs and outputs are never written to shared
/// memory, project memory, handoff files or provider history. The audit log
/// records the task, byte counts and truncation, never prompt or answer text.
extension BridgeService {
    // MARK: Settings

    public func localHelperSettings() throws -> LocalModelHelperSettings {
        try store.loadSettings().localHelper
    }

    /// Turning the helper on needs a configured Local model that the server
    /// lists, checked now; turning it off needs nothing. Returns the saved switches.
    @discardableResult
    public func setLocalHelperEnabled(_ enabled: Bool) async throws -> LocalModelHelperSettings {
        if enabled {
            let local = try store.loadSettings().localModel
            try LocalModelClient.validateSettings(local)
            guard !local.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentBridgeError.invalidInput("Choose a local model and pass the connection test before turning on the local model helper.")
            }
            let models: [LocalModelDescriptor]
            do {
                models = try await localModelClient.models(settings: local)
            } catch AgentBridgeError.processCancelled {
                throw AgentBridgeError.processCancelled
            } catch {
                throw AgentBridgeError.invalidInput("The local model connection test did not pass, so the helper stays off: \(OutputRedactor.redact(error.localizedDescription))")
            }
            guard models.contains(where: { $0.id == local.model || $0.name == local.model }) else {
                throw AgentBridgeError.invalidInput("The configured local model is not in the server's model list, so the helper stays off.")
            }
        }
        return try updateSettings { settings in
            var helper = settings.localHelper
            helper.enabled = enabled
            settings.localHelper = helper
        }.localHelper
    }

    /// A task's own switch. It has no effect while the master switch is off.
    @discardableResult
    public func setLocalHelperTask(_ task: LocalHelperTask, on: Bool) throws -> LocalModelHelperSettings {
        return try updateSettings { settings in
            var helper = settings.localHelper
            helper.setTask(task, on: on)
            settings.localHelper = helper
        }.localHelper
    }

    // MARK: 1. Commit and pull request text

    /// What "Rewrite with local model" would send for an applied session. Sends nothing.
    public func localHelperPullRequestPreview(sessionID: UUID) async throws -> LocalHelperPreview {
        try await pullRequestHelperPreview(sessionID: sessionID, budget: LocalModelHelper.inputByteBudget(store.loadSettings().localModel))
    }

    /// Drafts the commit message and pull request title and description from the
    /// plan, the files, the recorded verification and the verified diff. Without a
    /// draft, the outcome says why; the caller keeps the proposed text.
    public func draftPullRequestTextWithLocalModel(
        sessionID: UUID,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> LocalHelperOutcome<PullRequestDraftText> {
        let session = try loadSession(sessionID)
        let record = LocalModelHelper.verificationRecord(label: session.verificationCommandLabel, passed: session.verificationPassed == true)
        return try await runLocalHelper(
            task: .commitText,
            sourceID: sessionID,
            maximumAnswerBytes: LocalModelHelper.maximumJSONAnswerBytes,
            cancellation: cancellation,
            makePreview: { budget in try await self.pullRequestHelperPreview(sessionID: sessionID, budget: budget) },
            parse: { try LocalModelHelper.parsePullRequestText($0, verificationRecord: record) }
        )
    }

    private func pullRequestHelperPreview(sessionID: UUID, budget: Int) async throws -> LocalHelperPreview {
        let session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        guard session.appliedBranchName != nil else {
            throw AgentBridgeError.invalidInput("Apply the verified changes to a local branch first.")
        }
        let diff = try await workspaceManager.applyWorktreeDiff(for: session)
        return try LocalModelHelper.pullRequestTextPreview(
            plan: session.changePlan.map { LocalModelHelper.PlanInput(title: $0.title, summary: $0.summary, steps: $0.steps) },
            diff: diff,
            verificationLabel: session.verificationCommandLabel,
            verificationPassed: session.verificationPassed == true,
            budget: budget
        )
    }

    // MARK: 2. Explain a failed verification

    /// What "Explain this failure" would send. `diff` is the diff on screen; without
    /// it the session's current diff is read for the file list.
    public func localHelperFailurePreview(
        sessionID: UUID,
        failure: LocalHelperVerificationFailure,
        diff: WorkspaceChangeDiff? = nil
    ) async throws -> LocalHelperPreview {
        try await failureHelperPreview(sessionID: sessionID, failure: failure, diff: diff, budget: LocalModelHelper.inputByteBudget(store.loadSettings().localModel))
    }

    /// A plain-language explanation and files to check. Shown in place, never saved.
    public func explainVerificationFailureWithLocalModel(
        sessionID: UUID,
        failure: LocalHelperVerificationFailure,
        diff: WorkspaceChangeDiff? = nil,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> LocalHelperOutcome<String> {
        _ = try loadSession(sessionID)
        return try await runLocalHelper(
            task: .explainFailure,
            sourceID: sessionID,
            maximumAnswerBytes: LocalModelHelper.maximumTextAnswerBytes,
            cancellation: cancellation,
            makePreview: { budget in try await self.failureHelperPreview(sessionID: sessionID, failure: failure, diff: diff, budget: budget) },
            parse: LocalModelHelper.parsePlainText
        )
    }

    private func failureHelperPreview(
        sessionID: UUID,
        failure: LocalHelperVerificationFailure,
        diff: WorkspaceChangeDiff?,
        budget: Int
    ) async throws -> LocalHelperPreview {
        let session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        let files: [ChangeFileDiff]
        if let diff { files = diff.files } else { files = try await changesDiff(sessionID: sessionID).files }
        return try LocalModelHelper.failureExplanationPreview(failure: failure, files: files, budget: budget)
    }

    // MARK: 3. Handoff summary

    /// What "Draft with local model" would send: the conversation's recent saved turns.
    public func localHelperHandoffPreview(sessionID: UUID) async throws -> LocalHelperPreview {
        try handoffHelperPreview(sessionID: sessionID, budget: LocalModelHelper.inputByteBudget(store.loadSettings().localModel))
    }

    /// Drafts the quick continuation's Done, Next and prompt fields.
    public func draftHandoffWithLocalModel(
        sessionID: UUID,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> LocalHelperOutcome<LocalHelperHandoffDraft> {
        _ = try loadSession(sessionID)
        return try await runLocalHelper(
            task: .handoffSummary,
            sourceID: sessionID,
            maximumAnswerBytes: LocalModelHelper.maximumJSONAnswerBytes,
            cancellation: cancellation,
            makePreview: { budget in try self.handoffHelperPreview(sessionID: sessionID, budget: budget) },
            parse: LocalModelHelper.parseHandoff
        )
    }

    private func handoffHelperPreview(sessionID: UUID, budget: Int) throws -> LocalHelperPreview {
        let session = try loadSession(sessionID)
        let turns = try sharedMemoryStore.snapshot(scope: memoryScope(for: session)).turns
        guard !turns.isEmpty else {
            throw AgentBridgeError.invalidInput("This conversation has no saved turns to summarize yet.")
        }
        let repositoryName = URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent
        return try LocalModelHelper.handoffPreview(turns: turns, repositoryName: repositoryName, budget: budget)
    }

    // MARK: 4. Summarize changes

    /// What "Summarize with local model" would send. `diff` is the diff on screen;
    /// without it the session's current diff is read.
    public func localHelperChangeSummaryPreview(sessionID: UUID, diff: WorkspaceChangeDiff? = nil) async throws -> LocalHelperPreview {
        try await changeSummaryHelperPreview(sessionID: sessionID, diff: diff, budget: LocalModelHelper.inputByteBudget(store.loadSettings().localModel))
    }

    /// The model's plain-language summary of the diff and things to check. It is
    /// an opinion, not a verification, and it is never saved.
    public func summarizeChangesWithLocalModel(
        sessionID: UUID,
        diff: WorkspaceChangeDiff? = nil,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> LocalHelperOutcome<String> {
        _ = try loadSession(sessionID)
        return try await runLocalHelper(
            task: .changeSummary,
            sourceID: sessionID,
            maximumAnswerBytes: LocalModelHelper.maximumTextAnswerBytes,
            cancellation: cancellation,
            makePreview: { budget in try await self.changeSummaryHelperPreview(sessionID: sessionID, diff: diff, budget: budget) },
            parse: LocalModelHelper.parsePlainText
        )
    }

    private func changeSummaryHelperPreview(sessionID: UUID, diff: WorkspaceChangeDiff?, budget: Int) async throws -> LocalHelperPreview {
        let session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        let current: WorkspaceChangeDiff
        if let diff { current = diff } else { current = try await changesDiff(sessionID: sessionID) }
        guard !current.files.isEmpty else {
            throw AgentBridgeError.invalidInput("There are no changes to summarize.")
        }
        return try LocalModelHelper.changeSummaryPreview(diff: current, budget: budget)
    }

    // MARK: Running a request

    /// One helper request: the switches, the input, the Local limits, the request
    /// and a strict read of the answer. Anything that stops it, other than
    /// cancellation, becomes the outcome's fallback reason; cancellation throws
    /// `processCancelled`.
    func runLocalHelper<Draft: Sendable & Equatable>(
        task: LocalHelperTask,
        sourceID: UUID,
        maximumAnswerBytes: Int,
        cancellation: CancellationFlag,
        makePreview: (Int) async throws -> LocalHelperPreview,
        parse: (String) throws -> Draft
    ) async throws -> LocalHelperOutcome<Draft> {
        func fallback(_ reason: String, preview: LocalHelperPreview? = nil, usage: LocalModelUsage? = nil) -> LocalHelperOutcome<Draft> {
            LocalHelperOutcome(draft: nil, fallbackReason: reason, preview: preview, usage: usage)
        }
        guard !cancellation.isCancelled else { throw AgentBridgeError.processCancelled }

        let settings: BridgeSettings
        do { settings = try store.loadSettings() }
        catch { return fallback(Self.notSentReason(error)) }
        guard settings.localHelper.enabled else {
            return fallback("The local model helper is off. Turn it on in Local model settings.")
        }
        guard settings.localHelper.isTaskOn(task) else {
            return fallback("This local model helper task is off. Turn it on in Local model settings.")
        }
        let local = settings.localModel
        guard !local.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback("Choose a local model in Local model settings first.")
        }

        let preview: LocalHelperPreview
        let profile: AccountProfile
        do {
            preview = try await makePreview(LocalModelHelper.inputByteBudget(local))
            profile = try accountProfileStore.selected(provider: .local)
            guard !cancellation.isCancelled else { throw AgentBridgeError.processCancelled }
            try authorizeLocalHelperRun(profile: profile, settings: local, sourceID: sourceID, task: task)
        } catch AgentBridgeError.processCancelled {
            throw AgentBridgeError.processCancelled
        } catch {
            return fallback(Self.notSentReason(error))
        }

        let truncatedFiles = preview.files.isEmpty ? "none" : "\(preview.sentFileCount)/\(preview.files.count)"
        try? store.appendEvent(AuditEvent(
            sessionID: sourceID,
            kind: "local_helper.started",
            message: "task=\(task.rawValue); account_profile_id=\(profile.id.uuidString.lowercased()); backend=\(local.backend.rawValue); prompt_bytes=\(preview.promptBytes); budget_bytes=\(preview.budgetBytes); diff_files_sent=\(truncatedFiles); truncated=\(preview.truncated). Prompt and answer text are not recorded."
        ))

        let response: LocalModelResponse
        do {
            response = try await localModelClient.generate(
                settings: local,
                prompt: preview.prompt,
                cancellationRequestURL: nil,
                cancellation: cancellation,
                maximumOutputBytes: maximumAnswerBytes,
                timeout: localHelperTimeout
            )
        } catch AgentBridgeError.processCancelled {
            recordHelperFailure(task: task, sourceID: sourceID, reason: "cancelled")
            throw AgentBridgeError.processCancelled
        } catch AgentBridgeError.processTimedOut {
            recordHelperFailure(task: task, sourceID: sourceID, reason: "timed_out")
            return fallback("The local model did not answer in time.", preview: preview)
        } catch {
            recordHelperFailure(task: task, sourceID: sourceID, reason: "request_failed")
            return fallback("The local model could not draft this: \(OutputRedactor.redact(error.localizedDescription))", preview: preview)
        }
        recordTokenUsage(TokenUsage(local: response.usage), runID: LocalModelHelper.usageStreamID, profileID: profile.id)

        let draft: Draft
        do {
            draft = try parse(response.text)
        } catch {
            recordHelperFailure(task: task, sourceID: sourceID, reason: "invalid_answer", answerBytes: response.text.utf8.count)
            return fallback("The local model's answer could not be used: \(error.localizedDescription)", preview: preview, usage: response.usage)
        }
        try? store.appendEvent(AuditEvent(
            sessionID: sourceID,
            kind: "local_helper.finished",
            message: "task=\(task.rawValue); answer_bytes=\(response.text.utf8.count); provider_input_tokens=\(response.usage.inputTokens.map(String.init) ?? "unavailable"); provider_output_tokens=\(response.usage.outputTokens.map(String.init) ?? "unavailable"). The draft was not applied or saved."
        ))
        return LocalHelperOutcome(draft: draft, fallbackReason: nil, preview: preview, usage: response.usage)
    }

    private func recordHelperFailure(task: LocalHelperTask, sourceID: UUID, reason: String, answerBytes: Int? = nil) {
        let bytes = answerBytes.map { "; answer_bytes=\($0)" } ?? ""
        try? store.appendEvent(AuditEvent(
            sessionID: sourceID,
            kind: "local_helper.failed",
            message: "task=\(task.rawValue); reason=\(reason)\(bytes). The existing text was kept."
        ))
    }

    private static func notSentReason(_ error: Error) -> String {
        "The local model request was not sent: \(OutputRedactor.redact(error.localizedDescription))"
    }
}
