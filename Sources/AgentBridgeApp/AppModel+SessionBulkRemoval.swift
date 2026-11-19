import AgentBridgeCore
import Foundation

/// What removing several sessions at once would do, grouped for one confirmation.
struct SessionBulkRemovalReview: Equatable, Identifiable {
    /// Each review is new, so a new review shows a new sheet.
    let id = UUID()
    struct Item: Equatable, Identifiable {
        let session: SessionRecord
        let preview: SessionRemovalPreview
        var id: UUID { session.id }
    }

    struct BlockedItem: Equatable, Identifiable {
        let session: SessionRecord
        /// Why it cannot be removed now, as an English source string.
        let reason: String
        var id: UUID { session.id }
    }

    /// Sessions that can be removed, in the order they were selected in.
    let removable: [Item]
    /// Sessions that are left in place, with the reason.
    let blocked: [BlockedItem]

    /// Removable sessions whose workspace holds nothing the source lacks.
    var safe: [Item] { removable.filter { !$0.preview.mayLoseWork } }
    /// Removable sessions whose workspace holds work removal would lose.
    var mayLoseWork: [Item] { removable.filter { $0.preview.mayLoseWork } }

    /// Groups `sessions`, keeping their order. A blocker wins over a preview; a
    /// session with neither could not be checked and is not removable.
    init(sessions: [SessionRecord], previews: [UUID: SessionRemovalPreview], blockers: [UUID: String]) {
        var removable: [Item] = []
        var blocked: [BlockedItem] = []
        for session in sessions {
            if let reason = blockers[session.id] {
                blocked.append(BlockedItem(session: session, reason: reason))
            } else if let preview = previews[session.id], preview.sessionID == session.id {
                removable.append(Item(session: session, preview: preview))
            } else {
                blocked.append(BlockedItem(session: session, reason: "AgentBridge could not check what removing this session would delete."))
            }
        }
        self.removable = removable
        self.blocked = blocked
    }
}

extension AppModel {
    /// The sessions both lists show: all sessions that match the filter.
    var filteredSessions: [SessionRecord] {
        guard sessionFilter.isActive else { return sessions }
        return sessions.filter { sessionFilter.matches($0, extraText: modelLabel(for: $0).map { [$0] } ?? []) }
    }

    /// Selected sessions that are still shown, in list order. Bulk removal acts
    /// only on these, so a session the filter hides is never removed unseen.
    var shownSessionsSelectedForRemoval: [SessionRecord] {
        filteredSessions.filter { sessionsSelectedForRemoval.contains($0.id) }
    }

    /// Whether bulk removal can start now. The single path has the same limits.
    var canReviewBulkSessionRemoval: Bool {
        !isRemovingSession && !hasActiveAutonomousWorkflow && service != nil && !shownSessionsSelectedForRemoval.isEmpty
    }

    func clearSessionFilter() {
        sessionFilter = SessionFilter()
    }

    func setSelectingSessions(_ selecting: Bool) {
        isSelectingSessions = selecting
        if !selecting { sessionsSelectedForRemoval = [] }
    }

    func toggleSessionSelectedForRemoval(_ sessionID: UUID) {
        if sessionsSelectedForRemoval.contains(sessionID) {
            sessionsSelectedForRemoval.remove(sessionID)
        } else {
            sessionsSelectedForRemoval.insert(sessionID)
        }
    }

    func selectAllShownSessions() {
        sessionsSelectedForRemoval.formUnion(filteredSessions.map(\.id))
    }

    /// A short name for a session in the bulk confirmation and summary.
    func bulkRemovalLabel(for session: SessionRecord) -> String {
        localizedFormat(
            "%@ · %@ · %@",
            session.provider.rawValue.capitalized,
            URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent,
            String(session.snapshotCommit.prefix(12))
        )
    }

    /// Checks what removing each selected session would delete, one at a time,
    /// then shows one confirmation for all of them.
    func reviewBulkSessionRemoval() {
        guard canReviewBulkSessionRemoval, let service else { return }
        let targets = shownSessionsSelectedForRemoval
        isRemovingSession = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isRemovingSession = false
                self.bulkSessionRemovalProgress = nil
            }
            var previews: [UUID: SessionRemovalPreview] = [:]
            var blockers: [UUID: String] = [:]
            for (index, session) in targets.enumerated() {
                let progress = self.localizedFormat("Checking session %@ of %@…", String(index + 1), String(targets.count))
                self.bulkSessionRemovalProgress = progress
                self.status = progress
                if let blocker = self.sessionRemovalBlocker(for: session) {
                    blockers[session.id] = blocker
                    continue
                }
                do {
                    previews[session.id] = try await service.sessionRemovalPreview(sessionID: session.id)
                } catch {
                    blockers[session.id] = error.localizedDescription
                }
            }
            self.bulkSessionRemovalReview = SessionBulkRemovalReview(sessions: targets, previews: previews, blockers: blockers)
            self.status = "Review what removing the sessions deletes."
        }
    }

    func cancelBulkSessionRemoval() {
        bulkSessionRemovalReview = nil
    }

    /// Removes every removable session the user just reviewed, one at a time,
    /// each against its own preview, and goes on past a session that fails.
    func confirmBulkSessionRemoval() {
        guard let review = bulkSessionRemovalReview, !isRemovingSession, let service else { return }
        bulkSessionRemovalReview = nil
        let items = review.removable
        let notRemovable = review.blocked.count
        guard !items.isEmpty else { return }
        isRemovingSession = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isRemovingSession = false
                self.bulkSessionRemovalProgress = nil
            }
            var removed = 0
            var failures: [(label: String, message: String)] = []
            for (index, item) in items.enumerated() {
                let progress = self.localizedFormat("Removing session %@ of %@…", String(index + 1), String(items.count))
                self.bulkSessionRemovalProgress = progress
                self.status = progress
                let label = self.bulkRemovalLabel(for: item.session)
                if let current = self.sessions.first(where: { $0.id == item.id }),
                   let blocker = self.sessionRemovalBlocker(for: current) {
                    failures.append((label, self.localized(blocker)))
                    continue
                }
                do {
                    try await service.removeSession(sessionID: item.id, reviewed: item.preview)
                    removed += 1
                    if self.selectedSessionID == item.id {
                        self.selectedSessionID = nil
                        self.changes.changeDiff = nil
                    }
                } catch {
                    failures.append((label, self.localized(error.localizedDescription)))
                }
            }
            self.sessionsSelectedForRemoval = []
            self.refresh()
            let summary = self.bulkSessionRemovalSummary(
                removed: removed,
                attempted: items.count,
                notRemovable: notRemovable,
                failures: failures
            )
            if failures.isEmpty {
                self.status = summary
            } else {
                self.errorMessage = summary
            }
        }
    }

    /// What bulk removal did, in the app language.
    func bulkSessionRemovalSummary(
        removed: Int,
        attempted: Int,
        notRemovable: Int,
        failures: [(label: String, message: String)]
    ) -> String {
        var lines = [localizedFormat("Removed %@ of %@ sessions.", String(removed), String(attempted))]
        if notRemovable > 0 {
            lines.append(localizedFormat("Sessions left in place because they could not be removed now: %@.", String(notRemovable)))
        }
        for failure in failures {
            lines.append(localizedFormat("Could not remove %@: %@", failure.label, failure.message))
        }
        return lines.joined(separator: "\n")
    }
}
