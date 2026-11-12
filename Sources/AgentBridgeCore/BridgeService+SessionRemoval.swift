import Foundation

extension BridgeService {
    /// What removing the session would delete. Nothing is changed.
    public func sessionRemovalPreview(sessionID: UUID) async throws -> SessionRemovalPreview {
        await workspaceManager.removalPreview(for: try loadSession(sessionID))
    }

    /// Removes the session after the user reviewed `reviewed`: deletes its
    /// isolated workspace and its private copy of the pinned commit, then hides it
    /// from the session list. Its record and audit events stay, so usage
    /// statistics still count its runs.
    ///
    /// Holding the session's run lease, it checks the workspace again and stops
    /// if anything changed since the review, so nothing the user did not see is
    /// deleted. A session that is running, or has a paid API call not yet
    /// reconciled, cannot be removed.
    public func removeSession(sessionID: UUID, reviewed: SessionRemovalPreview) async throws {
        guard reviewed.sessionID == sessionID else {
            throw AgentBridgeError.sessionMismatch("The reviewed removal is for a different session.")
        }
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        // The lease is free, so nothing runs this session; a `.running` status is
        // left over from a process that stopped.
        var session = try loadSession(sessionID)
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        if session.provider == .claude,
           try spendLedger(for: profileID).unresolvedReservations().contains(where: { $0.sessionID == sessionID }) {
            throw AgentBridgeError.sessionMismatch("This session has a paid API call that is not reconciled yet. Reconcile it before removing the session.")
        }
        guard await workspaceManager.removalPreview(for: session) == reviewed else {
            throw AgentBridgeError.sessionMismatch("The session's workspace changed after you reviewed the removal. Nothing was deleted; review it again.")
        }
        try workspaceManager.deleteWorkspace(for: session)
        let now = Date()
        session.removedAt = now
        session.updatedAt = now
        try store.saveSession(session)
        try? store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "session.removed",
            message: reviewed.mayLoseWork
                ? "The session was removed and its isolated workspace deleted, after the user confirmed it held work that might exist nowhere else."
                : "The session was removed and its isolated workspace deleted."
        ))
    }
}
