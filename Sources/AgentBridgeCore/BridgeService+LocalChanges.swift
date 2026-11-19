import Foundation

extension BridgeService {
    /// Lists Local patch picker paths and inspects contents locally to mark
    /// non-UTF-8, NUL-containing or oversized files as unavailable. Contents are
    /// sent to the model only after the user selects them for an input preview/run.
    public func localChangeFileCandidates(sessionID: UUID) async throws -> [LocalChangeFileCandidate] {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        let session = try loadSession(sessionID)
        try requireLocalChangesSession(session)
        let paths = try await workspaceManager.localChangeCandidatePaths(for: session)
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true)
        return paths.map { LocalPatchWorkspace.candidate(path: $0, root: workspace) }
    }

    /// Produces the exact Local input byte counts without contacting the model.
    public func previewLocalChangeInput(
        sessionID: UUID,
        planID: UUID,
        reviewedDigest: String,
        request: String,
        filePaths: [String],
        newFilePaths: [String] = [],
        failure: LocalHelperVerificationFailure? = nil,
        note: String = ""
    ) async throws -> LocalChangeInputPreview {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        let session = try loadSession(sessionID)
        try requireLocalChangesSession(session)
        let plan = try requireApprovedPlan(session: session, planID: planID, reviewedDigest: reviewedDigest)
        let settings = try store.loadSettings().localModel
        let prepared = try await prepareLocalChangeInput(
            session: session,
            plan: plan,
            request: request,
            filePaths: filePaths,
            newFilePaths: newFilePaths,
            failure: failure,
            note: note,
            settings: settings,
            allowEmptyRequest: true
        )
        return prepared.preview
    }

    /// Runs an approved plan through the loopback Local model, then validates
    /// and applies the complete response inside the isolated workspace.
    public func runLocalChanges(
        sessionID: UUID,
        request: String,
        planID: UUID,
        reviewedDigest: String,
        filePaths: [String],
        newFilePaths: [String] = [],
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> LocalChangeRunResult {
        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateLocalChangeRequest(trimmedRequest)
        let lease = try await acquireProviderRunLease(for: sessionID, waitsForRunSlot: false, cancellation: cancellation)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireLocalChangesSession(session)
        let plan = try requireApprovedPlan(session: session, planID: planID, reviewedDigest: reviewedDigest)
        let settings = try store.loadSettings().localModel
        let prepared = try await prepareLocalChangeInput(
            session: session,
            plan: plan,
            request: trimmedRequest,
            filePaths: filePaths,
            newFilePaths: newFilePaths,
            failure: nil,
            note: "",
            settings: settings
        )
        guard prepared.preview.fitsBudget else {
            try appendLocalChangeEvent(
                sessionID: sessionID,
                kind: "local.change.rejected",
                fileCount: prepared.preview.files.count,
                inputBytes: prepared.preview.totalInputBytes,
                outputBytes: 0,
                detail: "reason=over_budget; over_budget_bytes=\(prepared.preview.overBudgetBytes)"
            )
            throw localChangeOverBudget(prepared.preview)
        }
        return try await executeLocalChange(
            session: &session,
            plan: plan,
            prepared: prepared,
            settings: settings,
            failureTailBytes: 0,
            cancellation: cancellation,
            onProgress: onProgress
        )
    }

    /// Fixes a failed Local verification. The failed output is supplied by the
    /// App's in-memory result or by the CLI, and is redacted and bounded here.
    public func fixLocalChanges(
        sessionID: UUID,
        failure: LocalHelperVerificationFailure,
        note: String = "",
        filePaths: [String] = [],
        newFilePaths: [String] = [],
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> LocalChangeRunResult {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedNote.utf8.count <= Self.maximumChangePlanRequestBytes, !trimmedNote.contains("\0") else {
            throw AgentBridgeError.invalidInput("The Local fix note must be text of up to 8,000 bytes.")
        }
        let lease = try await acquireProviderRunLease(for: sessionID, waitsForRunSlot: false, cancellation: cancellation)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireLocalChangesSession(session)
        guard session.verificationPassed == false,
              let lastChangeAt = session.lastChangeRunAt,
              let verificationAt = session.verificationCompletedAt,
              verificationAt >= lastChangeAt else {
            throw AgentBridgeError.invalidInput("A failed verification is required before fixing changes with Local.")
        }
        guard let plan = session.changePlan else { throw AgentBridgeError.changePlanRequired }
        guard session.approvedChangePlanDigest == plan.reviewDigest else { throw AgentBridgeError.changePlanRequired }
        try validateFailure(failure)
        let currentDiff = try await workspaceManager.diff(for: session)
        let changedExistingPaths = currentDiff.files.compactMap { file -> String? in
            guard file.status != .deleted else { return nil }
            return file.path
        }
        let selectedPaths = Array(Set(changedExistingPaths + filePaths)).sorted()
        let settings = try store.loadSettings().localModel
        let prepared = try await prepareLocalChangeInput(
            session: session,
            plan: plan,
            request: "",
            filePaths: selectedPaths,
            newFilePaths: newFilePaths,
            failure: failure,
            note: trimmedNote,
            settings: settings
        )
        guard prepared.preview.fitsBudget else {
            try appendLocalChangeEvent(
                sessionID: sessionID,
                kind: "local.change.rejected",
                fileCount: prepared.preview.files.count,
                inputBytes: prepared.preview.totalInputBytes,
                outputBytes: 0,
                detail: "reason=over_budget; over_budget_bytes=\(prepared.preview.overBudgetBytes)"
            )
            throw localChangeOverBudget(prepared.preview)
        }
        return try await executeLocalChange(
            session: &session,
            plan: plan,
            prepared: prepared,
            settings: settings,
            failureTailBytes: prepared.failureTailBytes,
            cancellation: cancellation,
            onProgress: onProgress
        )
    }

    private struct PreparedLocalChangeInput {
        let prompt: String
        let preview: LocalChangeInputPreview
        let fileContents: [String: String]
        let newFilePaths: Set<String>
        let failureTailBytes: Int
    }

    private func prepareLocalChangeInput(
        session: SessionRecord,
        plan: ChangePlan,
        request: String,
        filePaths: [String],
        newFilePaths: [String],
        failure: LocalHelperVerificationFailure?,
        note: String,
        settings: LocalModelSettings,
        allowEmptyRequest: Bool = false
    ) async throws -> PreparedLocalChangeInput {
        try LocalModelClient.validateSettings(settings)
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("Select a local model first.")
        }
        if failure == nil, !allowEmptyRequest || !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try validateLocalChangeRequest(request)
        }
        guard note.utf8.count <= Self.maximumChangePlanRequestBytes, !note.contains("\0") else {
            throw AgentBridgeError.invalidInput("The Local fix note must be text of up to 8,000 bytes.")
        }
        guard Set(filePaths).count == filePaths.count, Set(newFilePaths).count == newFilePaths.count else {
            let duplicatePaths = Self.duplicatePaths(filePaths + newFilePaths)
            throw LocalPatchApplicationError.rejectedPaths(duplicatePaths)
        }
        let allPaths = filePaths + newFilePaths
        guard Set(allPaths).count == allPaths.count else {
            throw LocalPatchApplicationError.rejectedPaths(Self.duplicatePaths(allPaths))
        }
        let sessionCandidates = Set(try await workspaceManager.localChangeCandidatePaths(for: session))
        let root = URL(fileURLWithPath: session.workspacePath, isDirectory: true)
        var fileContents: [String: String] = [:]
        var sizes: [LocalChangeInputFileSize] = []
        for path in filePaths {
            guard sessionCandidates.contains(path), LocalPatchWorkspace.isNormalizedRelativePath(path) else {
                throw LocalPatchApplicationError.rejectedPaths([path])
            }
            let (content, _) = try LocalPatchWorkspace.readText(path: path, root: root)
            fileContents[path] = content
            sizes.append(LocalChangeInputFileSize(path: path, byteCount: content.utf8.count))
        }
        var newPathSet = Set<String>()
        for path in newFilePaths {
            guard LocalPatchWorkspace.isNormalizedRelativePath(path) else {
                throw LocalPatchApplicationError.rejectedPaths([path])
            }
            try LocalPatchWorkspace.validateAbsent(path: path, root: root)
            newPathSet.insert(path)
        }

        let failureTail = failure.map(Self.boundedFailureTail) ?? ""
        let prompt = try Self.localChangePrompt(
            plan: plan,
            request: request,
            fileContents: fileContents,
            newFilePaths: newFilePaths,
            failure: failure,
            failureTail: failureTail,
            note: note
        )
        let budget = try LocalModelHelper.inputByteBudget(settings)
        return PreparedLocalChangeInput(
            prompt: prompt,
            preview: LocalChangeInputPreview(files: sizes.sorted { $0.path < $1.path }, totalInputBytes: prompt.utf8.count, budgetBytes: budget),
            fileContents: fileContents,
            newFilePaths: newPathSet,
            failureTailBytes: failureTail.utf8.count
        )
    }

    private func executeLocalChange(
        session: inout SessionRecord,
        plan: ChangePlan,
        prepared: PreparedLocalChangeInput,
        settings: LocalModelSettings,
        failureTailBytes: Int,
        cancellation: CancellationFlag,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> LocalChangeRunResult {
        let profile = try requireBoundProfile(for: session, allowUnselected: false)
        guard profile.provider == .local else { throw AccountProfileError.providerMismatch(profile.id, .local) }
        try authorizeLocalModelRun(runID: session.id, profile: profile, settings: settings)
        _ = store.consumeCancellationRequest(for: session.id)
        let taskID = try beginTrackedRun(
            sessionID: session.id,
            summary: "Approved Local change plan is running.",
            approvedChange: true
        )
        session.status = .running
        session.approvedChangePlanDigest = nil
        session.approvedChangePlanMemoryDigest = nil
        session.lastChangeRunAt = Date()
        session.verificationPassed = nil
        session.verificationDiffDigest = nil
        session.verificationCompletedAt = nil
        session.changesAcceptedAt = nil
        session.updatedAt = Date()
        do {
            try store.saveSession(session)
            try appendLocalChangeEvent(
                sessionID: session.id,
                kind: "local.change.started",
                fileCount: prepared.preview.files.count,
                inputBytes: prepared.preview.totalInputBytes,
                outputBytes: 0,
                detail: "new_file_count=\(prepared.newFilePaths.count); failure_tail_bytes=\(failureTailBytes); budget_bytes=\(prepared.preview.budgetBytes)"
            )
            let response = try await localModelClient.generate(
                settings: settings,
                prompt: prepared.prompt,
                cancellationRequestURL: store.cancellationRequestURL(for: session.id),
                cancellation: cancellation,
                maximumOutputBytes: LocalPatchResponseParser.maximumResponseBytes,
                timeout: localHelperTimeout,
                redactResponse: false,
                onProgress: onProgress
            )
            recordTokenUsage(TokenUsage(local: response.usage), runID: session.id, profileID: profile.id)
            let parsed: LocalPatchResponse
            do {
                parsed = try LocalPatchResponseParser.parse(response.text)
            } catch {
                try? appendLocalChangeEvent(
                    sessionID: session.id,
                    kind: "local.change.rejected",
                    fileCount: prepared.preview.files.count,
                    inputBytes: prepared.preview.totalInputBytes,
                    outputBytes: response.text.utf8.count,
                    detail: "reason=invalid_response"
                )
                throw error
            }

            let selected = Set(prepared.fileContents.keys)
            do {
                try LocalPatchWorkspace.writeAll(
                    parsed.files,
                    selectedPaths: selected,
                    newPaths: prepared.newFilePaths,
                    expectedFileContents: prepared.fileContents.mapValues { Data($0.utf8) },
                    root: URL(fileURLWithPath: session.workspacePath, isDirectory: true)
                )
            } catch let error as LocalPatchApplicationError {
                try? appendLocalChangeEvent(
                    sessionID: session.id,
                    kind: "local.change.rejected",
                    fileCount: prepared.preview.files.count,
                    inputBytes: prepared.preview.totalInputBytes,
                    outputBytes: response.text.utf8.count,
                    detail: "reason=path_or_write_validation; response_file_count=\(parsed.files.count)"
                )
                throw error
            }

            session.status = .completed
            session.updatedAt = Date()
            try store.saveSession(session)
            let totalFileBytes = parsed.files.reduce(0) { $0 + ($1.content?.utf8.count ?? 0) }
            try appendLocalChangeEvent(
                sessionID: session.id,
                kind: "local.change.applied",
                fileCount: parsed.files.count,
                inputBytes: prepared.preview.totalInputBytes,
                outputBytes: response.text.utf8.count,
                detail: "content_bytes=\(totalFileBytes); summary_bytes=\(parsed.summary.utf8.count)"
            )
            let diff = try await workspaceManager.diff(for: session)
            try? finishTrackedRun(
                taskID: taskID,
                status: .completed,
                summary: "Local change response was validated and applied; the diff is ready for review.",
                reference: try? ParallelTaskReference(kind: .diff, value: "sha256:\(diff.digest)")
            )
            return LocalChangeRunResult(
                summary: parsed.summary,
                changedPaths: parsed.files.map(\.path),
                inputBytes: prepared.preview.totalInputBytes,
                outputBytes: response.text.utf8.count
            )
        } catch {
            session.status = (error as? AgentBridgeError) == .processCancelled ? .cancelled : .failed
            session.updatedAt = Date()
            try? store.saveSession(session)
            try? appendLocalChangeEvent(
                sessionID: session.id,
                kind: "local.change.failed",
                fileCount: prepared.preview.files.count,
                inputBytes: prepared.preview.totalInputBytes,
                outputBytes: 0,
                detail: "cancelled=\((error as? AgentBridgeError) == .processCancelled); failure_tail_bytes=\(failureTailBytes)"
            )
            try? finishTrackedRun(
                taskID: taskID,
                status: session.status == .cancelled ? .cancelled : .failed,
                summary: session.status == .cancelled ? "Local change generation was cancelled." : "Local change generation did not complete."
            )
            throw error
        }
    }

    private func requireLocalChangesSession(_ session: SessionRecord) throws {
        guard session.provider == .local else {
            throw AgentBridgeError.sessionMismatch("This Local patch operation requires a Local model session.")
        }
        try requireIsolatedChangesSession(session)
        try awaitWorkspaceValidation(session)
    }

    private func awaitWorkspaceValidation(_ session: SessionRecord) throws {
        // The caller performs the asynchronous workspace check before reading or
        // writing. This synchronous guard keeps provider/access mistakes explicit.
        guard session.policy.accessMode == .isolatedChanges, !session.policy.workspaceReadOnly else {
            throw AgentBridgeError.sessionMismatch("Create an isolated-change session; read-only and native interactive sessions do not run this operation.")
        }
    }

    private func validateLocalChangeRequest(_ request: String) throws {
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("Enter the change request for the Local model.")
        }
        guard request.utf8.count <= Self.maximumChangePlanRequestBytes, !request.contains("\0") else {
            throw AgentBridgeError.invalidInput("The Local change request must be text of up to 8,000 bytes.")
        }
    }

    private static func duplicatePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return Array(Set(paths.filter { !seen.insert($0).inserted })).sorted()
    }

    private static func boundedFailureTail(_ failure: LocalHelperVerificationFailure) -> String {
        let redacted = OutputRedactor.redact(failure.output)
        let data = Data(redacted.utf8)
        let tail = data.suffix(LocalModelHelper.maximumOutputTailBytes)
        return String(decoding: tail, as: UTF8.self)
    }

    private func validateFailure(_ failure: LocalHelperVerificationFailure) throws {
        guard !failure.commandLabel.isEmpty, failure.commandLabel.utf8.count <= 2_048,
              failure.output.utf8.count <= 2 * 1_024 * 1_024 else {
            throw AgentBridgeError.invalidInput("Verification output must be text no longer than 2 MiB, with a short command label.")
        }
    }

    private func localChangeOverBudget(_ preview: LocalChangeInputPreview) -> AgentBridgeError {
        .invalidInput("The Local model input is over budget by \(preview.overBudgetBytes) bytes (total \(preview.totalInputBytes); budget \(preview.budgetBytes)).")
    }

    private func appendLocalChangeEvent(
        sessionID: UUID,
        kind: String,
        fileCount: Int,
        inputBytes: Int,
        outputBytes: Int,
        detail: String
    ) throws {
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: kind,
            message: "file_count=\(fileCount); input_bytes=\(inputBytes); output_bytes=\(outputBytes); \(detail). Prompt, file contents and model content are not recorded."
        ))
    }

    private static func localChangePrompt(
        plan: ChangePlan,
        request: String,
        fileContents: [String: String],
        newFilePaths: [String],
        failure: LocalHelperVerificationFailure?,
        failureTail: String,
        note: String
    ) throws -> String {
        let planValue: [String: Any] = ["title": plan.title, "summary": plan.summary, "steps": plan.steps]
        let fileValues = fileContents.keys.sorted().map { ["path": $0, "content": fileContents[$0]!] }
        let fileJSON = try compactJSON(fileValues)
        let newFileJSON = try compactJSON(newFilePaths.sorted())
        let noteJSON = try compactJSON(note)
        let planJSON = try compactJSON(planValue)
        let requestJSON = try compactJSON(request)
        let failureJSON: String
        if let failure {
            failureJSON = try compactJSON([
                "command": OutputRedactor.redact(failure.commandLabel),
                "exitCode": failure.exitCode.map { String($0) } ?? "not reported",
                "outputTail": failureTail
            ])
        } else {
            failureJSON = ""
        }
        let instruction = localChangeInstruction
        if failure != nil {
            return """
            \(instruction)

            APPROVED PLAN (JSON)
            \(planJSON)

            FAILED VERIFICATION (JSON; redacted output tail)
            \(failureJSON)

            CURRENT SELECTED FILES (JSON; complete UTF-8 contents)
            \(fileJSON)

            NEW FILE PATHS THE USER ALLOWS (JSON)
            \(newFileJSON)

            OPTIONAL USER NOTE (JSON string)
            \(noteJSON)
            """
        }
        return """
        \(instruction)

        APPROVED PLAN (JSON)
        \(planJSON)

        USER REQUEST (JSON string)
        \(requestJSON)

        FILES SELECTED BY THE USER (JSON; complete UTF-8 contents)
        \(fileJSON)

        NEW FILE PATHS THE USER ALLOWS (JSON)
        \(newFileJSON)
        """
    }

    private static let localChangeInstruction = """
    Implement the user request using the approved plan and the supplied file contents.
    Return only one JSON object with no surrounding prose or markdown code fence, matching this schema exactly:
    {"summary":"what changed","files":[{"path":"relative/path","action":"modify|create|delete","content":"full new file content"}]}
    Each file entry must contain only path, action and content. For modify and create, content is the complete new UTF-8 file content. For delete, omit content or set it to null. Do not return diffs.
    """

    private static func localPlanDraftPrompt(request: String, filePaths: [String]) throws -> String {
        let requestJSON = try compactJSON(request)
        let pathsJSON = try compactJSON(filePaths)
        return """
        Draft an isolated-change plan for the user to review, based on the request and listed workspace file paths.
        Return only one JSON object, with no surrounding prose or markdown code fence, matching this exact schema:
        {"title":"short plan title","summary":"what will change and why","steps":["one specific, bounded edit"]}

        USER REQUEST (JSON string)
        \(requestJSON)

        TRACKED AND NON-IGNORED UNTRACKED WORKSPACE FILE PATHS (JSON; paths only)
        \(pathsJSON)
        """
    }

    private static func compactJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentBridgeError.invalidInput("Could not prepare the Local model request as UTF-8 text.")
        }
        return string
    }

    func draftLocalChangePlan(
        sessionID: UUID,
        request: String,
        cancellation: CancellationFlag,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> DraftedChangePlan {
        let lease = try await acquireProviderRunLease(for: sessionID, waitsForRunSlot: false, cancellation: cancellation)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireLocalChangesSession(session)
        try validateLocalChangeRequest(request)
        let settings = try store.loadSettings().localModel
        try LocalModelClient.validateSettings(settings)
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("Select a local model first.")
        }
        try await workspaceManager.validateWorkspace(for: session, accessMode: .isolatedChanges)
        let paths = try await workspaceManager.localChangeCandidatePaths(for: session)
        let prompt = try Self.localPlanDraftPrompt(request: request, filePaths: paths)
        let budget = try LocalModelHelper.inputByteBudget(settings)
        guard prompt.utf8.count <= budget else {
            throw AgentBridgeError.invalidInput("The Local model plan request is over budget by \(prompt.utf8.count - budget) bytes (total \(prompt.utf8.count); budget \(budget)).")
        }
        let profile = try requireBoundProfile(for: session, allowUnselected: false)
        try authorizeLocalModelRun(runID: sessionID, profile: profile, settings: settings)
        _ = store.consumeCancellationRequest(for: sessionID)
        let taskID = try beginTrackedRun(sessionID: sessionID, summary: "Local model is drafting a change plan.")
        session.status = .running
        session.updatedAt = Date()
        do {
            try store.saveSession(session)
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "change_plan.draft_started",
                message: "Started a Local plan draft using \(paths.count) workspace file path(s); prompt_bytes=\(prompt.utf8.count); budget_bytes=\(budget). Paths only; no file content, shared memory or model content is recorded."
            ))
            let response = try await localModelClient.generate(
                settings: settings,
                prompt: prompt,
                cancellationRequestURL: store.cancellationRequestURL(for: sessionID),
                cancellation: cancellation,
                maximumOutputBytes: LocalModelHelper.maximumJSONAnswerBytes,
                timeout: localHelperTimeout,
                onProgress: onProgress
            )
            recordTokenUsage(TokenUsage(local: response.usage), runID: sessionID, profileID: profile.id)
            let draft = try ChangePlanDraftParser.parse(response.text)
            session.status = .completed
            session.updatedAt = Date()
            try store.saveSession(session)
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "change_plan.drafted",
                message: "Drafted a Local change plan with \(draft.steps.count) step(s), prompt_bytes=\(prompt.utf8.count), answer_bytes=\(response.text.utf8.count). The draft was not saved or approved."
            ))
            try? finishTrackedRun(taskID: taskID, status: .completed, summary: "Drafted a Local change plan; nothing was saved or approved.")
            return draft
        } catch {
            session.status = (error as? AgentBridgeError) == .processCancelled ? .cancelled : .failed
            session.updatedAt = Date()
            try? store.saveSession(session)
            try? store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: session.status == .cancelled ? "change_plan.draft_cancelled" : "change_plan.draft_failed",
                message: "Local plan draft ended; prompt_bytes=\(prompt.utf8.count); budget_bytes=\(budget); answer content is not recorded."
            ))
            try? finishTrackedRun(
                taskID: taskID,
                status: session.status == .cancelled ? .cancelled : .failed,
                summary: session.status == .cancelled ? "Local plan drafting was cancelled." : "Local plan drafting did not complete."
            )
            throw error
        }
    }
}
