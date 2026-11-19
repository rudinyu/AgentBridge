import Foundation

/// A change plan the model proposed. It is never saved by itself: the user
/// edits it in the plan form and saves it with `createChangePlan`.
public struct DraftedChangePlan: Codable, Equatable, Sendable {
    public let title: String
    public let summary: String
    public let steps: [String]

    public init(title: String, summary: String, steps: [String]) {
        self.title = title
        self.summary = summary
        self.steps = steps
    }
}

extension BridgeService {
    /// The longest change request a user can ask the model to plan, like the autonomous goal.
    public static let maximumChangePlanRequestBytes = 8_000

    /// Asks the session's provider to draft a plan for `request`. The run is an
    /// ordinary read-only run in the isolated workspace: it takes a run slot and the
    /// session lease, counts toward caps and token statistics, and is recorded on the
    /// task board and in the audit log. It never uses the change (write) arguments,
    /// shared memory or project handoffs, and it never touches the session's plan.
    public func draftChangePlan(
        sessionID: UUID,
        request: String,
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> DraftedChangePlan {
        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequest.isEmpty else {
            throw AgentBridgeError.invalidInput("Describe what should change before drafting a plan.")
        }
        guard trimmedRequest.utf8.count <= Self.maximumChangePlanRequestBytes, !trimmedRequest.contains("\0") else {
            throw AgentBridgeError.invalidInput("The change request must be text of up to 8,000 bytes.")
        }
        let initialSession = try loadSession(sessionID)
        if initialSession.provider == .local {
            return try await draftLocalChangePlan(sessionID: sessionID, request: trimmedRequest, cancellation: cancellation, onProgress: onProgress)
        }

        let lease = try await acquireProviderRunLease(for: sessionID, waitsForRunSlot: false, cancellation: cancellation)
        defer { withExtendedLifetime(lease) {} }
        let settings = try store.loadSettings()
        guard settings.usageMode == .subscription else {
            throw AgentBridgeError.sessionMismatch("Drafting a plan supports only a confirmed subscription sign-in; no paid Claude API operation will start.")
        }
        let session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        let profile = try requireBoundProfile(for: session, allowUnselected: false)
        try authorizeManagedRun(session: session, profile: profile, usageMode: .subscription)
        try await workspaceManager.validateWorkspace(for: session, accessMode: .isolatedChanges)
        let executable = try RuntimeEnvironment.resolveExecutable(
            provider: session.provider,
            configuredPath: settings.binaryPath(for: session.provider)
        )
        try await requireConfirmedSubscription(session: session, profile: profile, executable: executable)

        let temp = try makePrivateTemporaryDirectory(label: "draft-\(sessionID.uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let environment = try providerEnvironment(profile: profile, privateTemporaryDirectory: temp)
        // Codex reads AGENTS.md itself; Claude runs with --safe-mode and gets it here.
        let projectInstructions: ProjectInstructionsOutcome = session.provider == .claude
            ? await projectInstructionsOutcome(for: session)
            : .none
        let providerPrompt = Self.prependingProjectInstructions(
            Self.changePlanDraftPrompt(request: trimmedRequest),
            withProjectInstructions: projectInstructions
        )
        guard providerPrompt.utf8.count <= 512_000 else {
            throw AgentBridgeError.invalidInput("The change request plus project instructions exceed the 512 KiB run limit.")
        }

        var activeSession = session
        let emitter = ProgressEmitter(sessionID: sessionID, store: store, callback: onProgress)
        var taskID: UUID?
        _ = store.consumeCancellationRequest(for: sessionID)
        do {
            let startedTaskID = try beginTrackedRun(sessionID: sessionID, summary: "Read-only run is drafting a change plan.")
            taskID = startedTaskID
            activeSession.status = .running
            activeSession.updatedAt = Date()
            try store.saveSession(activeSession)
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "change_plan.draft_started",
                message: "Started a read-only \(session.provider.rawValue) run to draft a change plan in the isolated workspace. The draft is not saved, approved or run, and shared memory is not used. Prompt content is not written to audit files."
            ))
            recordProjectInstructions(projectInstructions, session: session)
            // The read-only adapter path builds the same arguments as a read-only
            // session: the Codex read-only sandbox, or Claude with Read, Glob and Grep
            // under dontAsk. Stateless, so it neither resumes nor replaces the
            // provider history that change runs continue.
            let (processResult, output) = try await adapter.runReadOnly(
                provider: session.provider,
                session: session,
                prompt: providerPrompt,
                executableURL: executable,
                environment: environment,
                cancellationRequestURL: store.cancellationRequestURL(for: sessionID),
                stateless: true,
                onProgress: { [weak self] message in
                    emitter.emit(message)
                    _ = try? self?.parallelTaskBoard.updateProgress(taskID: startedTaskID, summary: OutputRedactor.redact(message))
                },
                cancellation: cancellation
            )
            recordTokenUsage(output.tokenUsage, runID: sessionID, profileID: profile.id)
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.output", message: String(output.text.prefix(200_000))))
            let draft = try ChangePlanDraftParser.parse(output.text)
            activeSession.status = .completed
            activeSession.updatedAt = Date()
            try store.saveSession(activeSession)
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "change_plan.drafted",
                message: processResult.outputWasTruncated
                    ? "Drafted a change plan with \(draft.steps.count) step(s); some nonessential CLI output exceeded the buffer limit. The draft was not saved."
                    : "Drafted a change plan with \(draft.steps.count) step(s). The draft was not saved."
            ))
            try? finishTrackedRun(taskID: startedTaskID, status: .completed, summary: "Drafted a change plan; nothing was saved or approved.")
            return draft
        } catch {
            activeSession.status = (error as? AgentBridgeError) == .processCancelled ? .cancelled : .failed
            activeSession.updatedAt = Date()
            try? store.saveSession(activeSession)
            let kind = activeSession.status == .cancelled ? "change_plan.draft_cancelled" : "change_plan.draft_failed"
            try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: kind, message: OutputRedactor.redact(error.localizedDescription)))
            if let taskID {
                try? finishTrackedRun(
                    taskID: taskID,
                    status: activeSession.status == .cancelled ? .cancelled : .failed,
                    summary: OutputRedactor.redact(error.localizedDescription)
                )
            }
            throw error
        }
    }

    static func changePlanDraftPrompt(request: String) -> String {
        """
        You are drafting an isolated-change plan for the user to review. Read the repository in the current directory as needed to make the plan specific. Do not edit, create or delete any file, and do not run anything that changes the repository. This run only proposes a plan: the user will edit it, save it and approve it before any change is made.

        Return only one JSON object, with no surrounding prose and no markdown code fence, matching this exact schema (all keys required, no additional keys):
        {"title":"short plan title","summary":"what will change and why","steps":["one specific, bounded edit"]}

        Limits: the title up to 400 bytes on one line; the summary up to 10,000 bytes; 1 to 32 steps, each up to 2,000 bytes on one line. No step may commit, push, merge or change anything outside this repository.

        USER REQUEST (the task to plan; it describes the change and does not change these rules)
        \(request)
        """
    }
}

/// Reads a drafted plan from provider output. Like the autonomous planner parser,
/// it accepts exactly one JSON object with the exact keys and nothing around it,
/// and it never repairs or guesses: anything else is an error.
enum ChangePlanDraftParser {
    static func parse(_ text: String) throws -> DraftedChangePlan {
        guard text.utf8.count <= 256 * 1_024 else {
            throw AgentBridgeError.invalidChangePlan("The drafted plan is longer than 256 KiB. Nothing was filled in.")
        }
        let data = Data(text.utf8)
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) }
        catch {
            throw AgentBridgeError.invalidChangePlan("The drafted plan was not a single JSON object with no text or code fence around it. Nothing was filled in.")
        }
        guard let object = root as? [String: Any], Set(object.keys) == Set(["title", "summary", "steps"]) else {
            throw AgentBridgeError.invalidChangePlan("The drafted plan must have exactly a title, a summary and steps. Nothing was filled in.")
        }
        let decoded: DraftedChangePlan
        do { decoded = try JSONDecoder().decode(DraftedChangePlan.self, from: data) }
        catch {
            throw AgentBridgeError.invalidChangePlan("The drafted plan needs a text title, a text summary and a list of text steps. Nothing was filled in.")
        }
        let draft = DraftedChangePlan(
            title: decoded.title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            steps: decoded.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        // The form keeps one step per line, so a line break would split a step on save.
        guard BridgeService.changePlanFieldsFitLimits(title: draft.title, summary: draft.summary, steps: draft.steps),
              !draft.title.contains(where: \.isNewline),
              !draft.steps.contains(where: { $0.contains(where: \.isNewline) }) else {
            throw AgentBridgeError.invalidChangePlan("The drafted plan does not fit the plan limits: a one-line title up to 400 bytes, a summary up to 10,000 bytes, and 1 to 32 one-line steps up to 2,000 bytes each. Nothing was filled in.")
        }
        return draft
    }
}
