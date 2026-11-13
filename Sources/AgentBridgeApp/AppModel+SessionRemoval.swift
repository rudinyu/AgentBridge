import AgentBridgeCore
import Foundation

extension AppModel {
    /// Why `session` cannot be removed now, or nil if it can.
    func sessionRemovalBlocker(for session: SessionRecord) -> String? {
        if hasActiveAutonomousWorkflow {
            return "Finish or stop the autonomous workflow before removing a session."
        }
        if hasActiveRun(for: session.id) || session.status == .running {
            return "Stop the session before removing it."
        }
        let workspace = URL(fileURLWithPath: session.workspacePath).standardizedFileURL.path
        // The running process counts too: it may belong to a launch the panel
        // no longer shows.
        let launches = [terminal.terminalLaunch, terminal.windowController.runningLaunch].compactMap { $0 }
        if launches.contains(where: { URL(fileURLWithPath: $0.workingDirectory).standardizedFileURL.path == workspace }) {
            return "Close the terminal for this session before removing it."
        }
        return nil
    }

    /// Checks what removing the session would delete, then asks the user.
    func reviewSessionRemoval(_ sessionID: UUID) {
        guard !isRemovingSession, let service, let session = sessions.first(where: { $0.id == sessionID }) else { return }
        if let blocker = sessionRemovalBlocker(for: session) {
            errorMessage = blocker
            return
        }
        isRemovingSession = true
        status = "Checking what removing the session would delete…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRemovingSession = false }
            do {
                self.sessionRemovalPreview = try await service.sessionRemovalPreview(sessionID: sessionID)
                self.status = "Review what removing the session deletes."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSessionRemoval() {
        sessionRemovalPreview = nil
    }

    /// Removes the session the user just reviewed.
    func confirmSessionRemoval() {
        guard let preview = sessionRemovalPreview, !isRemovingSession, let service else { return }
        sessionRemovalPreview = nil
        if let session = sessions.first(where: { $0.id == preview.sessionID }),
           let blocker = sessionRemovalBlocker(for: session) {
            errorMessage = blocker
            return
        }
        isRemovingSession = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRemovingSession = false }
            do {
                try await service.removeSession(sessionID: preview.sessionID, reviewed: preview)
                if self.selectedSessionID == preview.sessionID {
                    self.selectedSessionID = nil
                    self.changes.changeDiff = nil
                }
                self.refresh()
                self.status = "Removed the session and deleted its isolated workspace."
            } catch {
                self.errorMessage = error.localizedDescription
                self.refresh()
            }
        }
    }

    /// How many paths of each list the confirmation shows.
    private static let listedRemovalPaths = 12

    private func listedPaths(_ paths: [String], total: Int) -> String {
        var text = paths.prefix(Self.listedRemovalPaths).map { "• \($0)" }.joined(separator: "\n")
        let more = total - min(paths.count, Self.listedRemovalPaths)
        if more > 0 { text += "\n" + localizedFormat("…and %@ more.", String(more)) }
        return text
    }

    /// The confirmation text for `preview`, in the app language.
    func sessionRemovalMessage(_ preview: SessionRemovalPreview) -> String {
        var parts = [localizedFormat("AgentBridge deletes this session's isolated workspace: %@", preview.workspacePath)]
        if !preview.workspaceExists {
            parts.append(localized("The workspace folder no longer exists."))
        }
        for problem in preview.inspectionProblems {
            parts.append(localized(problem))
        }
        if !preview.unsavedReferences.isEmpty {
            parts.append(localizedFormat(
                "Branches, tags, notes or stash entries whose commits exist only in this workspace: %@",
                preview.unsavedReferences.joined(separator: ", ")
            ))
        }
        if preview.changedPathCount > 0 {
            parts.append(localizedFormat(
                "Files that differ from what the source repository has (%@):",
                String(preview.changedPathCount)
            ) + "\n" + listedPaths(preview.changedPaths, total: preview.changedPathCount))
        }
        if preview.ignoredPathCount > 0 {
            parts.append(localizedFormat(
                "Ignored files and folders, which Git does not keep (%@):",
                String(preview.ignoredPathCount)
            ) + "\n" + listedPaths(preview.ignoredPaths, total: preview.ignoredPathCount))
        }
        parts.append(localized(preview.mayLoseWork
            ? "Anything listed here is lost. Removal cannot be undone."
            : "Nothing in the workspace is missing from the source repository."))
        parts.append(localized("The session's audit events and usage records are kept."))
        return parts.joined(separator: "\n\n")
    }
}
