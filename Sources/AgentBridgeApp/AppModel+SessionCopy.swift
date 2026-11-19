import AgentBridgeCore
import Foundation

/// What "New Session Like This" will create, while the user edits it.
struct SessionCopyDraft: Identifiable, Equatable {
    let sourceSessionID: UUID
    let provider: AgentProvider
    let accessMode: AccessMode
    let sourceCommit: String
    var modelChoice: ProviderModelChoice
    var accountProfileID: UUID?
    var commit: SessionCommitChoice

    var id: UUID { sourceSessionID }

    /// Starts from the source's model, effort, account and commit.
    init(source: SessionRecord, fallbackAccountProfileID: UUID? = nil) {
        sourceSessionID = source.id
        provider = source.provider
        accessMode = source.policy.accessMode
        sourceCommit = source.snapshotCommit
        modelChoice = source.modelChoice
        accountProfileID = source.accountProfileID ?? fallbackAccountProfileID
        commit = .sameAsSource
    }

    /// The model choice to send: nil for local sessions, which have none.
    var requestedModelChoice: ProviderModelChoice? {
        ProviderModelOptions.supportsModelChoice(provider) ? modelChoice : nil
    }
}

/// Text and decisions for "New Session Like This", kept apart from the view so
/// tests can check them.
enum SessionCopyPresentation {
    static let sameCommitFormat = "Same commit (%@)"
    static let sourceHeadLabel = "Current HEAD of the source repository"
    static let notCopiedNote = "Approvals, verification results, changes and enabled extensions are not copied. A copied change plan must be approved again."

    /// "Try Another Model…" is offered only where a model can be chosen.
    static func canTryAnotherModel(_ session: SessionRecord) -> Bool {
        ProviderModelOptions.supportsModelChoice(session.provider)
    }

    /// The text for the new session's composer: the source's most recent prompt,
    /// for a read-only conversation only, or nil when there is none to offer.
    /// It is only placed in the composer, never sent.
    static func composerPrefill(source: SessionRecord, newSession: SessionRecord, recentPrompts: [UUID: String]) -> String? {
        guard source.policy.accessMode == .readOnly, newSession.policy.accessMode == .readOnly,
              let prompt = recentPrompts[source.id],
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return prompt
    }
}

extension AppModel {
    /// Opens the "New Session Like This" sheet for `sessionID`.
    func reviewNewSessionLike(_ sessionID: UUID) {
        guard let source = sessions.first(where: { $0.id == sessionID }) else {
            errorMessage = localized("The session could not be found.")
            return
        }
        sessionCopyDraft = SessionCopyDraft(source: source, fallbackAccountProfileID: selectedProfileIDs[source.provider])
    }

    func cancelNewSessionLike() {
        sessionCopyDraft = nil
    }

    /// The failed run the error alert is about, if the alert shows its error, so
    /// the alert can offer another model for that session.
    var sessionForTryAnotherModel: SessionRecord? {
        guard let failure = lastRunFailure, failure.message == errorMessage,
              let session = sessions.first(where: { $0.id == failure.sessionID }),
              SessionCopyPresentation.canTryAnotherModel(session) else { return nil }
        return session
    }

    /// Records a run the provider CLI failed, such as one whose model it
    /// rejected, so the error alert can offer another model. Other errors, such
    /// as a limit or a cancellation, are not about the model.
    func noteRunFailure(sessionID: UUID, error: Error) {
        guard case AgentBridgeError.providerFailed = error else {
            lastRunFailure = nil
            return
        }
        lastRunFailure = (sessionID, error.localizedDescription)
    }

    /// Creates the session the draft describes and opens it. A read-only
    /// conversation gets the source's last prompt in its composer, unsent.
    func createSessionFromCopyDraft(onCreated: @escaping @MainActor (UUID) -> Void) {
        guard let service, let draft = sessionCopyDraft, !isCreatingSessionCopy else { return }
        isCreatingSessionCopy = true
        status = "Creating an isolated workspace for the pinned commit…"
        let recentPrompts = recentProjectPrompts
        Task { @MainActor in
            defer { isCreatingSessionCopy = false }
            do {
                let result = try await service.createSession(
                    like: draft.sourceSessionID,
                    modelChoice: draft.requestedModelChoice,
                    accountProfileID: draft.accountProfileID,
                    commit: draft.commit
                )
                sessionCopyDraft = nil
                status = result.copiedChangePlan != nil
                    ? "Session created. Copied the change plan; approve it again before running."
                    : "Session created."
                refresh()
                if let source = try? service.sessionCopySource(draft.sourceSessionID),
                   result.session.policy.accessMode == .readOnly {
                    prompt = SessionCopyPresentation.composerPrefill(
                        source: source,
                        newSession: result.session,
                        recentPrompts: recentPrompts
                    ) ?? ""
                    isReviewingProviderHandoffPrompt = false
                }
                onCreated(result.session.id)
                if let planError = result.changePlanCopyError {
                    errorMessage = planError
                }
            } catch {
                errorMessage = error.localizedDescription
                status = "Could not create the session."
            }
        }
    }
}
