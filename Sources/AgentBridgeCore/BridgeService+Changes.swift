import Darwin
import Foundation

extension BridgeService {
    public func createChangePlan(
        sessionID: UUID,
        title: String,
        summary: String,
        steps: [String]
    ) throws -> ChangePlan {
        let initialSession = try loadSession(sessionID)
        guard initialSession.provider != .local else {
            throw AgentBridgeError.sessionMismatch("本機模型目前不支援隔離變更或工作計畫。")
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
            throw AgentBridgeError.invalidChangePlan("標題、摘要及 1 至 32 個步驟都必須有內容，且符合大小限制。")
        }
        let plan = ChangePlan(
            sessionID: sessionID,
            title: trimmedTitle,
            summary: trimmedSummary,
            steps: trimmedSteps
        )
        session.changePlan = plan
        session.approvedChangePlanDigest = nil
        session.verificationPassed = nil
        session.verificationDiffDigest = nil
        session.verificationCompletedAt = nil
        session.changesAcceptedAt = nil
        session.updatedAt = Date()
        try store.saveSession(session)
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "change.plan.created",
            message: "已建立待檢視的變更計畫（摘要雜湊 \(plan.reviewDigest)，步驟 \(plan.steps.count) 項）；尚未授權檔案寫入。"
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
            throw AgentBridgeError.invalidChangePlan("計畫內容已改變或檢視識別碼不符；請重新檢視目前計畫。")
        }
        session.approvedChangePlanDigest = plan.reviewDigest
        session.updatedAt = Date()
        try store.saveSession(session)
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "change.plan.approved",
            message: "使用者已明確檢視並核准變更計畫（摘要雜湊 \(plan.reviewDigest)）。"
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
            message: "已還原隔離工作區中 \(filePaths.count) 個使用者選取的檔案；來源儲存庫未變更。"
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
            message: "已還原整個隔離工作區至基準提交；來源儲存庫未變更。"
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
            message: "已匯出 \(diff.files.count) 個檔案的差異補丁（\(diff.patch.count) 位元組）；未修改來源儲存庫。"
        ))
        return diff.patch
    }

    @discardableResult
    public func acceptChanges(sessionID: UUID) async throws -> SessionRecord {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        try requireSuccessfulChangeVerification(session)
        let diff = try await workspaceManager.diff(for: session)
        try requireSuccessfulChangeVerification(session, diff: diff)
        guard !diff.files.isEmpty else { throw AgentBridgeError.invalidInput("工作區沒有可接受的變更。") }
        session.changesAcceptedAt = Date()
        session.updatedAt = Date()
        try store.saveSession(session)
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "change.accepted",
            message: "使用者已接受已驗證的隔離變更，包含 \(diff.files.count) 個檔案；來源儲存庫仍未修改。"
        ))
        return session
    }

    @discardableResult
    public func applyChangesToLocalBranch(sessionID: UUID, branchName: String) async throws -> BranchApplyResult {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        try requireSuccessfulChangeVerification(session)
        do {
            let currentDiff = try await workspaceManager.diff(for: session)
            try requireSuccessfulChangeVerification(session, diff: currentDiff)
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
                message: "使用者已將 \(result.changedFileCount) 個檔案套用到本機分支 \(result.branchName) 的隔離工作樹 \(result.worktreePath)。未建立提交、推送或合併。"
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
            throw AgentBridgeError.sessionMismatch("請建立隔離變更模式的工作階段；唯讀與原生互動工作階段不會執行此操作。")
        }
    }

    private func clearChangeAcceptanceState(_ session: inout SessionRecord) {
        session.approvedChangePlanDigest = nil
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
