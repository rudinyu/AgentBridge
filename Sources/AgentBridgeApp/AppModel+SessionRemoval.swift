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
        if let launch = terminal.terminalLaunch,
           URL(fileURLWithPath: launch.workingDirectory).standardizedFileURL.path == workspace {
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

    /// The confirmation text for `preview`, in the app language.
    func sessionRemovalMessage(_ preview: SessionRemovalPreview) -> String {
        var parts = [localizedFormat("AgentBridge deletes this session's isolated workspace: %@", preview.workspacePath)]
        if !preview.workspaceExists {
            parts.append(localized("The workspace folder no longer exists."))
        }
        if let problem = preview.inspectionProblem {
            parts.append(localized(problem))
        }
        if !preview.unsavedReferences.isEmpty {
            parts.append(localizedFormat(
                "Branches or stashes whose commits exist only in this workspace: %@",
                preview.unsavedReferences.joined(separator: ", ")
            ))
        }
        if preview.changedPathCount > 0 {
            var files = preview.changedPaths.prefix(12).map { "• \($0)" }.joined(separator: "\n")
            let more = preview.changedPathCount - min(preview.changedPaths.count, 12)
            if more > 0 { files += "\n" + localizedFormat("…and %@ more.", String(more)) }
            parts.append(localizedFormat(
                "Files that differ from what the source repository has (%@):",
                String(preview.changedPathCount)
            ) + "\n" + files)
        }
        parts.append(localized(preview.mayLoseWork
            ? "Anything listed here is lost. Removal cannot be undone."
            : "Nothing in the workspace is missing from the source repository."))
        parts.append(localized("The session's audit events and usage records are kept."))
        return parts.joined(separator: "\n\n")
    }
}
