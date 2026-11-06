import AppKit
import AgentBridgeCore
import Observation

/// Review of an isolated-change session: the plan draft and its approval,
/// the current diff, per-file restore, patch export, verification results,
/// acceptance and applying to a local branch. Running the approved change
/// and the verifier stays on `AppModel` with the other runs.
@MainActor
@Observable
final class ChangeReviewModel {
    var changePlanTitle = ""
    var changePlanSummary = ""
    var changePlanStepsText = ""
    var changeDiff: WorkspaceChangeDiff?
    var verificationResult: VerificationResult?
    var branchName = ""
    var customVerifierPath = ""
    var customVerifierArgumentsText = ""
    var isVerifying = false
    private var partiallyShownFilesConfirmedDigest: String?

    var selectedChangePlanDraftMatchesSaved: Bool {
        guard let plan = app.selectedSession?.changePlan else { return false }
        return ChangePlanDraft(
            title: changePlanTitle,
            summary: changePlanSummary,
            stepsText: changePlanStepsText
        ).matches(plan)
    }

    var selectedChangePlanIsApproved: Bool {
        guard selectedChangePlanDraftMatchesSaved,
              let session = app.selectedSession,
              let plan = session.changePlan else { return false }
        return session.approvedChangePlanDigest == plan.reviewDigest
    }

    var verifiedCurrentDiff: Bool {
        guard let session = app.selectedSession, let diff = changeDiff,
              session.verificationPassed == true,
              session.verificationDiffDigest == diff.digest,
              let verifiedAt = session.verificationCompletedAt,
              let lastChangeAt = session.lastChangeRunAt else { return false }
        return verifiedAt >= lastChangeAt
    }

    /// Bound to the digest, so a confirmation lapses as soon as the diff changes.
    var partiallyShownFilesConfirmed: Bool {
        get { changeDiff != nil && partiallyShownFilesConfirmedDigest == changeDiff?.digest }
        set { partiallyShownFilesConfirmedDigest = newValue ? changeDiff?.digest : nil }
    }

    var awaitingPartiallyShownFilesConfirmation: Bool {
        changeDiff?.partiallyShownFiles.isEmpty == false && !partiallyShownFilesConfirmed
    }

    func loadChangePlanDraftFromSelectedSession() {
        if let plan = app.selectedSession?.changePlan {
            changePlanTitle = plan.title
            changePlanSummary = plan.summary
            changePlanStepsText = plan.steps.joined(separator: "\n")
        } else {
            changePlanTitle = ""
            changePlanSummary = ""
            changePlanStepsText = ""
        }
    }

    func saveChangePlan() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession,
              session.policy.accessMode == .isolatedChanges else {
            app.errorMessage = "Create an isolated-changes session first."
            return
        }
        let steps = changePlanStepsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            let plan = try service.createChangePlan(
                sessionID: session.id,
                title: changePlanTitle,
                summary: changePlanSummary,
                steps: steps
            )
            changePlanTitle = plan.title
            changePlanSummary = plan.summary
            changePlanStepsText = plan.steps.joined(separator: "\n")
            app.status = "The plan was saved as awaiting review; writes are not authorized yet."
            app.refresh()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    func approveChangePlan() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession, let plan = session.changePlan else {
            app.errorMessage = "Save a work plan first."
            return
        }
        guard selectedChangePlanDraftMatchesSaved else {
            app.errorMessage = app.localized("Save your plan changes before review or approval.")
            return
        }
        do {
            _ = try service.approveChangePlan(sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest)
            app.status = "Explicitly approved the plan shown; you can now run isolated changes."
            app.refresh()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    func restoreChangeFile(_ path: String) {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession else { return }
        Task { @MainActor [weak self] in
            do {
                try await service.restoreChangeFiles(sessionID: session.id, filePaths: [path])
                self?.app.refreshSelectedEvents()
                self?.app.refresh()
            } catch { self?.app.errorMessage = error.localizedDescription }
        }
    }

    func restoreAllChangeFiles() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession else { return }
        Task { @MainActor [weak self] in
            do {
                try await service.restoreAllChanges(sessionID: session.id)
                self?.app.refreshSelectedEvents()
                self?.app.refresh()
            } catch { self?.app.errorMessage = error.localizedDescription }
        }
    }

    func exportChangePatch() {
        guard let service = app.service, let session = app.selectedSession else { return }
        Task { @MainActor [weak self] in
            do {
                let patch = try await service.exportChangePatch(sessionID: session.id)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "AgentBridge-\(session.id.uuidString.prefix(8)).patch"
                panel.allowedContentTypes = [.plainText]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try patch.write(to: url, options: .atomic)
                self?.app.status = "Exported a \(patch.count)-byte patch."
                self?.app.refreshSelectedEvents()
            } catch { self?.app.errorMessage = error.localizedDescription }
        }
    }

    func chooseCustomVerifier() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Executable"
        if panel.runModal() == .OK, let url = panel.url { customVerifierPath = url.path }
    }

    func acceptChanges() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession else { return }
        let confirmedDigest = partiallyShownFilesConfirmedDigest
        Task { @MainActor [weak self] in
            do {
                _ = try await service.acceptChanges(sessionID: session.id, partiallyShownFilesConfirmedDigest: confirmedDigest)
                self?.app.status = "Accepted the currently verified diff; the source repository is still unchanged."
                self?.app.refresh()
            } catch { self?.app.errorMessage = error.localizedDescription }
        }
    }

    func applyChangesToBranch() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service = app.service, let session = app.selectedSession else { return }
        let requestedBranchName = branchName
        let confirmedDigest = partiallyShownFilesConfirmedDigest
        Task { @MainActor [weak self] in
            do {
                let result = try await service.applyChangesToLocalBranch(
                    sessionID: session.id,
                    branchName: requestedBranchName,
                    partiallyShownFilesConfirmedDigest: confirmedDigest
                )
                self?.app.status = "Created an uncommitted worktree: \(result.worktreePath); no commit, push or merge was made."
                self?.app.refresh()
            } catch { self?.app.errorMessage = error.localizedDescription }
        }
    }

    @ObservationIgnored private weak var owner: AppModel?

    private var app: AppModel {
        guard let owner else { preconditionFailure("ChangeReviewModel outlived its AppModel.") }
        return owner
    }

    /// Connects this model to the `AppModel` that owns it; called once from `AppModel.init`.
    func attach(to app: AppModel) {
        owner = app
    }
}
