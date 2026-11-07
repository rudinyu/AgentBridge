import Darwin
import Foundation

extension BridgeService {
    public func createChangePlan(
        sessionID: UUID,
        title: String,
        summary: String,
        steps: [String],
        includesSharedMemory: Bool = false
    ) throws -> ChangePlan {
        let initialSession = try loadSession(sessionID)
        guard initialSession.provider != .local else {
            throw AgentBridgeError.sessionMismatch("Local models do not support isolated changes or work plans yet.")
        }
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSteps = steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmedTitle.isEmpty, trimmedTitle.utf8.count <= 400,
              !trimmedSummary.isEmpty, trimmedSummary.utf8.count <= 10_000,
              (1...32).contains(trimmedSteps.count),
              trimmedSteps.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_000 && !$0.contains("\0") }),
              !trimmedTitle.contains("\0"), !trimmedSummary.contains("\0") else {
            throw AgentBridgeError.invalidChangePlan("The title, summary and 1 to 32 steps must all have content and fit the size limits.")
        }
        if includesSharedMemory {
            let profile = try requireBoundProfile(for: session, allowUnselected: true)
            guard profile.allowsSharedMemory else {
                throw AgentBridgeError.invalidChangePlan("This account does not allow shared memory, so the plan cannot include it.")
            }
        }
        let plan = ChangePlan(
            sessionID: sessionID,
            title: trimmedTitle,
            summary: trimmedSummary,
            steps: trimmedSteps,
            includesSharedMemory: includesSharedMemory
        )
        session.changePlan = plan
        session.approvedChangePlanDigest = nil
        session.approvedChangePlanMemoryDigest = nil
        session.verificationPassed = nil
        session.verificationDiffDigest = nil
        session.verificationCompletedAt = nil
        session.changesAcceptedAt = nil
        session.updatedAt = Date()
        try store.saveSession(session)
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "change.plan.created",
            message: plan.includesSharedMemory
                ? "Created a change plan awaiting review that includes shared memory (summary hash \(plan.reviewDigest), \(plan.steps.count) steps); file writes are not authorized yet."
                : "Created a change plan awaiting review (summary hash \(plan.reviewDigest), \(plan.steps.count) steps); file writes are not authorized yet."
        ))
        return plan
    }

    @discardableResult
    public func approveChangePlan(sessionID: UUID, planID: UUID, reviewedDigest: String) throws -> ChangePlan {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        guard let plan = session.changePlan, plan.sessionID == sessionID, plan.id == planID,
              plan.reviewDigest == reviewedDigest.lowercased() else {
            throw AgentBridgeError.invalidChangePlan("The plan content changed or the review identifier does not match; review the current plan again.")
        }
        // Approval covers the memory as it is now. A later run, or a sync, can change it.
        let memoryDigest = plan.includesSharedMemory
            ? try changeRunMemoryDigest(session: session, profile: requireBoundProfile(for: session, allowUnselected: true))
            : nil
        if plan.includesSharedMemory, memoryDigest == nil {
            throw AgentBridgeError.invalidChangePlan("The plan includes shared memory, but this account does not allow it or there is none for this commit. Save the plan without memory.")
        }
        session.approvedChangePlanDigest = plan.reviewDigest
        session.approvedChangePlanMemoryDigest = memoryDigest
        session.updatedAt = Date()
        try store.saveSession(session)
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "change.plan.approved",
            message: memoryDigest.map {
                "The user explicitly reviewed and approved the change plan (summary hash \(plan.reviewDigest)) with shared memory sha256:\($0)."
            } ?? "The user explicitly reviewed and approved the change plan (summary hash \(plan.reviewDigest))."
        ))
        return plan
    }

    public func changesDiff(sessionID: UUID) async throws -> WorkspaceChangeDiff {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        let session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        return try await workspaceManager.diff(for: session)
    }

    public func restoreChangeFiles(sessionID: UUID, filePaths: [String]) async throws {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        try await workspaceManager.restoreFiles(for: session, paths: filePaths)
        clearChangeAcceptanceState(&session)
        session.updatedAt = Date()
        try store.saveSession(session)
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "change.files.restored",
            message: "Restored \(filePaths.count) user-selected files in the isolated workspace; the source repository was not changed."
        ))
    }

    public func restoreAllChanges(sessionID: UUID) async throws {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        try await workspaceManager.restoreAllChanges(for: session)
        clearChangeAcceptanceState(&session)
        session.updatedAt = Date()
        try store.saveSession(session)
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "change.workspace.restored",
            message: "Restored the whole isolated workspace to the base commit; the source repository was not changed."
        ))
    }

    public func exportChangePatch(sessionID: UUID) async throws -> Data {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        let session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        let diff = try await workspaceManager.diff(for: session)
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "change.patch.exported",
            message: "Exported a patch for \(diff.files.count) files (\(diff.patch.count) bytes); the source repository was not modified."
        ))
        return diff.patch
    }

    @discardableResult
    public func acceptChanges(sessionID: UUID, partiallyShownFilesConfirmedDigest: String? = nil) async throws -> SessionRecord {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        try requireSuccessfulChangeVerification(session)
        let diff = try await workspaceManager.diff(for: session)
        try requireSuccessfulChangeVerification(session, diff: diff)
        guard !diff.files.isEmpty else { throw AgentBridgeError.invalidInput("The workspace has no changes to accept.") }
        try requirePartiallyShownFilesConfirmed(diff, confirmedDigest: partiallyShownFilesConfirmedDigest, sessionID: sessionID)
        session.changesAcceptedAt = Date()
        session.updatedAt = Date()
        try store.saveSession(session)
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "change.accepted",
            message: "The user accepted verified isolated changes covering \(diff.files.count) files; the source repository is still unmodified."
        ))
        return session
    }

    @discardableResult
    public func applyChangesToLocalBranch(
        sessionID: UUID,
        branchName: String,
        partiallyShownFilesConfirmedDigest: String? = nil
    ) async throws -> BranchApplyResult {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        try requireSuccessfulChangeVerification(session)
        do {
            let currentDiff = try await workspaceManager.diff(for: session)
            try requireSuccessfulChangeVerification(session, diff: currentDiff)
            try requirePartiallyShownFilesConfirmed(currentDiff, confirmedDigest: partiallyShownFilesConfirmedDigest, sessionID: sessionID)
            let result = try await workspaceManager.applyVerifiedChangesToLocalBranch(
                for: session,
                branchName: branchName,
                diff: currentDiff
            )
            session.changesAcceptedAt = Date()
            session.updatedAt = Date()
            try store.saveSession(session)
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "change.applied_to_branch",
                message: "The user applied \(result.changedFileCount) files to an isolated worktree for local branch \(result.branchName) at \(result.worktreePath). No commit, push or merge was made."
            ))
            return result
        } catch let error as AgentBridgeError {
            if case .sourceBaseConflict = error {
                try? store.appendEvent(AuditEvent(
                    sessionID: sessionID,
                    kind: "change.apply.source_conflict",
                    message: OutputRedactor.redact(error.localizedDescription)
                ))
            }
            throw error
        }
    }

    func requireIsolatedChangesSession(_ session: SessionRecord) throws {
        guard session.provider == .codex || session.provider == .claude,
              session.policy.accessMode == .isolatedChanges,
              !session.policy.workspaceReadOnly else {
            throw AgentBridgeError.sessionMismatch("Create an isolated-change session; read-only and native interactive sessions do not run this operation.")
        }
    }

    /// Long and non-UTF-8 files stay in the patch but cannot be read in the review,
    /// so taking them needs a confirmation bound to this exact diff. Apply checks it
    /// too, because apply does not require an earlier accept.
    private func requirePartiallyShownFilesConfirmed(_ diff: WorkspaceChangeDiff, confirmedDigest: String?, sessionID: UUID) throws {
        let files = diff.partiallyShownFiles
        guard !files.isEmpty else { return }
        guard confirmedDigest == diff.digest else {
            throw AgentBridgeError.invalidInput("Some changed files are not fully shown. Export the patch to review them, then confirm before accepting or applying.")
        }
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "change.partially_shown_confirmed",
            message: "Confirmed \(files.count) file(s) that were not fully shown, for diff sha256:\(diff.digest)."
        ))
    }

    private func clearChangeAcceptanceState(_ session: inout SessionRecord) {
        session.approvedChangePlanDigest = nil
        session.approvedChangePlanMemoryDigest = nil
        session.verificationPassed = nil
        session.verificationDiffDigest = nil
        session.verificationCompletedAt = nil
        session.changesAcceptedAt = nil
    }

    private func requireSuccessfulChangeVerification(_ session: SessionRecord) throws {
        guard session.verificationPassed == true,
              let verificationAt = session.verificationCompletedAt,
              let lastChangeAt = session.lastChangeRunAt,
              verificationAt >= lastChangeAt else {
            throw AgentBridgeError.verificationRequired
        }
    }

    private func requireSuccessfulChangeVerification(_ session: SessionRecord, diff: WorkspaceChangeDiff) throws {
        try requireSuccessfulChangeVerification(session)
        guard session.verificationDiffDigest == diff.digest else {
            throw AgentBridgeError.verificationRequired
        }
    }
}
